package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"
)

var tokenToolOutputToken = regexp.MustCompile(`(?m)^Token:\s+(\S+)\s*$`)

func generateTokenToolIntegrationKeys(t *testing.T) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate integration signing key: %v", err)
	}
	privateKey = key
	publicKey = &key.PublicKey
}

func setupTokenToolIntegrationDB(t *testing.T) (*sql.DB, string) {
	t.Helper()

	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "auth-tokens.db")
	approvedVersionPath = filepath.Join(tmpDir, "approved_version.txt")
	if err := os.WriteFile(approvedVersionPath, []byte("v9.9.9"), 0644); err != nil {
		t.Fatalf("write temporary approved version: %v", err)
	}

	db, err := sql.Open("sqlite3", dbPath+"?_fk=1&_journal_mode=WAL")
	if err != nil {
		t.Fatalf("open temporary database: %v", err)
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

	CREATE TABLE owner_tokens (
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
	CREATE INDEX idx_owner_token_sha256 ON owner_tokens(token_sha256);`
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		t.Fatalf("create temporary authorisation schema: %v", err)
	}

	t.Cleanup(func() { db.Close() })
	return db, dbPath
}

func issueTokenWithTool(t *testing.T, dbPath string, args ...string) string {
	t.Helper()

	_, testFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate token-tool integration test")
	}
	toolDir := filepath.Join(filepath.Dir(testFile), "..", "tools", "token-tool")
	commandArgs := append([]string{"run", "."}, args...)
	cmd := exec.Command("go", commandArgs...)
	cmd.Dir = toolDir
	environment := make([]string, 0, len(os.Environ())+1)
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "DB_PATH=") {
			environment = append(environment, value)
		}
	}
	cmd.Env = append(environment, "DB_PATH="+dbPath)
	output, err := cmd.Output()
	if err != nil {
		// Do not include command output: a successful issuance prints the
		// plaintext token, and test failures must not disclose credentials.
		t.Fatalf("token-tool issuance failed: %v", err)
	}

	matches := tokenToolOutputToken.FindSubmatch(output)
	if len(matches) != 2 {
		t.Fatal("token-tool did not return an issued token")
	}
	return string(matches[1])
}

func installerAuthorizeStatus(t *testing.T, router http.Handler, token string) (int, AuthorizeResponse) {
	t.Helper()

	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(
		http.MethodPost,
		"/installer/authorize",
		bytes.NewBufferString(`{"installer_token":"`+token+`"}`),
	)
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(recorder, req)

	var response AuthorizeResponse
	if recorder.Code == http.StatusOK {
		if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
			t.Fatalf("decode successful authorisation response: %v", err)
		}
	}
	return recorder.Code, response
}

func TestTokenToolAgainstActualAuthorisationHandler(t *testing.T) {
	dbForAPI, dbPath := setupTokenToolIntegrationDB(t)
	generateTokenToolIntegrationKeys(t)
	db = dbForAPI
	cfg = Config{
		RegistryURL:     "registry.test.invalid",
		ActivationURL:   "https://matched.laysports.co.uk",
		RateLimitPerMin: 1000,
	}
	rateLimiter = NewRateLimiter(cfg.RateLimitPerMin, time.Minute)
	approvedVersion = refreshApprovedVersion()
	router := setupRouter()

	installerToken := issueTokenWithTool(t, dbPath, "issue-installer", "customer-integration", "temporary test row", "--expire-days", "1")
	status, response := installerAuthorizeStatus(t, router, installerToken)
	if status != http.StatusOK {
		t.Fatalf("actual authorisation handler rejected token with status %d", status)
	}
	if response.RegistryToken != installerToken || response.ApprovedVersion != "v9.9.9" || response.RegistryURL != "registry.test.invalid" || response.ActivationURL != "https://matched.laysports.co.uk" {
		t.Fatal("actual authorisation handler returned unexpected success response")
	}

	if status, _ := installerAuthorizeStatus(t, router, "lm_inst_not_issued_by_tool"); status != http.StatusUnauthorized {
		t.Fatalf("expected rejected installer token to return 401, got %d", status)
	}

	if _, err := db.Exec(
		`UPDATE installer_tokens SET expires_at = datetime('now', '-1 hour') WHERE token_sha256 = ?`,
		tokenSHA256(installerToken),
	); err != nil {
		t.Fatalf("expire issued installer token: %v", err)
	}
	if status, _ := installerAuthorizeStatus(t, router, installerToken); status != http.StatusUnauthorized {
		t.Fatalf("expected expired installer token to return 401, got %d", status)
	}

	revokedToken := issueTokenWithTool(t, dbPath, "issue-installer", "customer-revoked", "temporary test row", "--expire-days", "1")
	if _, err := db.Exec(
		`UPDATE installer_tokens SET revoked_at = CURRENT_TIMESTAMP WHERE token_sha256 = ?`,
		tokenSHA256(revokedToken),
	); err != nil {
		t.Fatalf("revoke issued installer token: %v", err)
	}
	if status, _ := installerAuthorizeStatus(t, router, revokedToken); status != http.StatusUnauthorized {
		t.Fatalf("expected revoked installer token to return 401, got %d", status)
	}

	ownerToken := issueTokenWithTool(t, dbPath, "issue-owner", "owner-integration", "repository:laymatched-api:pull", "temporary test row", "--expire-days", "1")
	ownerCredentials := base64.StdEncoding.EncodeToString([]byte("test-owner:" + ownerToken))
	ownerRequest := httptest.NewRequest(
		http.MethodGet,
		"/token?service=registry.test.invalid&scope=repository:laymatched-api:pull",
		nil,
	)
	ownerRequest.Header.Set("Authorization", "Basic "+ownerCredentials)
	ownerRecorder := httptest.NewRecorder()
	router.ServeHTTP(ownerRecorder, ownerRequest)
	if ownerRecorder.Code != http.StatusOK {
		t.Fatalf("actual token handler rejected tool-issued owner token with status %d", ownerRecorder.Code)
	}
	var ownerResponse TokenServiceResponse
	if err := json.Unmarshal(ownerRecorder.Body.Bytes(), &ownerResponse); err != nil || ownerResponse.Token == "" {
		t.Fatalf("actual token handler returned invalid owner exchange response")
	}
}
