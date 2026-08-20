package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/joho/godotenv"
	"github.com/mattn/go-sqlite3"
	"golang.org/x/crypto/bcrypt"
)

const (
	tokenPrefix       = "lm_inst_"
	ownerTokenPrefix  = "lm_owner_"
	tokenEntropyBytes = 24
	bcryptCost        = 12
	defaultDBPath     = "/data/auth-tokens.db"
)

type Config struct {
	DBPath string
}

func loadConfig() Config {
	_ = godotenv.Load()
	return Config{
		DBPath: getEnv("DB_PATH", defaultDBPath),
	}
}

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func initDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", path+"?_fk=1&_journal_mode=WAL")
	if err != nil {
		return nil, err
	}
	return db, nil
}

func generateToken(prefix string) (string, error) {
	entropy := make([]byte, tokenEntropyBytes)
	if _, err := rand.Read(entropy); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(entropy), nil
}

func hashToken(token string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(token), bcryptCost)
	if err != nil {
		return "", err
	}
	return string(hash), nil
}

func tokenSHA256(token string) string {
	// This is a simplified version - in reality we'd need crypto/sha256
	// But for the CLI tool we just store the bcrypt hash and compute sha256 in the API
	// The tool only needs to generate the token and bcrypt hash
	return ""
}

func issueInstallerToken(customerID, notes string, expiresInDays int) error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	token, err := generateToken(tokenPrefix)
	if err != nil {
		return err
	}

	hash, err := hashToken(token)
	if err != nil {
		return err
	}

	var expiresAt *time.Time
	if expiresInDays > 0 {
		t := time.Now().AddDate(0, 0, expiresInDays)
		expiresAt = &t
	}

	_, err = db.Exec(`
		INSERT INTO installer_tokens (customer_id, token_hash, expires_at, notes)
		VALUES (?, ?, ?, ?)
	`, customerID, hash, expiresAt, notes)
	if err != nil {
		var sqliteErr sqlite3.Error
		if errors.As(err, &sqliteErr) && sqliteErr.ExtendedCode == sqlite3.ErrConstraintUnique {
			return fmt.Errorf("token collision (extremely unlikely), please try again")
		}
		return err
	}

	fmt.Println("=== NEW INSTALLER TOKEN ===")
	fmt.Printf("Customer ID: %s\n", customerID)
	fmt.Printf("Token:       %s\n", token)
	fmt.Printf("Expires:     %s\n", func() string {
		if expiresAt != nil {
			return expiresAt.Format("2006-01-02")
		}
		return "never"
	}())
	fmt.Printf("Notes:       %s\n", notes)
	fmt.Println()
	fmt.Println("IMPORTANT: Save this token now. It cannot be retrieved again.")
	fmt.Println("Only the bcrypt hash is stored in the database.")

	return nil
}

func issueOwnerToken(name, scopes, notes string, expiresInDays int) error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	token, err := generateToken(ownerTokenPrefix)
	if err != nil {
		return err
	}

	hash, err := hashToken(token)
	if err != nil {
		return err
	}

	var expiresAt *time.Time
	if expiresInDays > 0 {
		t := time.Now().AddDate(0, 0, expiresInDays)
		expiresAt = &t
	}

	_, err = db.Exec(`
		INSERT INTO owner_tokens (name, token_hash, scopes, expires_at, notes)
		VALUES (?, ?, ?, ?, ?)
	`, name, hash, scopes, expiresAt, notes)
	if err != nil {
		var sqliteErr sqlite3.Error
		if errors.As(err, &sqliteErr) && sqliteErr.ExtendedCode == sqlite3.ErrConstraintUnique {
			return fmt.Errorf("token collision (extremely unlikely), please try again")
		}
		return err
	}

	fmt.Println("=== NEW OWNER TOKEN ===")
	fmt.Printf("Name:     %s\n", name)
	fmt.Printf("Token:    %s\n", token)
	fmt.Printf("Scopes:   %s\n", scopes)
	fmt.Printf("Expires:  %s\n", func() string {
		if expiresAt != nil {
			return expiresAt.Format("2006-01-02")
		}
		return "never"
	}())
	fmt.Printf("Notes:    %s\n", notes)
	fmt.Println()
	fmt.Println("IMPORTANT: Save this token now. It cannot be retrieved again.")
	fmt.Println("Only the bcrypt hash is stored in the database.")
	fmt.Println()
	fmt.Println("Use this token for CI/CD registry push operations.")
	fmt.Println("Scope must include: repository:laymatched-api:push,repository:laymatched-web:push")

	return nil
}

func listTokens() error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	fmt.Println("=== INSTALLER TOKENS ===")
	rows, err := db.Query(`
		SELECT id, customer_id, created_at, revoked_at, expires_at, notes, last_used_at
		FROM installer_tokens ORDER BY created_at DESC
	`)
	if err != nil {
		return err
	}
	defer rows.Close()

	fmt.Printf("%-4s %-20s %-20s %-10s %-12s %-30s %-20s\n",
		"ID", "CUSTOMER", "CREATED", "REVOKED", "EXPIRES", "NOTES", "LAST USED")
	fmt.Println(strings.Repeat("-", 120))

	hasInstaller := false
	for rows.Next() {
		hasInstaller = true
		var id int64
		var customerID, notes string
		var createdAt, revokedAt, expiresAt, lastUsedAt sql.NullTime
		if err := rows.Scan(&id, &customerID, &createdAt, &revokedAt, &expiresAt, &notes, &lastUsedAt); err != nil {
			return err
		}

		revoked := "no"
		if revokedAt.Valid {
			revoked = "yes"
		}
		expires := "never"
		if expiresAt.Valid {
			expires = expiresAt.Time.Format("2006-01-02")
		}
		lastUsed := "never"
		if lastUsedAt.Valid {
			lastUsed = lastUsedAt.Time.Format("2006-01-02 15:04")
		}
		if len(notes) > 28 {
			notes = notes[:28] + ".."
		}

		fmt.Printf("%-4d %-20s %-20s %-10s %-12s %-30s %-20s\n",
			id, customerID, createdAt.Time.Format("2006-01-02 15:04"), revoked, expires, notes, lastUsed)
	}

	if !hasInstaller {
		fmt.Println("(none)")
	}

	fmt.Println()
	fmt.Println("=== OWNER TOKENS ===")
	rows, err = db.Query(`
		SELECT id, name, created_at, revoked_at, expires_at, scopes, notes, last_used_at
		FROM owner_tokens ORDER BY created_at DESC
	`)
	if err != nil {
		return err
	}
	defer rows.Close()

	fmt.Printf("%-4s %-20s %-20s %-10s %-12s %-40s %-30s %-20s\n",
		"ID", "NAME", "CREATED", "REVOKED", "EXPIRES", "SCOPES", "NOTES", "LAST USED")
	fmt.Println(strings.Repeat("-", 160))

	hasOwner := false
	for rows.Next() {
		hasOwner = true
		var id int64
		var name, scopes, notes string
		var createdAt, revokedAt, expiresAt, lastUsedAt sql.NullTime
		if err := rows.Scan(&id, &name, &createdAt, &revokedAt, &expiresAt, &scopes, &notes, &lastUsedAt); err != nil {
			return err
		}

		revoked := "no"
		if revokedAt.Valid {
			revoked = "yes"
		}
		expires := "never"
		if expiresAt.Valid {
			expires = expiresAt.Time.Format("2006-01-02")
		}
		lastUsed := "never"
		if lastUsedAt.Valid {
			lastUsed = lastUsedAt.Time.Format("2006-01-02 15:04")
		}
		if len(scopes) > 38 {
			scopes = scopes[:38] + ".."
		}
		if len(notes) > 28 {
			notes = notes[:28] + ".."
		}

		fmt.Printf("%-4d %-20s %-20s %-10s %-12s %-40s %-30s %-20s\n",
			id, name, createdAt.Time.Format("2006-01-02 15:04"), revoked, expires, scopes, notes, lastUsed)
	}

	if !hasOwner {
		fmt.Println("(none)")
	}

	return rows.Err()
}

func revokeToken(id int64, tokenType string) error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	table := "installer_tokens"
	if tokenType == "owner" {
		table = "owner_tokens"
	}

	result, err := db.Exec(fmt.Sprintf(`
		UPDATE %s SET revoked_at = CURRENT_TIMESTAMP
		WHERE id = ? AND revoked_at IS NULL
	`, table), id)
	if err != nil {
		return err
	}

	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if affected == 0 {
		return fmt.Errorf("token not found or already revoked")
	}

	fmt.Printf("%s token %d revoked successfully\n", strings.Title(tokenType), id)
	return nil
}

func deleteToken(id int64, tokenType string) error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	table := "installer_tokens"
	if tokenType == "owner" {
		table = "owner_tokens"
	}

	result, err := db.Exec(fmt.Sprintf(`DELETE FROM %s WHERE id = ?`, table), id)
	if err != nil {
		return err
	}

	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if affected == 0 {
		return fmt.Errorf("token not found")
	}

	fmt.Printf("%s token %d deleted permanently\n", strings.Title(tokenType), id)
	return nil
}

func printUsage() {
	fmt.Println("Usage: token-tool <command> [args]")
	fmt.Println()
	fmt.Println("Commands:")
	fmt.Println("  issue-installer <customer-id> [notes] [--expire-days N]  Issue new installer token")
	fmt.Println("  issue-owner <name> <scopes> [notes] [--expire-days N]    Issue new owner token (for CI/CD)")
	fmt.Println("  list                                           List all tokens")
	fmt.Println("  revoke-installer <id>                          Revoke an installer token")
	fmt.Println("  revoke-owner <id>                              Revoke an owner token")
	fmt.Println("  delete-installer <id>                          Permanently delete an installer token")
	fmt.Println("  delete-owner <id>                              Permanently delete an owner token")
	fmt.Println()
	fmt.Println("Environment:")
	fmt.Println("  DB_PATH    Path to SQLite database (default: /data/auth-tokens.db)")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  token-tool issue-installer customer-123 \"Founding member\" --expire-days 365")
	fmt.Println("  token-tool issue-owner ci-cd \"repository:laymatched-api:push,repository:laymatched-web:push\" \"GitHub Actions\" --expire-days 365")
	fmt.Println("  token-tool list")
	fmt.Println("  token-tool revoke-installer 1")
	fmt.Println("  token-tool revoke-owner 2")
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
	}

	cmd := os.Args[1]

	switch cmd {
	case "issue-installer":
		if len(os.Args) < 3 {
			printUsage()
		}
		customerID := os.Args[2]
		notes := ""
		expireDays := 365

		for i := 3; i < len(os.Args); i++ {
			if os.Args[i] == "--expire-days" && i+1 < len(os.Args) {
				fmt.Sscanf(os.Args[i+1], "%d", &expireDays)
				i++
			} else if notes == "" && os.Args[i] != "--expire-days" {
				notes = os.Args[i]
			}
		}

		if err := issueInstallerToken(customerID, notes, expireDays); err != nil {
			log.Fatalf("Failed to issue token: %v", err)
		}

	case "issue-owner":
		if len(os.Args) < 4 {
			printUsage()
		}
		name := os.Args[2]
		scopes := os.Args[3]
		notes := ""
		expireDays := 365

		for i := 4; i < len(os.Args); i++ {
			if os.Args[i] == "--expire-days" && i+1 < len(os.Args) {
				fmt.Sscanf(os.Args[i+1], "%d", &expireDays)
				i++
			} else if notes == "" && os.Args[i] != "--expire-days" {
				notes = os.Args[i]
			}
		}

		if err := issueOwnerToken(name, scopes, notes, expireDays); err != nil {
			log.Fatalf("Failed to issue owner token: %v", err)
		}

	case "list":
		if err := listTokens(); err != nil {
			log.Fatalf("Failed to list tokens: %v", err)
		}

	case "revoke-installer":
		if len(os.Args) < 3 {
			printUsage()
		}
		var id int64
		fmt.Sscanf(os.Args[2], "%d", &id)
		if err := revokeToken(id, "installer"); err != nil {
			log.Fatalf("Failed to revoke token: %v", err)
		}

	case "revoke-owner":
		if len(os.Args) < 3 {
			printUsage()
		}
		var id int64
		fmt.Sscanf(os.Args[2], "%d", &id)
		if err := revokeToken(id, "owner"); err != nil {
			log.Fatalf("Failed to revoke token: %v", err)
		}

	case "delete-installer":
		if len(os.Args) < 3 {
			printUsage()
		}
		var id int64
		fmt.Sscanf(os.Args[2], "%d", &id)
		if err := deleteToken(id, "installer"); err != nil {
			log.Fatalf("Failed to delete token: %v", err)
		}

	case "delete-owner":
		if len(os.Args) < 3 {
			printUsage()
		}
		var id int64
		fmt.Sscanf(os.Args[2], "%d", &id)
		if err := deleteToken(id, "owner"); err != nil {
			log.Fatalf("Failed to delete token: %v", err)
		}

	default:
		printUsage()
	}
}