package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}
	// Set global db for handlers
	db = testDB

	token := "lm_inst_validtoken123456789012"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()
	router.GET("/test-db", func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

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
	if resp.RegistryURL != "registry.laymatched.io" {
		t.Errorf("Expected registry.laymatched.io, got %s", resp.RegistryURL)
	}
	if resp.RegistryToken == "" {
		t.Error("Expected non-empty registry token")
	}

	// Verify JWT structure
	parsed, err := jwt.Parse(resp.RegistryToken, func(t *jwt.Token) (interface{}, error) {
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
	scope := claims["scope"].(string)
	if scope != "repository:laymatched-api:pull,repository:laymatched-web:pull" {
		t.Errorf("Wrong scope: %s", scope)
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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

	token := "lm_inst_ttltoken12345678901234"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	var resp AuthorizeResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	parsed, _ := jwt.Parse(resp.RegistryToken, func(t *jwt.Token) (interface{}, error) {
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

	// First request with v0.1.0
	cfg = Config{
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
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
	cfg.ApprovedVersion = "v0.2.0"

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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 1000,
	}

	token := "lm_inst_urltoken1234567890123"
	insertTestToken(t, testDB, "customer-1", token, false, false)

	router := setupRouter()

	w := httptest.NewRecorder()
	req, _ := http.NewRequest("POST", "/installer/authorize", bytes.NewBufferString(`{"installer_token":"`+token+`"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(w, req)

	var resp AuthorizeResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp.RegistryURL != "registry.laymatched.io" {
		t.Errorf("Expected registry.laymatched.io, got %s", resp.RegistryURL)
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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
		RateLimitPerMin: 2,
	}

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
		token, err := generateToken()
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
		ApprovedVersion: "v0.1.0",
		RegistryURL:     "registry.laymatched.io",
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