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
	tokenPrefix      = "lm_inst_"
	tokenEntropyBytes = 24
	bcryptCost       = 12
	defaultDBPath    = "/data/auth-tokens.db"
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

func generateToken() (string, error) {
	entropy := make([]byte, tokenEntropyBytes)
	if _, err := rand.Read(entropy); err != nil {
		return "", err
	}
	return tokenPrefix + base64.RawURLEncoding.EncodeToString(entropy), nil
}

func hashToken(token string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(token), bcryptCost)
	if err != nil {
		return "", err
	}
	return string(hash), nil
}

func issueToken(customerID, notes string, expiresInDays int) error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	token, err := generateToken()
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

func listTokens() error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

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

	for rows.Next() {
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

	return rows.Err()
}

func revokeToken(id int64) error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	result, err := db.Exec(`
		UPDATE installer_tokens SET revoked_at = CURRENT_TIMESTAMP
		WHERE id = ? AND revoked_at IS NULL
	`, id)
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

	fmt.Printf("Token %d revoked successfully\n", id)
	return nil
}

func deleteToken(id int64) error {
	cfg := loadConfig()
	db, err := initDB(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	result, err := db.Exec(`DELETE FROM installer_tokens WHERE id = ?`, id)
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

	fmt.Printf("Token %d deleted permanently\n", id)
	return nil
}

func printUsage() {
	fmt.Println("Usage: token-tool <command> [args]")
	fmt.Println()
	fmt.Println("Commands:")
	fmt.Println("  issue <customer-id> [notes] [--expire-days N]  Issue new installer token")
	fmt.Println("  list                                           List all tokens")
	fmt.Println("  revoke <id>                                    Revoke a token")
	fmt.Println("  delete <id>                                    Permanently delete a token")
	fmt.Println()
	fmt.Println("Environment:")
	fmt.Println("  DB_PATH    Path to SQLite database (default: /data/auth-tokens.db)")
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
	}

	cmd := os.Args[1]

	switch cmd {
	case "issue":
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

		if err := issueToken(customerID, notes, expireDays); err != nil {
			log.Fatalf("Failed to issue token: %v", err)
		}

	case "list":
		if err := listTokens(); err != nil {
			log.Fatalf("Failed to list tokens: %v", err)
		}

	case "revoke":
		if len(os.Args) < 3 {
			printUsage()
		}
		var id int64
		fmt.Sscanf(os.Args[2], "%d", &id)
		if err := revokeToken(id); err != nil {
			log.Fatalf("Failed to revoke token: %v", err)
		}

	case "delete":
		if len(os.Args) < 3 {
			printUsage()
		}
		var id int64
		fmt.Sscanf(os.Args[2], "%d", &id)
		if err := deleteToken(id); err != nil {
			log.Fatalf("Failed to delete token: %v", err)
		}

	default:
		printUsage()
	}
}