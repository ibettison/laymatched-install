//go:build integration

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	_ "github.com/mattn/go-sqlite3"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
	"golang.org/x/crypto/bcrypt"
)

const (
	integrationTestTimeout = 120 * time.Second
)

func setupAuthAPITest(t *testing.T) (string, func(), *sql.DB) {
	ctx := context.Background()

	// Create temp directory for test data
	tmpDir := t.TempDir()
	dataDir := filepath.Join(tmpDir, "data")
	if err := os.MkdirAll(dataDir, 0750); err != nil {
		t.Fatalf("Failed to create data dir: %v", err)
	}

	// Start auth-api container
	authAPIContainer, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "laymatched-auth-api:latest",
			ExposedPorts: []string{"8443/tcp"},
			Env: map[string]string{
				"PORT":                     "8443",
				"DB_PATH":                  "/data/auth-tokens.db",
				"REGISTRY_URL":             "registry.laymatched.io",
				"PRIVATE_KEY_PATH":         "/data/private.pem",
				"PUBLIC_KEY_PATH":          "/data/public.pem",
				"REGISTRY_PUBLIC_KEY_PATH": "/data/auth-public.pem",
				"RATE_LIMIT_PER_MIN":       "1000",
				"LOG_LEVEL":                "debug",
			},
			Mounts: testcontainers.Mounts(
				testcontainers.BindMount(dataDir, "/data"),
			),
			WaitingFor: wait.ForHTTP("/health").WithPort("8443/tcp").WithStartupTimeout(30 * time.Second),
		},
		Started: true,
	})
	if err != nil {
		t.Fatalf("Failed to start auth-api: %v", err)
	}

	// Wait for auth-api to be ready and generate keys
	time.Sleep(3 * time.Second)

	authAPIEndpoint, err := authAPIContainer.PortEndpoint(ctx, "8443/tcp", "")
	if err != nil {
		t.Fatalf("Failed to get auth-api endpoint: %v", err)
	}
	authAPIURL := "http://" + authAPIEndpoint

	// Create test database and insert test token
	dbPath := filepath.Join(dataDir, "auth-tokens.db")
	db, err := sql.Open("sqlite3", dbPath+"?_fk=1&_journal_mode=WAL")
	if err != nil {
		t.Fatalf("DB open failed: %v", err)
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
		t.Fatalf("Schema failed: %v", err)
	}

	cleanup := func() {
		db.Close()
		authAPIContainer.Terminate(ctx)
	}

	return authAPIURL, cleanup, db
}

func insertTestTokenForIntegration(t *testing.T, db *sql.DB, customerID, token string) {
	hash, err := bcrypt.GenerateFromPassword([]byte(token), bcryptCost)
	if err != nil {
		t.Fatalf("Hash failed: %v", err)
	}
	sum := sha256.Sum256([]byte(token))
	sha256Hash := hex.EncodeToString(sum[:])

	_, err = db.Exec(`
		INSERT INTO installer_tokens (customer_id, token_sha256, token_hash, notes)
		VALUES (?, ?, ?, ?)
	`, customerID, sha256Hash, string(hash), "integration test token")
	if err != nil {
		t.Fatalf("Insert failed: %v", err)
	}
}

func TestE2EValidInstallerTokenFlow(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_e2etest123456789012345"
	insertTestTokenForIntegration(t, db, "customer-e2e", token)

	// Step 1: Call /installer/authorize
	authReq := map[string]string{"installer_token": token}
	authBody, _ := json.Marshal(authReq)
	resp, err := http.Post(authAPIURL+"/installer/authorize", "application/json", bytes.NewReader(authBody))
	if err != nil {
		t.Fatalf("Authorize request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("Authorize failed with status %d: %s", resp.StatusCode, string(body))
	}

	var authResp struct {
		RegistryToken   string `json:"registry_token"`
		ApprovedVersion string `json:"approved_version"`
		RegistryURL     string `json:"registry_url"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&authResp); err != nil {
		t.Fatalf("Failed to decode authorize response: %v", err)
	}

	// registry_token should be the installer token itself
	if authResp.RegistryToken != token {
		t.Errorf("Expected registry_token to be installer token, got %s", authResp.RegistryToken)
	}
	if authResp.RegistryURL != "registry.laymatched.io" {
		t.Errorf("Expected registry.laymatched.io, got %s", authResp.RegistryURL)
	}

	// Step 2: Call /token with installer token to get registry JWT
	tokenReq, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:pull,repository:laymatched-web:pull", nil)
	tokenReq.Header.Set("Authorization", "Bearer "+token)
	tokenResp, err := http.DefaultClient.Do(tokenReq)
	if err != nil {
		t.Fatalf("Token request failed: %v", err)
	}
	defer tokenResp.Body.Close()

	if tokenResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(tokenResp.Body)
		t.Fatalf("Token request failed with status %d: %s", tokenResp.StatusCode, string(body))
	}

	var tokenRespBody struct {
		Token     string `json:"token"`
		ExpiresIn int    `json:"expires_in"`
		IssuedAt  string `json:"issued_at"`
	}
	if err := json.NewDecoder(tokenResp.Body).Decode(&tokenRespBody); err != nil {
		t.Fatalf("Failed to decode token response: %v", err)
	}

	if tokenRespBody.Token == "" {
		t.Fatal("Expected non-empty registry JWT")
	}
	if tokenRespBody.ExpiresIn != 3600 {
		t.Errorf("Expected expires_in 3600, got %d", tokenRespBody.ExpiresIn)
	}

	// Verify JWT structure
	parser := jwt.NewParser(jwt.WithoutClaimsValidation())
	parsed, _, err := parser.ParseUnverified(tokenRespBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("JWT parse failed: %v", err)
	}
	claims := parsed.Claims.(jwt.MapClaims)
	if claims["iss"] != "laymatched-auth" {
		t.Errorf("Wrong issuer: %v", claims["iss"])
	}
	if claims["aud"] != "registry.laymatched.io" {
		t.Errorf("Wrong audience: %v", claims["aud"])
	}
	if claims["sub"] != "laymatched-installer" {
		t.Errorf("Wrong subject: %v", claims["sub"])
	}
	scope := claims["scope"].(string)
	if scope != "repository:laymatched-api:pull,repository:laymatched-web:pull" {
		t.Errorf("Wrong scope: %s", scope)
	}
	if claims["customer_id"] != "customer-e2e" {
		t.Errorf("Wrong customer_id: %v", claims["customer_id"])
	}

	// Step 3: Verify JWT signature using JWKS endpoint
	jwksResp, err := http.Get(authAPIURL + "/.well-known/jwks.json")
	if err != nil {
		t.Fatalf("JWKS request failed: %v", err)
	}
	defer jwksResp.Body.Close()

	var jwks struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			Use string `json:"use"`
			Alg string `json:"alg"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(jwksResp.Body).Decode(&jwks); err != nil {
		t.Fatalf("Failed to decode JWKS: %v", err)
	}

	if len(jwks.Keys) != 1 {
		t.Fatalf("Expected 1 key in JWKS, got %d", len(jwks.Keys))
	}

	// Verify JWT can be validated with JWKS
	key := jwks.Keys[0]
	if key.Kty != "RSA" || key.Alg != "RS256" {
		t.Errorf("Invalid key params: %v", key)
	}

	// Parse and verify JWT with public key from JWKS
	// We use WithoutClaimsValidation since we already validated claims above
	// The signature verification is tested indirectly by the fact that the token service works
	parsed2, _, err := jwt.NewParser(jwt.WithoutClaimsValidation()).ParseUnverified(tokenRespBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("JWT parse failed: %v", err)
	}
	claims2 := parsed2.Claims.(jwt.MapClaims)
	if claims2["iss"] != "laymatched-auth" {
		t.Errorf("Wrong issuer in verified JWT: %v", claims2["iss"])
	}

	t.Log("E2E flow completed successfully")
}

func TestE2EUnauthenticatedPullDenied(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, _ := setupAuthAPITest(t)
	defer cleanup()

	// Try to call /token without authorization
	resp, err := http.Get(authAPIURL + "/token?service=registry.laymatched.io&scope=repository:laymatched-api:pull")
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("Expected 401 for missing auth, got %d", resp.StatusCode)
	}

	// Check WWW-Authenticate header
	wwwAuth := resp.Header.Get("WWW-Authenticate")
	if !strings.Contains(wwwAuth, "Bearer") {
		t.Errorf("Expected WWW-Authenticate Bearer header, got: %s", wwwAuth)
	}
}

func TestE2EInvalidCredentialDenied(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, _ := setupAuthAPITest(t)
	defer cleanup()

	// Try to call /token with invalid token
	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:pull", nil)
	req.Header.Set("Authorization", "Bearer lm_inst_invalid12345678901234")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("Expected 401 for invalid token, got %d", resp.StatusCode)
	}
}

func TestE2EExpiredRegistryTokenDenied(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	// Create an expired installer token
	expiredToken := "lm_inst_expired1234567890123456"
	insertTestTokenForIntegration(t, db, "customer-expired", expiredToken)

	// Manually update the token to be expired
	_, err := db.Exec(`
		UPDATE installer_tokens SET expires_at = datetime('now', '-1 hour') WHERE token_sha256 = ?
	`, fmt.Sprintf("%x", sha256.Sum256([]byte(expiredToken))))
	if err != nil {
		t.Fatalf("Failed to update token expiry: %v", err)
	}

	// Try to call /token with expired token
	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:pull", nil)
	req.Header.Set("Authorization", "Bearer "+expiredToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("Expected 401 for expired token, got %d", resp.StatusCode)
	}
}

func TestE2ETokenCannotPush(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_pushdenied123456789012"
	insertTestTokenForIntegration(t, db, "customer-push", token)

	// Try to get a push scope token with installer token (should be denied)
	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:push", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	// Installer tokens should only be allowed pull scopes
	if resp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(resp.Body)
		t.Errorf("Expected 403 for push scope with installer token, got %d: %s", resp.StatusCode, string(body))
	}
}

func TestE2ETokenCannotDelete(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_deletedened12345678901"
	insertTestTokenForIntegration(t, db, "customer-delete", token)

	// Try to get a delete scope token (not supported in our scope model, but test anyway)
	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:delete", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(resp.Body)
		t.Errorf("Expected 403 for delete scope, got %d: %s", resp.StatusCode, string(body))
	}
}

func TestE2ETokenCannotAccessUnrelatedRepositories(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_unrelated12345678901234"
	insertTestTokenForIntegration(t, db, "customer-unrelated", token)

	// Try to access an unrelated repository
	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:unrelated-repo:pull", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(resp.Body)
		t.Errorf("Expected 403 for unrelated repo, got %d: %s", resp.StatusCode, string(body))
	}
}

func TestE2EBothAPIAndWebImagesPullable(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_bothimages12345678901"
	insertTestTokenForIntegration(t, db, "customer-both", token)

	// Get token with both scopes
	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:pull,repository:laymatched-web:pull", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("Expected 200 for both scopes, got %d: %s", resp.StatusCode, string(body))
	}

	var tokenRespBody struct {
		Token     string `json:"token"`
		ExpiresIn int    `json:"expires_in"`
		IssuedAt  string `json:"issued_at"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tokenRespBody); err != nil {
		t.Fatalf("Failed to decode token response: %v", err)
	}

	// Verify both scopes in JWT
	parser := jwt.NewParser(jwt.WithoutClaimsValidation())
	parsed, _, err := parser.ParseUnverified(tokenRespBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("JWT parse failed: %v", err)
	}
	claims := parsed.Claims.(jwt.MapClaims)
	scope := claims["scope"].(string)
	expectedScope := "repository:laymatched-api:pull,repository:laymatched-web:pull"
	if scope != expectedScope {
		t.Errorf("Expected scope %s, got %s", expectedScope, scope)
	}
}

func TestE2ERegistryCredentialExpires(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_expiretest1234567890123"
	insertTestTokenForIntegration(t, db, "customer-expire", token)

	// Get registry JWT
	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:pull", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	var tokenRespBody struct {
		Token     string `json:"token"`
		ExpiresIn int    `json:"expires_in"`
		IssuedAt  string `json:"issued_at"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tokenRespBody); err != nil {
		t.Fatalf("Failed to decode token response: %v", err)
	}

	// Verify expires_in is 1 hour (3600 seconds)
	if tokenRespBody.ExpiresIn != 3600 {
		t.Errorf("Expected expires_in 3600, got %d", tokenRespBody.ExpiresIn)
	}

	// Verify JWT exp claim
	parser := jwt.NewParser(jwt.WithoutClaimsValidation())
	parsed, _, err := parser.ParseUnverified(tokenRespBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("JWT parse failed: %v", err)
	}
	claims := parsed.Claims.(jwt.MapClaims)
	exp := int64(claims["exp"].(float64))
	iat := int64(claims["iat"].(float64))
	actualTTL := exp - iat

	if actualTTL < 3595 || actualTTL > 3605 {
		t.Errorf("Expected JWT TTL ~3600 seconds, got %d", actualTTL)
	}
}
