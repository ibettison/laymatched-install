package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
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
	tokenPrefix      = "lm_inst_"
	tokenEntropyBytes = 24
	bcryptCost       = 12
	registryTokenTTL = 1 * time.Hour
	issuer           = "laymatched-auth"
	audience         = "registry.laymatched.io"
)

type Config struct {
	Port               string
	DBPath             string
	ApprovedVersion    string
	RegistryURL        string
	PrivateKeyPath     string
	PublicKeyPath      string
	RateLimitPerMin    int
	LogLevel           string
}

type InstallerToken struct {
	ID            int64
	CustomerID    string
	TokenSHA256   string
	TokenHash     string
	CreatedAt     time.Time
	RevokedAt     *time.Time
	ExpiresAt     *time.Time
	Notes         string
	LastUsedAt    *time.Time
}

type AuthorizeRequest struct {
	InstallerToken string `json:"installer_token" binding:"required" validate:"required"`
}

type AuthorizeResponse struct {
	RegistryToken  string `json:"registry_token"`
	ApprovedVersion string `json:"approved_version"`
	RegistryURL     string `json:"registry_url"`
}

type HealthResponse struct {
	Status    string `json:"status"`
	Version   string `json:"version"`
	Timestamp string `json:"timestamp"`
}

var (
	db          *sql.DB
	privateKey  *rsa.PrivateKey
	publicKey   *rsa.PublicKey
	cfg         Config
	rateLimiter *RateLimiter
)

type RateLimiter struct {
	mu       sync.Mutex
	requests map[string][]time.Time
	limit    int
	window   time.Duration
}

func NewRateLimiter(limit int, window time.Duration) *RateLimiter {
	return &RateLimiter{
		requests: make(map[string][]time.Time),
		limit:    limit,
		window:   window,
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

	rl.requests[key] = append(rl.requests[key], now)
	return true
}

func loadConfig() Config {
	_ = godotenv.Load()

	return Config{
		Port:            getEnv("PORT", "8443"),
		DBPath:          getEnv("DB_PATH", "/data/auth-tokens.db"),
		ApprovedVersion: getEnv("APPROVED_VERSION", "v0.1.0"),
		RegistryURL:     getEnv("REGISTRY_URL", "registry.laymatched.io"),
		PrivateKeyPath:  getEnv("PRIVATE_KEY_PATH", "/data/private.pem"),
		PublicKeyPath:   getEnv("PUBLIC_KEY_PATH", "/data/public.pem"),
		RateLimitPerMin: getEnvInt("RATE_LIMIT_PER_MIN", 50),
		LogLevel:        getEnv("LOG_LEVEL", "info"),
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
	`
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)

	return db, nil
}

func loadOrGenerateKeys(privatePath, publicPath string) (*rsa.PrivateKey, *rsa.PublicKey, error) {
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

	return priv, &priv.PublicKey, nil
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

func generateToken() (string, error) {
	entropy := make([]byte, tokenEntropyBytes)
	if _, err := rand.Read(entropy); err != nil {
		return "", err
	}
	return tokenPrefix + base64.RawURLEncoding.EncodeToString(entropy), nil
}

func generateRegistryToken(customerID string) (string, error) {
	now := time.Now()
	claims := jwt.MapClaims{
		"iss": issuer,
		"sub": "laymatched-installer",
		"aud": audience,
		"scope": "repository:laymatched-api:pull,repository:laymatched-web:pull",
		"iat": now.Unix(),
		"exp": now.Add(registryTokenTTL).Unix(),
		"customer_id": customerID,
	}

	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	return token.SignedString(privateKey)
}

func findTokenByHash(hash string) (*InstallerToken, error) {
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

func updateTokenLastUsed(id int64) error {
	_, err := db.Exec(`UPDATE installer_tokens SET last_used_at = CURRENT_TIMESTAMP WHERE id = ?`, id)
	return err
}

func isTokenValid(t *InstallerToken) error {
	if t == nil {
		return errors.New("invalid token")
	}
	if t.RevokedAt != nil {
		return errors.New("token revoked")
	}
	if t.ExpiresAt != nil && time.Now().After(*t.ExpiresAt) {
		return errors.New("token expired")
	}
	return nil
}

func redactToken(token string) string {
	if len(token) <= 8 {
		return "lm_inst_****"
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

	t, err := findTokenByHash(tokenHash)
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

	if err := isTokenValid(t); err != nil {
		logRequest(c, http.StatusUnauthorized, tokenPrefix, "invalid or revoked token")
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
		return
	}

	if err := updateTokenLastUsed(t.ID); err != nil {
		log.Printf(`{"level":"warn","message":"failed to update last_used_at","token_id":%d}`, t.ID)
	}

	registryToken, err := generateRegistryToken(t.CustomerID)
	if err != nil {
		logError(c, http.StatusInternalServerError, tokenPrefix, "registry token generation failed")
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	resp := AuthorizeResponse{
		RegistryToken:   registryToken,
		ApprovedVersion: cfg.ApprovedVersion,
		RegistryURL:     cfg.RegistryURL,
	}

	logRequest(c, http.StatusOK, tokenPrefix, "authorization successful")
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

	r.GET("/health", healthHandler)
	r.GET("/.well-known/jwks.json", jwksHandler)

	api := r.Group("/installer")
	api.POST("/authorize", authorizeHandler)

	return r
}

func main() {
	cfg = loadConfig()
	rateLimiter = NewRateLimiter(cfg.RateLimitPerMin, time.Minute)

	var err error
	db, err = initDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("Database init failed: %v", err)
	}
	defer db.Close()

	privateKey, publicKey, err = loadOrGenerateKeys(cfg.PrivateKeyPath, cfg.PublicKeyPath)
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
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}
	log.Println("Server exited")
}