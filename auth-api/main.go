package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/joho/godotenv"
	_ "github.com/mattn/go-sqlite3"
	"golang.org/x/crypto/bcrypt"
)

const (
	tokenPrefix              = "lm_inst_"
	ownerTokenPrefix         = "lm_owner_"
	tokenEntropyBytes        = 24
	bcryptCost               = 12
	registryTokenTTL         = 1 * time.Hour
	ownerTokenTTL            = 24 * time.Hour
	issuer                   = "laymatched-auth"
	audience                 = "registry.laymatched.io"
	rateLimitCleanupInterval = 5 * time.Minute
	maxRateLimitEntries      = 10000 // Maximum number of IPs to track
)

var approvedVersionPath = "/data/approved_version.txt"

type Config struct {
	Port                  string
	DBPath                string
	RegistryURL           string
	PrivateKeyPath        string
	PublicKeyPath         string
	RegistryPublicKeyPath string
	RegistryCertPath      string
	RateLimitPerMin       int
	LogLevel              string
	TrustedProxies        string
}

type InstallerToken struct {
	ID          int64
	CustomerID  string
	TokenSHA256 string
	TokenHash   string
	CreatedAt   time.Time
	RevokedAt   *time.Time
	ExpiresAt   *time.Time
	Notes       string
	LastUsedAt  *time.Time
}

type OwnerToken struct {
	ID          int64
	Name        string
	TokenSHA256 string
	TokenHash   string
	CreatedAt   time.Time
	RevokedAt   *time.Time
	ExpiresAt   *time.Time
	Scopes      string
	Notes       string
	LastUsedAt  *time.Time
}

type AuthorizeRequest struct {
	InstallerToken string `json:"installer_token" binding:"required" validate:"required"`
}

type AuthorizeResponse struct {
	RegistryToken   string `json:"registry_token"`
	ApprovedVersion string `json:"approved_version"`
	RegistryURL     string `json:"registry_url"`
}

type HealthResponse struct {
	Status    string `json:"status"`
	Version   string `json:"version"`
	Timestamp string `json:"timestamp"`
}

type TokenServiceRequest struct {
	Service string `form:"service"`
	Scope   string `form:"scope"`
	Account string `form:"account"`
}

type TokenServiceResponse struct {
	Token     string `json:"token"`
	ExpiresIn int    `json:"expires_in"`
	IssuedAt  string `json:"issued_at"`
}

var (
	db                *sql.DB
	privateKey        *rsa.PrivateKey
	publicKey         *rsa.PublicKey
	cfg               Config
	rateLimiter       *RateLimiter
	approvedVersion   string
	approvedVersionMu sync.RWMutex
)

type RateLimiter struct {
	mu       sync.Mutex
	requests map[string][]time.Time
	limit    int
	window   time.Duration
	stopCh   chan struct{}
}

func NewRateLimiter(limit int, window time.Duration) *RateLimiter {
	rl := &RateLimiter{
		requests: make(map[string][]time.Time),
		limit:    limit,
		window:   window,
		stopCh:   make(chan struct{}),
	}
	go rl.cleanupLoop()
	return rl
}

func (rl *RateLimiter) Stop() {
	close(rl.stopCh)
}

func (rl *RateLimiter) cleanupLoop() {
	ticker := time.NewTicker(rateLimitCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			rl.cleanup()
		case <-rl.stopCh:
			return
		}
	}
}

func (rl *RateLimiter) cleanup() {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)
	for key, reqs := range rl.requests {
		var valid []time.Time
		for _, t := range reqs {
			if t.After(cutoff) {
				valid = append(valid, t)
			}
		}
		if len(valid) == 0 {
			delete(rl.requests, key)
		} else {
			rl.requests[key] = valid
		}
	}

	// Enforce max entries limit - if still too many, remove oldest entries
	if len(rl.requests) > maxRateLimitEntries {
		// Sort by oldest request time and remove oldest entries
		type ipEntry struct {
			ip     string
			oldest time.Time
		}
		entries := make([]ipEntry, 0, len(rl.requests))
		for ip, reqs := range rl.requests {
			if len(reqs) > 0 {
				entries = append(entries, ipEntry{ip: ip, oldest: reqs[0]})
			}
		}
		// Simple approach: just delete random entries until under limit
		// In production, you'd want a more sophisticated eviction policy
		toDelete := len(rl.requests) - maxRateLimitEntries
		deleted := 0
		for ip := range rl.requests {
			if deleted >= toDelete {
				break
			}
			delete(rl.requests, ip)
			deleted++
		}
	}
}

func (rl *RateLimiter) Allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)

	if reqs, ok := rl.requests[key]; ok {
		var valid []time.Time
		for _, t := range reqs {
			if t.After(cutoff) {
				valid = append(valid, t)
			}
		}
		rl.requests[key] = valid
		if len(valid) >= rl.limit {
			return false
		}
	}

	// Check if adding this key would exceed max entries
	if len(rl.requests) >= maxRateLimitEntries {
		// Check if this key already exists
		if _, exists := rl.requests[key]; !exists {
			// Too many unique IPs, reject
			return false
		}
	}

	rl.requests[key] = append(rl.requests[key], now)
	return true
}

func loadConfig() Config {
	_ = godotenv.Load()

	return Config{
		Port:                  getEnv("PORT", "8443"),
		DBPath:                getEnv("DB_PATH", "/data/auth-tokens.db"),
		RegistryURL:           getEnv("REGISTRY_URL", "registry.laymatched.io"),
		PrivateKeyPath:        getEnv("PRIVATE_KEY_PATH", "/data/private.pem"),
		PublicKeyPath:         getEnv("PUBLIC_KEY_PATH", "/data/public.pem"),
		RegistryPublicKeyPath: getEnv("REGISTRY_PUBLIC_KEY_PATH", "/data/auth-public.pem"),
		RegistryCertPath:      getEnv("REGISTRY_CERT_PATH", "/data/auth-cert.pem"),
		RateLimitPerMin:       getEnvInt("RATE_LIMIT_PER_MIN", 50),
		LogLevel:              getEnv("LOG_LEVEL", "info"),
		TrustedProxies:        getEnv("TRUSTED_PROXIES", "127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"),
	}
}

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func getEnvInt(key string, defaultVal int) int {
	if v := os.Getenv(key); v != "" {
		var i int
		fmt.Sscanf(v, "%d", &i)
		if i > 0 {
			return i
		}
	}
	return defaultVal
}

func initDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", path+"?_fk=1&_journal_mode=WAL")
	if err != nil {
		return nil, err
	}

	schema := `
	CREATE TABLE IF NOT EXISTS installer_tokens (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		customer_id TEXT NOT NULL,
		token_sha256 TEXT NOT NULL UNIQUE,
		token_hash TEXT NOT NULL,
		created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
		revoked_at DATETIME,
		expires_at DATETIME,
		notes TEXT,
		last_used_at DATETIME
	);
	CREATE INDEX IF NOT EXISTS idx_token_sha256 ON installer_tokens(token_sha256);
	CREATE INDEX IF NOT EXISTS idx_customer_id ON installer_tokens(customer_id);

	CREATE TABLE IF NOT EXISTS owner_tokens (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		name TEXT NOT NULL,
		token_sha256 TEXT NOT NULL UNIQUE,
		token_hash TEXT NOT NULL,
		created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
		revoked_at DATETIME,
		expires_at DATETIME,
		scopes TEXT NOT NULL,
		notes TEXT,
		last_used_at DATETIME
	);
	CREATE INDEX IF NOT EXISTS idx_owner_token_sha256 ON owner_tokens(token_sha256);
	`
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)

	return db, nil
}

func loadOrGenerateKeys(privatePath, publicPath, registryPublicPath, registryCertPath string) (*rsa.PrivateKey, *rsa.PublicKey, error) {
	privPEM, err := os.ReadFile(privatePath)
	if err == nil {
		block, _ := pem.Decode(privPEM)
		if block == nil || block.Type != "RSA PRIVATE KEY" {
			return nil, nil, errors.New("invalid private key PEM")
		}
		priv, err := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return nil, nil, err
		}
		pubPEM, err := os.ReadFile(publicPath)
		if err == nil {
			block, _ := pem.Decode(pubPEM)
			if block != nil && block.Type == "PUBLIC KEY" {
				pub, err := x509.ParsePKIXPublicKey(block.Bytes)
				if err == nil {
					if rsaPub, ok := pub.(*rsa.PublicKey); ok {
						// Ensure registry public key also exists
						if _, err := os.Stat(registryPublicPath); os.IsNotExist(err) {
							if err := writePublicKey(registryPublicPath, rsaPub); err != nil {
								log.Printf(`{"level":"warn","message":"failed to write registry public key","path":"%s","error":"%v"}`, registryPublicPath, err)
							}
						}
						// Ensure registry certificate also exists
						if _, err := os.Stat(registryCertPath); os.IsNotExist(err) {
							if err := generateAndWriteCert(registryCertPath, priv); err != nil {
								log.Printf(`{"level":"warn","message":"failed to write registry certificate","path":"%s","error":"%v"}`, registryCertPath, err)
							}
						}
						return priv, rsaPub, nil
					}
				}
			}
		}
		return priv, &priv.PublicKey, nil
	}

	log.Println("Generating new RSA key pair...")
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}

	privPEM = pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(priv),
	})
	if err := os.WriteFile(privatePath, privPEM, 0600); err != nil {
		return nil, nil, err
	}

	pubPEM, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		return nil, nil, err
	}
	pubPEM = pem.EncodeToMemory(&pem.Block{
		Type:  "PUBLIC KEY",
		Bytes: pubPEM,
	})
	if err := os.WriteFile(publicPath, pubPEM, 0644); err != nil {
		return nil, nil, err
	}

	// Also write to registry public key path
	if err := writePublicKey(registryPublicPath, &priv.PublicKey); err != nil {
		return nil, nil, err
	}

	// Generate and write X.509 certificate for registry rootcertbundle
	if err := generateAndWriteCert(registryCertPath, priv); err != nil {
		return nil, nil, err
	}

	return priv, &priv.PublicKey, nil
}

func generateAndWriteCert(certPath string, priv *rsa.PrivateKey) error {
	// Generate a self-signed X.509 certificate for the registry to trust
	serialNumber, _ := rand.Int(rand.Reader, new(big.Int).SetUint64(^uint64(0)))
	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName: "laymatched-auth",
		},
		NotBefore:             time.Now().Add(-365 * 24 * time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour), // 10 years
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           nil,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})
	return os.WriteFile(certPath, certPEM, 0644)
}

func writePublicKey(path string, pub *rsa.PublicKey) error {
	pubPEM, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return err
	}
	pubPEM = pem.EncodeToMemory(&pem.Block{
		Type:  "PUBLIC KEY",
		Bytes: pubPEM,
	})
	return os.WriteFile(path, pubPEM, 0644)
}

func loadApprovedVersion() string {
	data, err := os.ReadFile(approvedVersionPath)
	if err != nil {
		log.Printf(`{"level":"warn","message":"failed to read approved_version.txt, using default","error":"%v"}`, err)
		return "v0.1.0"
	}
	v := strings.TrimSpace(string(data))
	if v == "" {
		return "v0.1.0"
	}
	return v
}

func watchApprovedVersion() {
	prev := ""
	for {
		v := loadApprovedVersion()
		approvedVersionMu.Lock()
		approvedVersion = v
		approvedVersionMu.Unlock()
		if v != prev {
			log.Printf(`{"level":"info","message":"approved version changed","version":"%s"}`, v)
			prev = v
		}
		time.Sleep(5 * time.Second)
	}
}

func getApprovedVersion() string {
	approvedVersionMu.RLock()
	defer approvedVersionMu.RUnlock()
	return approvedVersion
}

func hashToken(token string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(token), bcryptCost)
	if err != nil {
		return "", err
	}
	return string(hash), nil
}

func tokenSHA256(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func verifyTokenHash(token, hash string) bool {
	err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(token))
	return err == nil
}

func generateToken(prefix string) (string, error) {
	entropy := make([]byte, tokenEntropyBytes)
	if _, err := rand.Read(entropy); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(entropy), nil
}

func generateRegistryToken(customerID string, scopes string, ttl time.Duration) (string, error) {
	now := time.Now()

	// Parse scopes and build Docker Distribution compatible access entries
	// Scopes format: "repository:laymatched-api:pull,repository:laymatched-web:push"
	var access []map[string]interface{}
	for _, scope := range strings.Split(scopes, ",") {
		scope = strings.TrimSpace(scope)
		if scope == "" {
			continue
		}
		parts := strings.Split(scope, ":")
		if len(parts) != 3 {
			continue
		}
		resourceType := parts[0] // "repository"
		resourceName := parts[1] // "laymatched-api"
		action := parts[2]       // "pull", "push", etc.

		if resourceType == "repository" {
			access = append(access, map[string]interface{}{
				"type":    resourceType,
				"name":    resourceName,
				"actions": []string{action},
			})
		}
	}

	claims := jwt.MapClaims{
		"iss":         issuer,
		"sub":         "laymatched-installer",
		"aud":         audience,
		"access":      access,
		"iat":         now.Unix(),
		"exp":         now.Add(ttl).Unix(),
		"customer_id": customerID,
	}

	// Read certificate for x5c header (required by Docker Distribution token auth)
	// If certificate is not available (e.g., in unit tests), skip x5c header
	certPEM, err := os.ReadFile(cfg.RegistryCertPath)
	if err == nil {
		block, _ := pem.Decode(certPEM)
		if block != nil && block.Type == "CERTIFICATE" {
			certDER := block.Bytes
			certB64 := base64.StdEncoding.EncodeToString(certDER)
			token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
			token.Header["x5c"] = []string{certB64}
			return token.SignedString(privateKey)
		}
	}

	// Fallback: sign without x5c header (for environments without certificate)
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	return token.SignedString(privateKey)
}

func findInstallerTokenByHash(hash string) (*InstallerToken, error) {
	row := db.QueryRow(`
		SELECT id, customer_id, token_sha256, token_hash, created_at, revoked_at, expires_at, notes, last_used_at
		FROM installer_tokens WHERE token_sha256 = ?
	`, hash)

	var t InstallerToken
	var revokedAt, expiresAt, lastUsedAt sql.NullTime
	err := row.Scan(&t.ID, &t.CustomerID, &t.TokenSHA256, &t.TokenHash, &t.CreatedAt, &revokedAt, &expiresAt, &t.Notes, &lastUsedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if revokedAt.Valid {
		t.RevokedAt = &revokedAt.Time
	}
	if expiresAt.Valid {
		t.ExpiresAt = &expiresAt.Time
	}
	if lastUsedAt.Valid {
		t.LastUsedAt = &lastUsedAt.Time
	}
	return &t, nil
}

func findOwnerTokenByHash(hash string) (*OwnerToken, error) {
	row := db.QueryRow(`
		SELECT id, name, token_sha256, token_hash, created_at, revoked_at, expires_at, scopes, notes, last_used_at
		FROM owner_tokens WHERE token_sha256 = ?
	`, hash)

	var t OwnerToken
	var revokedAt, expiresAt, lastUsedAt sql.NullTime
	err := row.Scan(&t.ID, &t.Name, &t.TokenSHA256, &t.TokenHash, &t.CreatedAt, &revokedAt, &expiresAt, &t.Scopes, &t.Notes, &lastUsedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if revokedAt.Valid {
		t.RevokedAt = &revokedAt.Time
	}
	if expiresAt.Valid {
		t.ExpiresAt = &expiresAt.Time
	}
	if lastUsedAt.Valid {
		t.LastUsedAt = &lastUsedAt.Time
	}
	return &t, nil
}

func updateInstallerTokenLastUsed(id int64) error {
	_, err := db.Exec(`UPDATE installer_tokens SET last_used_at = CURRENT_TIMESTAMP WHERE id = ?`, id)
	return err
}

func updateOwnerTokenLastUsed(id int64) error {
	_, err := db.Exec(`UPDATE owner_tokens SET last_used_at = CURRENT_TIMESTAMP WHERE id = ?`, id)
	return err
}

func isTokenValid(revokedAt, expiresAt *time.Time) error {
	if revokedAt != nil {
		return errors.New("token revoked")
	}
	if expiresAt != nil && time.Now().After(*expiresAt) {
		return errors.New("token expired")
	}
	return nil
}

func redactToken(token string) string {
	if len(token) <= 8 {
		return token[:4] + "****"
	}
	return token[:8] + "****"
}

func logRequest(c *gin.Context, status int, tokenPrefix string, message string) {
	log.Printf(`{"level":"info","method":"%s","path":"%s","status":%d,"client_ip":"%s","token_prefix":"%s","message":"%s"}`,
		c.Request.Method, c.Request.URL.Path, status, c.ClientIP(), tokenPrefix, message)
}

func logError(c *gin.Context, status int, tokenPrefix string, message string) {
	log.Printf(`{"level":"error","method":"%s","path":"%s","status":%d,"client_ip":"%s","token_prefix":"%s","message":"%s"}`,
		c.Request.Method, c.Request.URL.Path, status, c.ClientIP(), tokenPrefix, message)
}

func rateLimitMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		ip := c.ClientIP()
		if !rateLimiter.Allow(ip) {
			logError(c, http.StatusTooManyRequests, "-", "rate limit exceeded")
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "rate limit exceeded"})
			return
		}
		c.Next()
	}
}

func authorizeHandler(c *gin.Context) {
	var req AuthorizeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		logError(c, http.StatusBadRequest, "-", "invalid request body")
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request"})
		return
	}

	tokenPrefix := redactToken(req.InstallerToken)

	tokenHash := tokenSHA256(req.InstallerToken)

	t, err := findInstallerTokenByHash(tokenHash)
	if err != nil {
		logError(c, http.StatusInternalServerError, tokenPrefix, "database error")
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	if t == nil || !verifyTokenHash(req.InstallerToken, t.TokenHash) {
		logRequest(c, http.StatusUnauthorized, tokenPrefix, "invalid or revoked token")
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
		return
	}

	if err := isTokenValid(t.RevokedAt, t.ExpiresAt); err != nil {
		logRequest(c, http.StatusUnauthorized, tokenPrefix, "invalid or revoked token")
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
		return
	}

	if err := updateInstallerTokenLastUsed(t.ID); err != nil {
		log.Printf(`{"level":"warn","message":"failed to update last_used_at","token_id":%d}`, t.ID)
	}

	resp := AuthorizeResponse{
		RegistryToken:   req.InstallerToken,
		ApprovedVersion: getApprovedVersion(),
		RegistryURL:     cfg.RegistryURL,
	}

	logRequest(c, http.StatusOK, tokenPrefix, "authorization successful")
	c.JSON(http.StatusOK, resp)
}

func tokenServiceHandler(c *gin.Context) {
	var req TokenServiceRequest
	if err := c.ShouldBindQuery(&req); err != nil {
		logError(c, http.StatusBadRequest, "-", "invalid token service request")
		c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request"})
		return
	}

	authHeader := c.GetHeader("Authorization")
	if authHeader == "" {
		logError(c, http.StatusUnauthorized, "-", "missing authorization header")
		c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}

	if !strings.HasPrefix(authHeader, "Bearer ") {
		logError(c, http.StatusUnauthorized, "-", "invalid authorization scheme")
		c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}

	token := strings.TrimPrefix(authHeader, "Bearer ")
	tokenPrefix := redactToken(token)

	tokenHash := tokenSHA256(token)

	var t *OwnerToken
	var err error
	if strings.HasPrefix(token, ownerTokenPrefix) {
		t, err = findOwnerTokenByHash(tokenHash)
	} else {
		inst, err := findInstallerTokenByHash(tokenHash)
		if err != nil || inst == nil {
			logRequest(c, http.StatusUnauthorized, tokenPrefix, "invalid or revoked token")
			c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
			c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
			return
		}
		if err := isTokenValid(inst.RevokedAt, inst.ExpiresAt); err != nil {
			logRequest(c, http.StatusUnauthorized, tokenPrefix, "invalid or revoked token")
			c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
			c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
			return
		}

		scope := req.Scope
		if scope == "" {
			scope = "repository:laymatched-api:pull,repository:laymatched-web:pull"
		}
		allowedScopes := []string{"repository:laymatched-api:pull", "repository:laymatched-web:pull"}
		for _, s := range strings.Split(scope, ",") {
			s = strings.TrimSpace(s)
			allowed := false
			for _, a := range allowedScopes {
				if s == a {
					allowed = true
					break
				}
			}
			if !allowed {
				logRequest(c, http.StatusForbidden, tokenPrefix, "scope not authorized for installer token")
				c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
				c.JSON(http.StatusForbidden, gin.H{"error": "scope not authorized"})
				return
			}
		}

		if err := updateInstallerTokenLastUsed(inst.ID); err != nil {
			log.Printf(`{"level":"warn","message":"failed to update installer last_used_at","token_id":%d}`, inst.ID)
		}
		registryToken, err := generateRegistryToken(
			inst.CustomerID,
			scope,
			registryTokenTTL,
		)
		if err != nil {
			logError(c, http.StatusInternalServerError, tokenPrefix, "registry token generation failed")
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		now := time.Now().UTC()
		resp := TokenServiceResponse{
			Token:     registryToken,
			ExpiresIn: int(registryTokenTTL.Seconds()),
			IssuedAt:  now.Format(time.RFC3339),
		}
		logRequest(c, http.StatusOK, tokenPrefix, "token service: installer token exchanged")
		c.JSON(http.StatusOK, resp)
		return
	}

	if err != nil || t == nil {
		logRequest(c, http.StatusUnauthorized, tokenPrefix, "invalid or revoked owner token")
		c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
		return
	}

	if err := isTokenValid(t.RevokedAt, t.ExpiresAt); err != nil {
		logRequest(c, http.StatusUnauthorized, tokenPrefix, "invalid or revoked owner token")
		c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
		return
	}

	// For owner tokens, validate requested scope against token's allowed scopes
	if req.Scope != "" {
		// Parse owner token scopes (comma-separated)
		allowedScopeMap := make(map[string]bool)
		for _, s := range strings.Split(t.Scopes, ",") {
			allowedScopeMap[strings.TrimSpace(s)] = true
		}
		// Check each requested scope
		for _, s := range strings.Split(req.Scope, ",") {
			s = strings.TrimSpace(s)
			if !allowedScopeMap[s] {
				logRequest(c, http.StatusForbidden, tokenPrefix, "scope not authorized")
				c.Header("WWW-Authenticate", `Bearer realm="https://api.laymatched.com/token",service="registry.laymatched.io"`)
				c.JSON(http.StatusForbidden, gin.H{"error": "scope not authorized"})
				return
			}
		}
	}

	if err := updateOwnerTokenLastUsed(t.ID); err != nil {
		log.Printf(`{"level":"warn","message":"failed to update owner last_used_at","token_id":%d}`, t.ID)
	}

	registryToken, err := generateRegistryToken(t.Name, req.Scope, ownerTokenTTL)
	if err != nil {
		logError(c, http.StatusInternalServerError, tokenPrefix, "registry token generation failed")
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	now := time.Now().UTC()
	resp := TokenServiceResponse{
		Token:     registryToken,
		ExpiresIn: int(ownerTokenTTL.Seconds()),
		IssuedAt:  now.Format(time.RFC3339),
	}
	logRequest(c, http.StatusOK, tokenPrefix, "token service: owner token exchanged")
	c.JSON(http.StatusOK, resp)
}

func healthHandler(c *gin.Context) {
	c.JSON(http.StatusOK, HealthResponse{
		Status:    "healthy",
		Version:   "1.0.0",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	})
}

func jwksHandler(c *gin.Context) {
	n := publicKey.N.Bytes()
	e := publicKey.E

	nB64 := base64.RawURLEncoding.EncodeToString(n)
	eBytes := make([]byte, 4)
	for i := 0; i < 4; i++ {
		eBytes[i] = byte(e >> (8 * (3 - i)))
	}
	eB64 := base64.RawURLEncoding.EncodeToString(eBytes)

	c.JSON(http.StatusOK, gin.H{
		"keys": []gin.H{
			{
				"kty": "RSA",
				"kid": "laymatched-auth-1",
				"use": "sig",
				"alg": "RS256",
				"n":   nB64,
				"e":   eB64,
			},
		},
	})
}

func setupRouter() *gin.Engine {
	if cfg.LogLevel != "debug" {
		gin.SetMode(gin.ReleaseMode)
	}

	if rateLimiter == nil {
		rateLimiter = NewRateLimiter(cfg.RateLimitPerMin, time.Minute)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(rateLimitMiddleware())

	if cfg.TrustedProxies != "" {
		proxies := strings.Split(cfg.TrustedProxies, ",")
		var trusted []string
		for _, p := range proxies {
			p = strings.TrimSpace(p)
			if p != "" {
				trusted = append(trusted, p)
			}
		}
		if len(trusted) > 0 {
			if err := r.SetTrustedProxies(trusted); err != nil {
				log.Printf(`{"level":"warn","message":"failed to set trusted proxies","error":"%v"}`, err)
			}
		}
	}

	r.GET("/health", healthHandler)
	r.GET("/.well-known/jwks.json", jwksHandler)

	api := r.Group("/installer")
	api.POST("/authorize", authorizeHandler)

	tokenSvc := r.Group("/token")
	tokenSvc.GET("", tokenServiceHandler)

	return r
}

func main() {
	cfg = loadConfig()
	rateLimiter = NewRateLimiter(cfg.RateLimitPerMin, time.Minute)

	approvedVersion = loadApprovedVersion()
	go watchApprovedVersion()

	var err error
	db, err = initDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("Database init failed: %v", err)
	}
	defer db.Close()

	privateKey, publicKey, err = loadOrGenerateKeys(cfg.PrivateKeyPath, cfg.PublicKeyPath, cfg.RegistryPublicKeyPath, cfg.RegistryCertPath)
	if err != nil {
		log.Fatalf("Key loading failed: %v", err)
	}

	router := setupRouter()

	srv := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: router,
	}

	go func() {
		log.Printf(`{"level":"info","message":"Auth API starting","port":%s}`, cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")
	rateLimiter.Stop()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}
	log.Println("Server exited")
}
