package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

func setupTestDB(t *testing.T) (*sql.DB, func()) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	db, err := sql.Open("sqlite3", dbPath+"?_fk=1&_journal_mode=WAL")
	if err != nil {
		t.Fatalf("DB open failed: %v", err)
	}

	schema := `
	CREATE TABLE installer_tokens (
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
	CREATE INDEX idx_token_sha256 ON installer_tokens(token_sha256);
	CREATE INDEX idx_customer_id ON installer_tokens(customer_id);
	`
	if _, err := db.Exec(schema); err != nil {
		t.Fatalf("Schema failed: %v", err)
	}

	return db, func() { db.Close() }
}

func generateTestKeys(t *testing.T) (*rsa.PrivateKey, *rsa.PublicKey) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("Key gen failed: %v", err)
	}
	return priv, &priv.PublicKey
}

func hashTokenForTest(t *testing.T, token string) string {
	hash, err := bcrypt.GenerateFromPassword([]byte(token), bcryptCost)
	if err != nil {
		t.Fatalf("Hash failed: %v", err)
	}
	return string(hash)
}

func insertTestToken(t *testing.T, db *sql.DB, customerID, token string, revoked, expired bool) int64 {
	bcryptHash := hashTokenForTest(t, token)
	sha256Hash := tokenSHA256ForTest(t, token)
	var revokedAt, expiresAt *time.Time
	now := time.Now()
	if revoked {
		revokedAt = &now
	}
	if expired {
		t := now.Add(-time.Hour)
		expiresAt = &t
	}

	result, err := db.Exec(`
		INSERT INTO installer_tokens (customer_id, token_sha256, token_hash, revoked_at, expires_at, notes)
		VALUES (?, ?, ?, ?, ?, ?)
	`, customerID, sha256Hash, bcryptHash, revokedAt, expiresAt, "test token")
	if err != nil {
		t.Fatalf("Insert failed: %v", err)
	}
	id, _ := result.LastInsertId()
	return id
}

func tokenSHA256ForTest(t *testing.T, token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func TestAuthorizeValidToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()

	priv, pub := generateTestKeys(t)
	privateKey = priv
	publicKey = pub

	cfg = Config{
		Port:            "8443",
		DBPath:          "",
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	db = testDB
	approvedVersion = loadApprovedVersion()

	token := "lm_inst_validtoken123456789012"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("Expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp AuthorizeResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("Invalid JSON: %v", err)
	}

	if resp.ApprovedVersion != "v0.1.0" {
		t.Errorf("Expected version v0.1.0, got %s", resp.ApprovedVersion)
	}
	if resp.RegistryURL != "registry.matched.laysports.co.uk" {
		t.Errorf("Expected registry.matched.laysports.co.uk, got %s", resp.RegistryURL)
	}
	// registry_token should be the installer token itself (for use with /token endpoint)
	if resp.RegistryToken != token {
		t.Errorf("Expected registry_token to be installer token, got %s", resp.RegistryToken)
	}
}

func TestTokenServiceWithInstallerToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()

	priv, pub := generateTestKeys(t)
	privateKey = priv
	publicKey = pub

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	db = testDB
	approvedVersion = loadApprovedVersion()

	token := "lm_inst_tokensvctoken12345678"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	// Call token service with installer token
	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/token?service=registry.matched.laysports.co.uk&scope=repository:laymatched-api:pull", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("Expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp TokenServiceResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("Invalid JSON: %v", err)
	}

	if resp.Token == "" {
		t.Error("Expected non-empty registry token")
	}
	if resp.ExpiresIn != int(registryTokenTTL.Seconds()) {
		t.Errorf("Expected expires_in %d, got %d", int(registryTokenTTL.Seconds()), resp.ExpiresIn)
	}

	// Verify JWT structure
	parsed, err := jwt.Parse(resp.Token, func(t *jwt.Token) (interface{}, error) {
		return pub, nil
	})
	if err != nil {
		t.Fatalf("JWT parse failed: %v", err)
	}
	claims := parsed.Claims.(jwt.MapClaims)
	if claims["iss"] != issuer {
		t.Errorf("Wrong issuer: %v", claims["iss"])
	}
	if claims["aud"] != audience {
		t.Errorf("Wrong audience: %v", claims["aud"])
	}
	if claims["sub"] != "laymatched-installer" {
		t.Errorf("Wrong subject: %v", claims["sub"])
	}
	// Verify access claim (Docker Distribution format)
	access := claims["access"].([]interface{})
	if len(access) != 1 {
		t.Errorf("Expected 1 access entry, got %d", len(access))
	}
	accessEntry := access[0].(map[string]interface{})
	if accessEntry["type"] != "repository" {
		t.Errorf("Wrong access type: %v", accessEntry["type"])
	}
	if accessEntry["name"] != "laymatched-api" {
		t.Errorf("Wrong access name: %v", accessEntry["name"])
	}
	actions := accessEntry["actions"].([]interface{})
	if len(actions) != 1 || actions[0] != "pull" {
		t.Errorf("Wrong access actions: %v", actions)
	}
	if claims["customer_id"] != "customer-1" {
		t.Errorf("Wrong customer_id: %v", claims["customer_id"])
	}
}

func TestAuthorizeUnknownToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"lm_inst_unknown12345678901234"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("Expected 401, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]string
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["error"] != "invalid credentials" {
		t.Errorf("Expected 'invalid credentials', got %s", resp["error"])
	}
}

func TestAuthorizeRevokedToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	token := "lm_inst_revokedtoken1234567890"
	insertTestToken(t, testDB, "customer-1", token, true, false)

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("Expected 401, got %d: %s", w.Code, w.Body.String())
	}
}

func TestAuthorizeExpiredToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	token := "lm_inst_expiredtoken12345678901"
	insertTestToken(t, testDB, "customer-1", token, false, true)

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("Expected 401, got %d: %s", w.Code, w.Body.String())
	}
}

func TestAuthorizeMalformedRequest(t *testing.T) {
	gin.SetMode(gin.TestMode)

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{invalid json`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("Expected 400, got %d", w.Code)
	}
}

func TestHealthEndpoint(t *testing.T) {
	gin.SetMode(gin.TestMode)

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/health", nil)
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("Expected 200, got %d", w.Code)
	}

	var resp HealthResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Status != "healthy" {
		t.Errorf("Expected healthy, got %s", resp.Status)
	}
}

func TestJWKSEndpoint(t *testing.T) {
	gin.SetMode(gin.TestMode)

	priv, pub := generateTestKeys(t)
	privateKey = priv
	publicKey = pub

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/.well-known/jwks.json", nil)
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("Expected 200, got %d", w.Code)
	}

	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	keys := resp["keys"].([]interface{})
	if len(keys) != 1 {
		t.Fatalf("Expected 1 key, got %d", len(keys))
	}
	key := keys[0].(map[string]interface{})
	if key["kty"] != "RSA" || key["alg"] != "RS256" {
		t.Errorf("Invalid key params: %v", key)
	}
}

func TestTokenHashNotLogged(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	token := "lm_inst_secrettoken12345678901"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	// The log output should contain only the prefix, not the full token
	// This is tested by verifying the redactToken function
	redacted := redactToken(token)
	if redacted == token {
		t.Error("Token not redacted")
	}
	if len(redacted) >= len(token) {
		t.Error("Redacted token not shorter than original")
	}
}

func TestRegistryTokenTTL(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, pub := generateTestKeys(t)
	privateKey = priv
	publicKey = pub

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	token := "lm_inst_ttltoken12345678901234"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	// Call token service to get registry JWT
	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/token?service=registry.matched.laysports.co.uk&scope=repository:laymatched-api:pull", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	router.ServeHTTP(w, req)

	var resp TokenServiceResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	parsed, _ := jwt.Parse(resp.Token, func(t *jwt.Token) (interface{}, error) {
		return pub, nil
	})
	claims := parsed.Claims.(jwt.MapClaims)
	exp := int64(claims["exp"].(float64))
	iat := int64(claims["iat"].(float64))

	expectedTTL := int64(registryTokenTTL.Seconds())
	actualTTL := exp - iat

	if actualTTL < expectedTTL-5 || actualTTL > expectedTTL+5 {
		t.Errorf("Expected TTL ~%d seconds, got %d", expectedTTL, actualTTL)
	}
}

func TestApprovedVersionChange(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	token := "lm_inst_versiontoken1234567890"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	// Create a temp approved_version.txt file
	tmpDir := t.TempDir()
	versionFile := filepath.Join(tmpDir, "approved_version.txt")
	approvedVersionPath = versionFile

	// First request with v0.1.0
	os.WriteFile(versionFile, []byte("v0.1.0"), 0644)
	// Initialize approved version
	approvedVersion = loadApprovedVersion()

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	var resp1 AuthorizeResponse
	json.Unmarshal(w.Body.Bytes(), &resp1)

	// Change approved version
	os.WriteFile(versionFile, []byte("v0.2.0"), 0644)
	// Manually reload approved version (file watcher not running in tests)
	approvedVersion = loadApprovedVersion()

	w = httptest.NewRecorder()
	req, _ = http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	var resp2 AuthorizeResponse
	json.Unmarshal(w.Body.Bytes(), &resp2)

	if resp1.ApprovedVersion != "v0.1.0" {
		t.Errorf("First response wrong version: %s", resp1.ApprovedVersion)
	}
	if resp2.ApprovedVersion != "v0.2.0" {
		t.Errorf("Second response wrong version: %s", resp2.ApprovedVersion)
	}
}

func TestRegistryURLReturned(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	approvedVersion = loadApprovedVersion()

	token := "lm_inst_urltoken1234567890123"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	var resp AuthorizeResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp.RegistryURL != "registry.matched.laysports.co.uk" {
		t.Errorf("Expected registry.matched.laysports.co.uk, got %s", resp.RegistryURL)
	}
}

func TestRateLimiting(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 2,
	}
	approvedVersion = loadApprovedVersion()

	router := setupRouter()

	// Test rate limiter directly
	rl := NewRateLimiter(2, time.Minute)

	// First two requests should be allowed
	if !rl.Allow("192.168.1.100") {
		t.Fatal("First request should be allowed")
	}
	if !rl.Allow("192.168.1.100") {
		t.Fatal("Second request should be allowed")
	}

	// Third request should be denied
	if rl.Allow("192.168.1.100") {
		t.Fatal("Third request should be rate limited")
	}

	// Different IP should be allowed
	if !rl.Allow("192.168.1.101") {
		t.Fatal("Different IP should be allowed")
	}

	// Also test through HTTP (with rate limit disabled for this part)
	cfg.RateLimitPerMin = 1000
	router = setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"lm_inst_ratelimit123456789012"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("Expected 401 for invalid token, got %d", w.Code)
	}
}

func TestTokenGenerationEntropy(t *testing.T) {
	tokens := make(map[string]bool)
	for i := 0; i < 1000; i++ {
		token, err := generateToken(tokenPrefix)
		if err != nil {
			t.Fatalf("Token generation failed: %v", err)
		}
		if tokens[token] {
			t.Fatal("Duplicate token generated")
		}
		tokens[token] = true

		if len(token) < len(tokenPrefix)+32 {
			t.Errorf("Token too short: %s", token)
		}
		if token[:len(tokenPrefix)] != tokenPrefix {
			t.Errorf("Token missing prefix: %s", token)
		}
	}
}

func TestConcurrentTokenValidation(t *testing.T) {
	gin.SetMode(gin.TestMode)

	testDB, cleanup := setupTestDB(t)
	defer cleanup()
	db = testDB

	priv, _ := generateTestKeys(t)
	privateKey = priv

	cfg = Config{
		RegistryURL:     "registry.matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}

	token := "lm_inst_concurrent123456789012"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	done := make(chan bool, 10)
	for i := 0; i < 10; i++ {
		go func() {
			w := httptest.NewRecorder()
			req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
			req.Header.Set("Content-Type", "application/json")
			router.ServeHTTP(w, req)
			if w.Code != http.StatusOK {
				t.Errorf("Concurrent request failed: %d", w.Code)
			}
			done <- true
		}()
	}

	for i := 0; i < 10; i++ {
		<-done
	}
}

func TestRegistryPublicKeyDistribution(t *testing.T) {
	gin.SetMode(gin.TestMode)

	tmpDir := t.TempDir()
	privatePath := filepath.Join(tmpDir, "private.pem")
	publicPath := filepath.Join(tmpDir, "public.pem")
	registryPublicPath := filepath.Join(tmpDir, "auth-public.pem")
	registryCertPath := filepath.Join(tmpDir, "auth-cert.pem")

	cfg = Config{
		RegistryURL:           "registry.matched.laysports.co.uk",
		RateLimitPerMin:       1000,
		PrivateKeyPath:        privatePath,
		PublicKeyPath:         publicPath,
		RegistryPublicKeyPath: registryPublicPath,
		RegistryCertPath:      registryCertPath,
	}
	approvedVersion = loadApprovedVersion()

	// Call loadOrGenerateKeys - should write to all three paths
	priv, pub, err := loadOrGenerateKeys(privatePath, publicPath, registryPublicPath, registryCertPath)
	if err != nil {
		t.Fatalf("loadOrGenerateKeys failed: %v", err)
	}
	privateKey = priv
	publicKey = pub

	// Verify all three files exist
	for _, p := range []string{privatePath, publicPath, registryPublicPath, registryCertPath} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("Expected file %s to exist: %v", p, err)
		}
	}

	// Verify registry public key matches the public key
	registryPubPEM, err := os.ReadFile(registryPublicPath)
	if err != nil {
		t.Fatalf("Failed to read registry public key: %v", err)
	}
	block, _ := pem.Decode(registryPubPEM)
	if block == nil || block.Type != "PUBLIC KEY" {
		t.Fatalf("Invalid registry public key PEM")
	}
	registryPub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		t.Fatalf("Failed to parse registry public key: %v", err)
	}
	rsaRegistryPub, ok := registryPub.(*rsa.PublicKey)
	if !ok {
		t.Fatalf("Registry public key is not RSA")
	}
	if rsaRegistryPub.N.Cmp(pub.N) != 0 || rsaRegistryPub.E != pub.E {
		t.Errorf("Registry public key does not match generated public key")
	}

	// Verify private key is NOT readable at registry public path (permissions)
	// The registry public key should be world-readable (0644), private key should be 0600
	privateInfo, err := os.Stat(privatePath)
	if err != nil {
		t.Fatalf("Failed to stat private key: %v", err)
	}
	if privateInfo.Mode().Perm() != 0600 {
		t.Errorf("Private key should have 0600 permissions, got %v", privateInfo.Mode().Perm())
	}

	registryPubInfo, err := os.Stat(registryPublicPath)
	if err != nil {
		t.Fatalf("Failed to stat registry public key: %v", err)
	}
	if registryPubInfo.Mode().Perm() != 0644 {
		t.Errorf("Registry public key should have 0644 permissions, got %v", registryPubInfo.Mode().Perm())
	}
}
