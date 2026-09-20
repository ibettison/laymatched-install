package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func openTokenTestDB(t *testing.T) *sql.DB {
	t.Helper()

	db, err := initDB(filepath.Join(t.TempDir(), "auth-tokens.db"))
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
	);`
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		t.Fatalf("create temporary authorisation schema: %v", err)
	}

	t.Cleanup(func() { db.Close() })
	return db
}

func expectedTokenSHA256(token string) string {
	sum := sha256.Sum256([]byte(token))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func TestTokenSHA256UsesAuthorisationAPIVerificationEncoding(t *testing.T) {
	token := "lm_inst_testtoken12345678901234"
	got := tokenSHA256(token)

	if got != expectedTokenSHA256(token) {
		t.Fatalf("SHA-256 encoding does not match the authorisation API contract")
	}
	if len(got) != 43 {
		t.Fatalf("expected unpadded SHA-256 encoding length 43, got %d", len(got))
	}
	if got[len(got)-1] == '=' {
		t.Fatal("SHA-256 encoding must not contain padding")
	}
}

func TestIssueInstallerTokenStoresBothAuthorisationHashes(t *testing.T) {
	db := openTokenTestDB(t)

	token, _, err := issueInstallerTokenWithDB(db, "customer-test", "temporary test row", 30)
	if err != nil {
		t.Fatalf("issue installer token: %v", err)
	}

	var storedSHA256, storedBcrypt string
	err = db.QueryRow(`
		SELECT token_sha256, token_hash
		FROM installer_tokens
		WHERE customer_id = ?
	`, "customer-test").Scan(&storedSHA256, &storedBcrypt)
	if err != nil {
		t.Fatalf("read issued installer token row: %v", err)
	}
	if storedSHA256 != expectedTokenSHA256(token) {
		t.Fatal("stored installer SHA-256 does not match the authorisation API lookup key")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(storedBcrypt), []byte(token)); err != nil {
		t.Fatalf("stored installer bcrypt hash does not verify: %v", err)
	}

	// This is the same indexed lookup performed by auth-api before bcrypt
	// verification. It proves the issued row is discoverable by that service.
	var foundID int64
	if err := db.QueryRow(
		`SELECT id FROM installer_tokens WHERE token_sha256 = ?`,
		expectedTokenSHA256(token),
	).Scan(&foundID); err != nil || foundID == 0 {
		t.Fatalf("authorisation API lookup could not find issued installer token")
	}
}

func TestIssueOwnerTokenStoresBothAuthorisationHashes(t *testing.T) {
	db := openTokenTestDB(t)

	token, _, err := issueOwnerTokenWithDB(db, "release-test", "repository:test:pull", "temporary test row", 30)
	if err != nil {
		t.Fatalf("issue owner token: %v", err)
	}

	var storedSHA256, storedBcrypt string
	err = db.QueryRow(`
		SELECT token_sha256, token_hash
		FROM owner_tokens
		WHERE name = ?
	`, "release-test").Scan(&storedSHA256, &storedBcrypt)
	if err != nil {
		t.Fatalf("read issued owner token row: %v", err)
	}
	if storedSHA256 != expectedTokenSHA256(token) {
		t.Fatal("stored owner SHA-256 does not match the authorisation API lookup key")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(storedBcrypt), []byte(token)); err != nil {
		t.Fatalf("stored owner bcrypt hash does not verify: %v", err)
	}

	var foundID int64
	if err := db.QueryRow(
		`SELECT id FROM owner_tokens WHERE token_sha256 = ?`,
		expectedTokenSHA256(token),
	).Scan(&foundID); err != nil || foundID == 0 {
		t.Fatalf("authorisation API lookup could not find issued owner token")
	}
}
