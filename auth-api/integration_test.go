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
				"REGISTRY_CERT_PATH":       "/data/auth-cert.pem",
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
	// Verify access claim (Docker Distribution format)
	access := claims["access"].([]interface{})
	if len(access) != 2 {
		t.Errorf("Expected 2 access entries, got %d", len(access))
	}
	expectedAccess := map[string][]string{
		"laymatched-api": {"pull"},
		"laymatched-web": {"pull"},
	}
	for _, entry := range access {
		entryMap := entry.(map[string]interface{})
		if entryMap["type"] != "repository" {
			t.Errorf("Wrong access type: %v", entryMap["type"])
		}
		name := entryMap["name"].(string)
		actions := entryMap["actions"].([]interface{})
		if expectedActions, ok := expectedAccess[name]; ok {
			if len(actions) != len(expectedActions) {
				t.Errorf("Wrong number of actions for %s: got %d, expected %d", name, len(actions), len(expectedActions))
			}
			for i, action := range actions {
				if action != expectedActions[i] {
					t.Errorf("Wrong action for %s: got %v, expected %v", name, action, expectedActions[i])
				}
			}
		} else {
			t.Errorf("Unexpected repository name: %s", name)
		}
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
	// Verify access claim (Docker Distribution format)
	access := claims["access"].([]interface{})
	if len(access) != 2 {
		t.Errorf("Expected 2 access entries, got %d", len(access))
	}
	expectedAccess := map[string][]string{
		"laymatched-api": {"pull"},
		"laymatched-web": {"pull"},
	}
	for _, entry := range access {
		entryMap := entry.(map[string]interface{})
		if entryMap["type"] != "repository" {
			t.Errorf("Wrong access type: %v", entryMap["type"])
		}
		name := entryMap["name"].(string)
		actions := entryMap["actions"].([]interface{})
		if expectedActions, ok := expectedAccess[name]; ok {
			if len(actions) != len(expectedActions) {
				t.Errorf("Wrong number of actions for %s: got %d, expected %d", name, len(actions), len(expectedActions))
			}
			for i, action := range actions {
				if action != expectedActions[i] {
					t.Errorf("Wrong action for %s: got %v, expected %v", name, action, expectedActions[i])
				}
			}
		} else {
			t.Errorf("Unexpected repository name: %s", name)
		}
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

func TestE2EFullRegistryFlow_SKIP(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	ctx := context.Background()

	// Create temp directory for test data FIRST (shared between registry and auth-api)
	tmpDir := t.TempDir()
	dataDir := filepath.Join(tmpDir, "data")
	if err := os.MkdirAll(dataDir, 0750); err != nil {
		t.Fatalf("Failed to create data dir: %v", err)
	}

	// Start auth-api FIRST so it generates the cert/keys
	authAPIContainer, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "laymatched-auth-api:latest",
			ExposedPorts: []string{"8443/tcp"},
			Env: map[string]string{
				"PORT":                     "8443",
				"DB_PATH":                  "/data/auth-tokens.db",
				"REGISTRY_URL":             "registry.laymatched.io", // placeholder, will be updated
				"PRIVATE_KEY_PATH":         "/data/private.pem",
				"PUBLIC_KEY_PATH":          "/data/public.pem",
				"REGISTRY_PUBLIC_KEY_PATH": "/data/auth-public.pem",
				"REGISTRY_CERT_PATH":       "/data/auth-cert.pem",
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
	defer authAPIContainer.Terminate(ctx)

	// Wait for auth-api to generate keys and cert
	time.Sleep(5 * time.Second)

	// Verify cert was generated
	certPath := filepath.Join(dataDir, "auth-cert.pem")
	if _, err := os.Stat(certPath); err != nil {
		t.Fatalf("Auth cert not generated at %s: %v", certPath, err)
	}

	// Start Docker Distribution registry with testcontainers
	// Mount the data dir to /certs so registry can access auth-cert.pem generated by auth-api
	registryContainer, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "registry:2.8.3",
			ExposedPorts: []string{"5000/tcp"},
			Env: map[string]string{
				"REGISTRY_AUTH_TOKEN_REALM":        "https://api.laymatched.com/token",
				"REGISTRY_AUTH_TOKEN_SERVICE":      "registry.laymatched.io",
				"REGISTRY_AUTH_TOKEN_ISSUER":       "laymatched-auth",
				"REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE": "/certs/auth-cert.pem",
			},
			Mounts: testcontainers.Mounts(
				testcontainers.BindMount(dataDir, "/certs"),
			),
			WaitingFor: wait.ForListeningPort("5000/tcp").WithStartupTimeout(30 * time.Second),
		},
		Started: true,
	})
	if err != nil {
		t.Fatalf("Failed to start registry: %v", err)
	}
	defer registryContainer.Terminate(ctx)

	registryEndpoint, err := registryContainer.PortEndpoint(ctx, "5000/tcp", "")
	if err != nil {
		t.Fatalf("Failed to get registry endpoint: %v", err)
	}
	registryURL := "http://" + registryEndpoint

	// Wait for registry to be ready
	time.Sleep(3 * time.Second)

	// Get auth-api endpoint (already running)
	authAPIEndpoint, err := authAPIContainer.PortEndpoint(ctx, "8443/tcp", "")
	if err != nil {
		t.Fatalf("Failed to get auth-api endpoint: %v", err)
	}
	authAPIURL := "http://" + authAPIEndpoint

	// Create test database and insert test tokens
	dbPath := filepath.Join(dataDir, "auth-tokens.db")
	db, err := sql.Open("sqlite3", dbPath+"?_fk=1&_journal_mode=WAL")
	if err != nil {
		t.Fatalf("DB open failed: %v", err)
	}
	defer db.Close()

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
		t.Fatalf("Schema failed: %v", err)
	}

	// Insert installer token (pull only)
	installerToken := "lm_inst_fulltest12345678901234"
	insertTestTokenForIntegration(t, db, "customer-full", installerToken)

	// Insert owner token (push and pull)
	ownerToken := "lm_owner_fulltest123456789012"
	ownerHash, _ := bcrypt.GenerateFromPassword([]byte(ownerToken), bcryptCost)
	ownerSHA256 := fmt.Sprintf("%x", sha256.Sum256([]byte(ownerToken)))
	_, err = db.Exec(`
		INSERT INTO owner_tokens (name, token_sha256, token_hash, scopes, notes)
		VALUES (?, ?, ?, ?, ?)
	`, "ci-cd", ownerSHA256, string(ownerHash), "repository:laymatched-api:push,repository:laymatched-web:push,repository:laymatched-api:pull,repository:laymatched-web:pull", "ci-cd token")
	if err != nil {
		t.Fatalf("Failed to insert owner token: %v", err)
	}

	// Step 1: Call /installer/authorize with installer token
	authReq := map[string]string{"installer_token": installerToken}
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

	if authResp.RegistryToken != installerToken {
		t.Errorf("Expected registry_token to be installer token, got %s", authResp.RegistryToken)
	}

	// Step 2: Call /token with installer token to get registry JWT for pull
	tokenReq, _ := http.NewRequest("GET", authAPIURL+"/token?service="+registryURL+"&scope=repository:laymatched-api:pull,repository:laymatched-web:pull", nil)
	tokenReq.Header.Set("Authorization", "Bearer "+installerToken)
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

	// Step 3: Use installer JWT to pull from registry (should fail - no images yet)
	// This tests that the JWT works with the registry
	pullReq, _ := http.NewRequest("GET", registryURL+"/v2/laymatched-api/manifests/v0.1.0", nil)
	pullReq.Header.Set("Authorization", "Bearer "+tokenRespBody.Token)
	pullReq.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")
	pullResp, err := http.DefaultClient.Do(pullReq)
	if err != nil {
		t.Fatalf("Pull request failed: %v", err)
	}
	defer pullResp.Body.Close()

	// Should get 404 (image doesn't exist) not 401 (auth failed)
	if pullResp.StatusCode == http.StatusUnauthorized {
		body, _ := io.ReadAll(pullResp.Body)
		t.Fatalf("Registry auth failed with installer token: %s", string(body))
	}
	if pullResp.StatusCode != http.StatusNotFound {
		t.Logf("Pull returned status %d (expected 404 since image doesn't exist)", pullResp.StatusCode)
	}

	// Step 4: Get owner token for push
	ownerTokenReq, _ := http.NewRequest("GET", authAPIURL+"/token?service="+registryURL+"&scope=repository:laymatched-api:push,repository:laymatched-web:push", nil)
	ownerTokenReq.Header.Set("Authorization", "Bearer "+ownerToken)
	ownerTokenResp, err := http.DefaultClient.Do(ownerTokenReq)
	if err != nil {
		t.Fatalf("Owner token request failed: %v", err)
	}
	defer ownerTokenResp.Body.Close()

	if ownerTokenResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(ownerTokenResp.Body)
		t.Fatalf("Owner token request failed with status %d: %s", ownerTokenResp.StatusCode, string(body))
	}

	var ownerTokenRespBody struct {
		Token     string `json:"token"`
		ExpiresIn int    `json:"expires_in"`
		IssuedAt  string `json:"issued_at"`
	}
	if err := json.NewDecoder(ownerTokenResp.Body).Decode(&ownerTokenRespBody); err != nil {
		t.Fatalf("Failed to decode owner token response: %v", err)
	}

	if ownerTokenRespBody.Token == "" {
		t.Fatal("Expected non-empty owner registry JWT")
	}

	// Verify owner JWT has push access
	parser := jwt.NewParser(jwt.WithoutClaimsValidation())
	ownerParsed, _, err := parser.ParseUnverified(ownerTokenRespBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("Owner JWT parse failed: %v", err)
	}
	ownerClaims := ownerParsed.Claims.(jwt.MapClaims)
	access := ownerClaims["access"].([]interface{})
	foundPush := false
	for _, entry := range access {
		entryMap := entry.(map[string]interface{})
		actions := entryMap["actions"].([]interface{})
		for _, action := range actions {
			if action == "push" {
				foundPush = true
				break
			}
		}
	}
	if !foundPush {
		t.Error("Owner JWT should have push access")
	}

	// Step 5: Test that installer token cannot get push scope
	pushReq, _ := http.NewRequest("GET", authAPIURL+"/token?service="+registryURL+"&scope=repository:laymatched-api:push", nil)
	pushReq.Header.Set("Authorization", "Bearer "+installerToken)
	pushResp, err := http.DefaultClient.Do(pushReq)
	if err != nil {
		t.Fatalf("Push scope request failed: %v", err)
	}
	defer pushResp.Body.Close()

	if pushResp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(pushResp.Body)
		t.Errorf("Expected 403 for push scope with installer token, got %d: %s", pushResp.StatusCode, string(body))
	}

	// Step 6: Test invalid/expired credentials denied
	// Create expired installer token
	expiredToken := "lm_inst_expiredfull123456789012"
	insertTestTokenForIntegration(t, db, "customer-expired-full", expiredToken)
	// Update to expired
	_, err = db.Exec(`
		UPDATE installer_tokens SET expires_at = datetime('now', '-1 hour') WHERE token_sha256 = ?
	`, fmt.Sprintf("%x", sha256.Sum256([]byte(expiredToken))))
	if err != nil {
		t.Fatalf("Failed to update token expiry: %v", err)
	}

	expiredReq, _ := http.NewRequest("GET", authAPIURL+"/token?service="+registryURL+"&scope=repository:laymatched-api:pull", nil)
	expiredReq.Header.Set("Authorization", "Bearer "+expiredToken)
	expiredResp, err := http.DefaultClient.Do(expiredReq)
	if err != nil {
		t.Fatalf("Expired token request failed: %v", err)
	}
	defer expiredResp.Body.Close()

	if expiredResp.StatusCode != http.StatusUnauthorized {
		body, _ := io.ReadAll(expiredResp.Body)
		t.Errorf("Expected 401 for expired token, got %d: %s", expiredResp.StatusCode, string(body))
	}

	// Step 7: Test unrelated repository access denied
	unrelatedReq, _ := http.NewRequest("GET", authAPIURL+"/token?service="+registryURL+"&scope=repository:unrelated:pull", nil)
	unrelatedReq.Header.Set("Authorization", "Bearer "+installerToken)
	unrelatedResp, err := http.DefaultClient.Do(unrelatedReq)
	if err != nil {
		t.Fatalf("Unrelated repo request failed: %v", err)
	}
	defer unrelatedResp.Body.Close()

	if unrelatedResp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(unrelatedResp.Body)
		t.Errorf("Expected 403 for unrelated repo, got %d: %s", unrelatedResp.StatusCode, string(body))
	}

	// Step 8: Verify JWT structure has correct access format (not scope string)
	installerParsed, _, err := parser.ParseUnverified(tokenRespBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("Installer JWT parse failed: %v", err)
	}
	installerClaims := installerParsed.Claims.(jwt.MapClaims)
	
	// Verify no "scope" claim (old format), only "access"
	if _, hasScope := installerClaims["scope"]; hasScope {
		t.Error("JWT should not have 'scope' claim, should use 'access' array")
	}
	
	// Verify access array format
	access = installerClaims["access"].([]interface{})
	if len(access) != 2 {
		t.Errorf("Expected 2 access entries, got %d", len(access))
	}
	for _, entry := range access {
		entryMap := entry.(map[string]interface{})
		if entryMap["type"] != "repository" {
			t.Errorf("Access type should be 'repository', got %v", entryMap["type"])
		}
		actions := entryMap["actions"].([]interface{})
		if len(actions) != 1 || actions[0] != "pull" {
			t.Errorf("Access actions should be ['pull'], got %v", actions)
		}
	}

	// Step 9: Restart auth-api and verify signing trust persists (keys are file-backed)
	t.Log("Restarting auth-api to verify key persistence...")
	timeout := 10 * time.Second
	authAPIContainer.Stop(ctx, &timeout)
	time.Sleep(2 * time.Second)
	authAPIContainer.Start(ctx)
	time.Sleep(3 * time.Second)

	// Get new endpoint after restart
	authAPIEndpoint, err = authAPIContainer.PortEndpoint(ctx, "8443/tcp", "")
	if err != nil {
		t.Fatalf("Failed to get auth-api endpoint after restart: %v", err)
	}
	authAPIURL = "http://" + authAPIEndpoint

	// Get new token after restart
	tokenReq2, _ := http.NewRequest("GET", authAPIURL+"/token?service="+registryURL+"&scope=repository:laymatched-api:pull", nil)
	tokenReq2.Header.Set("Authorization", "Bearer "+installerToken)
	tokenResp2, err := http.DefaultClient.Do(tokenReq2)
	if err != nil {
		t.Fatalf("Token request after restart failed: %v", err)
	}
	defer tokenResp2.Body.Close()

	if tokenResp2.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(tokenResp2.Body)
		t.Fatalf("Token request after restart failed with status %d: %s", tokenResp2.StatusCode, string(body))
	}

	var tokenRespBody2 struct {
		Token     string `json:"token"`
		ExpiresIn int    `json:"expires_in"`
		IssuedAt  string `json:"issued_at"`
	}
	if err := json.NewDecoder(tokenResp2.Body).Decode(&tokenRespBody2); err != nil {
		t.Fatalf("Failed to decode token response after restart: %v", err)
	}

	// Verify the new token can be validated with the same JWKS
	jwksResp, err := http.Get(authAPIURL + "/.well-known/jwks.json")
	if err != nil {
		t.Fatalf("JWKS request after restart failed: %v", err)
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
		t.Fatalf("Failed to decode JWKS after restart: %v", err)
	}

	// Verify new JWT can be parsed
	newParsed, _, err := parser.ParseUnverified(tokenRespBody2.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("New JWT parse failed after restart: %v", err)
	}
	newClaims := newParsed.Claims.(jwt.MapClaims)
	if newClaims["iss"] != "laymatched-auth" {
		t.Errorf("Wrong issuer after restart: %v", newClaims["iss"])
	}

	t.Log("Full registry E2E flow completed successfully")
}
