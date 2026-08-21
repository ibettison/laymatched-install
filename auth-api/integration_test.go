//go:build integration

package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
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
	integrationTestTimeout = 180 * time.Second
)

func setupAuthAPITest(t *testing.T) (string, string, func(), *sql.DB) {
	ctx := context.Background()

	tmpDir := filepath.Join("/tmp", "auth-api-test-"+fmt.Sprintf("%d", time.Now().UnixNano()))
	dataDir := filepath.Join(tmpDir, "data")
	if err := os.MkdirAll(dataDir, 0777); err != nil {
		t.Fatalf("Failed to create data dir: %v", err)
	}

	if err := os.WriteFile(filepath.Join(dataDir, "approved_version.txt"), []byte("v0.1.0"), 0644); err != nil {
		t.Fatalf("Failed to create approved_version.txt: %v", err)
	}

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

	time.Sleep(3 * time.Second)

	authAPIEndpoint, err := authAPIContainer.PortEndpoint(ctx, "8443/tcp", "")
	if err != nil {
		t.Fatalf("Failed to get auth-api endpoint: %v", err)
	}
	authAPIURL := "http://" + authAPIEndpoint

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
		os.RemoveAll(tmpDir)
	}

	return authAPIURL, dataDir, cleanup, db
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

func insertOwnerTokenForIntegration(t *testing.T, db *sql.DB, name, token, scopes string) {
	hash, err := bcrypt.GenerateFromPassword([]byte(token), bcryptCost)
	if err != nil {
		t.Fatalf("Hash failed: %v", err)
	}
	sum := sha256.Sum256([]byte(token))
	sha256Hash := hex.EncodeToString(sum[:])

	_, err = db.Exec(`
		INSERT INTO owner_tokens (name, token_sha256, token_hash, scopes, notes)
		VALUES (?, ?, ?, ?, ?)
	`, name, sha256Hash, string(hash), scopes, "integration test owner token")
	if err != nil {
		t.Fatalf("Insert owner token failed: %v", err)
	}
}

func getInstallerRegistryToken(t *testing.T, authAPIURL, registryURL, installerToken string) string {
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
	return tokenRespBody.Token
}

func getOwnerRegistryToken(t *testing.T, authAPIURL, registryURL, ownerToken string) string {
	tokenReq, _ := http.NewRequest("GET", authAPIURL+"/token?service="+registryURL+"&scope=repository:laymatched-api:push,repository:laymatched-web:push,repository:laymatched-api:pull,repository:laymatched-web:pull", nil)
	tokenReq.Header.Set("Authorization", "Bearer "+ownerToken)
	tokenResp, err := http.DefaultClient.Do(tokenReq)
	if err != nil {
		t.Fatalf("Owner token request failed: %v", err)
	}
	defer tokenResp.Body.Close()

	if tokenResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(tokenResp.Body)
		t.Fatalf("Owner token request failed with status %d: %s", tokenResp.StatusCode, string(body))
	}

	var tokenRespBody struct {
		Token     string `json:"token"`
		ExpiresIn int    `json:"expires_in"`
		IssuedAt  string `json:"issued_at"`
	}
	if err := json.NewDecoder(tokenResp.Body).Decode(&tokenRespBody); err != nil {
		t.Fatalf("Failed to decode owner token response: %v", err)
	}

	if tokenRespBody.Token == "" {
		t.Fatal("Expected non-empty owner registry JWT")
	}
	return tokenRespBody.Token
}

func dockerLogin(t *testing.T, registryURL, username, password string) {
	cmd := exec.Command("docker", "login", registryURL, "-u", username, "-p", password)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("docker login failed: %v\n%s", err, string(output))
	}
}

func dockerLogout(t *testing.T, registryURL string) {
	cmd := exec.Command("docker", "logout", registryURL)
	cmd.Run()
}

func dockerTag(t *testing.T, sourceImage, targetImage string) {
	cmd := exec.Command("docker", "tag", sourceImage, targetImage)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("docker tag failed: %v\n%s", err, string(output))
	}
}

func dockerPush(t *testing.T, image string) {
	cmd := exec.Command("docker", "push", image)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("docker push failed: %v\n%s", err, string(output))
	}
}

func dockerPull(t *testing.T, image string) {
	cmd := exec.Command("docker", "pull", image)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("docker pull failed: %v\n%s", err, string(output))
	}
}

func dockerRmi(t *testing.T, image string) {
	cmd := exec.Command("docker", "rmi", image)
	cmd.Run()
}

func registryManifestInspect(t *testing.T, registryURL, registryToken, image string) string {
	ref := strings.TrimPrefix(image, "http://")
	idx := strings.Index(ref, "/")
	if idx < 0 {
		t.Fatalf("Invalid image ref: %s", image)
	}
	repoTag := ref[idx+1:]
	repo, tag, _ := strings.Cut(repoTag, ":")
	req, _ := http.NewRequest("GET", registryURL+"/v2/"+repo+"/manifests/"+tag, nil)
	req.Header.Set("Authorization", "Bearer "+registryToken)
	req.Header.Set("Accept",
		"application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Registry manifest request failed: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("Expected manifest for %s to be accessible with registry token, got status %d: %s", repoTag, resp.StatusCode, string(body))
	}
	return string(body)
}

func getRegistryChallenge(t *testing.T, registryURL string) string {
	req, _ := http.NewRequest("GET", registryURL+"/v2/", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Challenge request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("Expected 401 challenge, got %d", resp.StatusCode)
	}
	return resp.Header.Get("WWW-Authenticate")
}

func TestE2EFullRegistryFlow(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	ctx := context.Background()

	// Create temp directory for test data (shared between registry and auth-api)
	tmpDir := filepath.Join("/tmp", "auth-api-test-e2e-"+fmt.Sprintf("%d", time.Now().UnixNano()))
	dataDir := filepath.Join(tmpDir, "data")
	if err := os.MkdirAll(dataDir, 0777); err != nil {
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
	defer authAPIContainer.Terminate(ctx)

	// Wait for auth-api to generate keys and cert
	time.Sleep(5 * time.Second)

	// Verify cert was generated
	certPath := filepath.Join(dataDir, "auth-cert.pem")
	if _, err := os.Stat(certPath); err != nil {
		t.Fatalf("Auth cert not generated at %s: %v", certPath, err)
	}

	// Use the auth-api's container IP:8443 as the token realm. Unlike the
	// random host port, the container IP is stable across container
	// Stop/Start, so the registry's baked-in realm stays valid after the
	// auth-api restart in TEST 10. The host can reach it on the bridge.
	authIP, err := authAPIContainer.ContainerIP(ctx)
	if err != nil {
		t.Fatalf("Failed to get auth-api container IP: %v", err)
	}
	authAPIURL := fmt.Sprintf("http://%s:8443", authIP)

	// Write a custom registry config that points the token realm at the local auth-api
	registryConfig := fmt.Sprintf(`version: 0.1
log:
  level: info
  formatter: json
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: false
auth:
  token:
    realm: %s/token
    service: registry.laymatched.io
    issuer: laymatched-auth
    rootcertbundle: /certs/auth-cert.pem
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
    X-Frame-Options: [DENY]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
compatibility:
  schema1:
    enabled: false
`, authAPIURL)
	registryConfigPath := filepath.Join(tmpDir, "registry-config.yml")
	if err := os.WriteFile(registryConfigPath, []byte(registryConfig), 0644); err != nil {
		t.Fatalf("Failed to write registry config: %v", err)
	}

	// Start Docker Distribution registry with testcontainers
	registryContainer, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "laymatched-registry:latest",
			ExposedPorts: []string{"5000/tcp"},
			Mounts: testcontainers.Mounts(
				testcontainers.BindMount(dataDir, "/certs"),
				testcontainers.BindMount(registryConfigPath, "/etc/docker/registry/config.yml"),
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
	registryHost := strings.TrimPrefix(registryURL, "http://")

	// Wait for registry to be ready
	time.Sleep(3 * time.Second)

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
	installerToken := "lm_inst_e2efulltest12345678901234"
	insertTestTokenForIntegration(t, db, "customer-e2e-full", installerToken)

	// Insert owner token (push and pull)
	ownerToken := "lm_owner_e2efulltest123456789012"
	insertOwnerTokenForIntegration(t, db, "ci-cd", ownerToken,
		"repository:laymatched-api:push,repository:laymatched-web:push,repository:laymatched-api:pull,repository:laymatched-web:pull")

	// Test tag unique per run
	testTag := fmt.Sprintf("e2e-%d", time.Now().UnixNano())
	apiImage := fmt.Sprintf("%s/laymatched-api:%s", registryHost, testTag)
	webImage := fmt.Sprintf("%s/laymatched-web:%s", registryHost, testTag)

	// =================================================================
	// TEST 1: Unauthenticated access denied (Bearer challenge)
	// =================================================================
	t.Log("TEST 1: Unauthenticated access denied")
	challenge := getRegistryChallenge(t, registryURL)
	if !strings.Contains(challenge, "Bearer") {
		t.Fatalf("Expected Bearer challenge, got: %s", challenge)
	}
	t.Log("  PASS: Registry returns Bearer challenge for unauthenticated access")

	// =================================================================
	// TEST 2: Get owner token and push images
	// =================================================================
	t.Log("TEST 2: Owner push - laymatched-api and laymatched-web")
	ownerRegistryToken := getOwnerRegistryToken(t, authAPIURL, registryURL, ownerToken)

	// Login as owner to registry
	dockerLogin(t, registryURL, "owner", ownerToken)

	// Create test images from busybox (tiny, deterministic)
	baseImage := "busybox:latest"
	cmd := exec.Command("docker", "pull", baseImage)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Failed to pull base image: %v\n%s", err, string(output))
	}

	// Tag and push laymatched-api
	dockerTag(t, baseImage, apiImage)
	dockerPush(t, apiImage)
	t.Logf("  PASS: Pushed %s", apiImage)

	// Tag and push laymatched-web
	dockerTag(t, baseImage, webImage)
	dockerPush(t, webImage)
	t.Logf("  PASS: Pushed %s", webImage)

	// Verify the owner's registry JWT has direct API access (proof of token exchange)
	ownerCheckReq, _ := http.NewRequest("GET", registryURL+"/v2/laymatched-api/tags/list", nil)
	ownerCheckReq.Header.Set("Authorization", "Bearer "+ownerRegistryToken)
	ownerCheckResp, err := http.DefaultClient.Do(ownerCheckReq)
	if err != nil {
		t.Fatalf("Owner registry token API check failed: %v", err)
	}
	ownerCheckResp.Body.Close()
	if ownerCheckResp.StatusCode != http.StatusOK {
		t.Fatalf("Expected owner registry token to access laymatched-api tags, got status %d", ownerCheckResp.StatusCode)
	}
	t.Logf("  PASS: Owner registry JWT grants API access to laymatched-api")

	// =================================================================
	// TEST 3: Verify images exist in registry (manifest inspect)
	// =================================================================
	t.Log("TEST 3: Verify images exist in registry")
	apiManifest := registryManifestInspect(t, registryURL, ownerRegistryToken, apiImage)
	if !strings.Contains(apiManifest, "schemaVersion") {
		t.Fatalf("API image manifest doesn't look like a valid manifest")
	}
	t.Logf("  PASS: API image manifest verified")

	webManifest := registryManifestInspect(t, registryURL, ownerRegistryToken, webImage)
	if !strings.Contains(webManifest, "schemaVersion") {
		t.Fatalf("Web image manifest doesn't look like a valid manifest")
	}
	t.Logf("  PASS: Web image manifest verified")

	// Logout
	dockerLogout(t, registryURL)

	// =================================================================
	// TEST 4: Get installer token and pull images
	// =================================================================
	t.Log("TEST 4: Installer pull - laymatched-api and laymatched-web")
	installerRegistryToken := getInstallerRegistryToken(t, authAPIURL, registryURL, installerToken)

	// Login as installer to registry
	dockerLogin(t, registryURL, "installer", installerToken)

	// Pull both images
	dockerPull(t, apiImage)
	t.Logf("  PASS: Pulled %s", apiImage)

	dockerPull(t, webImage)
	t.Logf("  PASS: Pulled %s", webImage)

	// Logout
	dockerLogout(t, registryURL)

	// =================================================================
	// TEST 5: Negative - Invalid installer credential denied
	// =================================================================
	t.Log("TEST 5: Invalid installer credential denied")
	invalidToken := "lm_inst_invalid12345678901234"

	// The auth-api token endpoint rejects the unknown credential, so docker login fails
	cmd = exec.Command("docker", "login", registryURL, "-u", "installer", "-p", invalidToken)
	output, err = cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("Expected docker login to fail with invalid installer credential, but it succeeded")
	}
	t.Logf("  PASS: Invalid installer credential rejected by auth-api token endpoint")

	// Confirm pull is still denied (no usable credential)
	cmd = exec.Command("docker", "pull", apiImage)
	output, err = cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("Expected pull to fail with invalid installer credential, but it succeeded")
	}
	t.Logf("  PASS: Pull denied with invalid installer credential")

	// =================================================================
	// TEST 6: Negative - Expired installer credential denied
	// =================================================================
	t.Log("TEST 6: Expired installer credential denied")
	expiredToken := "lm_inst_expired1234567890123456"
	insertTestTokenForIntegration(t, db, "customer-expired", expiredToken)
	_, err = db.Exec(`
		UPDATE installer_tokens SET expires_at = datetime('now', '-1 hour') WHERE token_sha256 = ?
	`, fmt.Sprintf("%x", sha256.Sum256([]byte(expiredToken))))
	if err != nil {
		t.Fatalf("Failed to update token expiry: %v", err)
	}

	// The auth-api token endpoint rejects the expired credential, so docker login fails
	cmd = exec.Command("docker", "login", registryURL, "-u", "installer", "-p", expiredToken)
	output, err = cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("Expected docker login to fail with expired installer credential, but it succeeded")
	}
	t.Logf("  PASS: Expired installer credential rejected by auth-api token endpoint")

	// =================================================================
	// TEST 7: Negative - Installer push denied by registry
	// =================================================================
	t.Log("TEST 7: Installer push denied by registry")
	dockerLogin(t, registryURL, "installer", installerToken)
	// Tag a real local image so the push attempt reaches the registry's auth check
	pushImage := fmt.Sprintf("%s/laymatched-api:push-test-%d", registryHost, time.Now().UnixNano())
	dockerTag(t, baseImage, pushImage)
	cmd = exec.Command("docker", "push", pushImage)
	output, err = cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("Expected push to fail with installer token, but it succeeded")
	}
	lower := strings.ToLower(string(output))
	if !strings.Contains(lower, "denied") && !strings.Contains(lower, "unauthorized") && !strings.Contains(lower, "forbidden") && !strings.Contains(lower, "scope not authorized") {
		t.Fatalf("Expected push denial, but error was unrelated: %s", string(output))
	}
	t.Logf("  PASS: Installer push denied by registry (token scope check)")
	dockerLogout(t, registryURL)

	// =================================================================
	// TEST 8: Negative - Installer delete denied by registry
	// =================================================================
	t.Log("TEST 8: Installer delete denied by registry")
	dockerLogin(t, registryURL, "installer", installerToken)
	// Manifest access must succeed first - this confirms the installer token is valid for pull
	registryManifestInspect(t, registryURL, installerRegistryToken, apiImage)
	t.Logf("  PASS: Installer registry token can read manifests (pull access)")
	// Delete requires delete scope - the registry access controller must reject the installer token
	req, _ := http.NewRequest("DELETE", registryURL+"/v2/laymatched-api/manifests/"+testTag, nil)
	req.Header.Set("Authorization", "Bearer "+installerRegistryToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Delete request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden {
		t.Fatalf("Expected delete to be denied with 401/403, got status %d", resp.StatusCode)
	}
	t.Logf("  PASS: Installer delete denied by registry (token scope check)")
	dockerLogout(t, registryURL)

	// =================================================================
	// TEST 9: Negative - Unrelated repository access denied
	// =================================================================
	t.Log("TEST 9: Unrelated repository access denied")
	// Installer CAN exchange for a valid JWT, but that JWT lacks unrelated-repo scope
	unrelatedToken := getInstallerRegistryToken(t, authAPIURL, registryURL, installerToken)

	// Direct API check: the installer JWT must be rejected for an unrelated repository
	unrelatedReq, _ := http.NewRequest("GET", registryURL+"/v2/unrelated-repo/tags/list", nil)
	unrelatedReq.Header.Set("Authorization", "Bearer "+unrelatedToken)
	unrelatedResp, err := http.DefaultClient.Do(unrelatedReq)
	if err != nil {
		t.Fatalf("Unrelated repo API check failed: %v", err)
	}
	unrelatedResp.Body.Close()
	if unrelatedResp.StatusCode != http.StatusUnauthorized && unrelatedResp.StatusCode != http.StatusForbidden {
		t.Fatalf("Expected unrelated repo access to be denied with 401/403, got status %d", unrelatedResp.StatusCode)
	}
	t.Logf("  PASS: Installer registry JWT denied for unrelated repository (API check)")

	// Docker CLI check: pull from unrelated repo must fail
	dockerLogin(t, registryURL, "installer", installerToken)
	cmd = exec.Command("docker", "pull", fmt.Sprintf("%s/unrelated-repo:latest", registryHost))
	output, err = cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("Expected pull from unrelated repo to fail, but it succeeded")
	}
	t.Logf("  PASS: Unrelated repository access denied by registry (docker pull)")
	dockerLogout(t, registryURL)

	// =================================================================
	// TEST 10: Restart auth-api and verify signing trust persists
	// =================================================================
	t.Log("TEST 10: Signing trust persists after Auth API restart")

	// First, get a working token and verify pull works
	installerRegistryTokenBefore := getInstallerRegistryToken(t, authAPIURL, registryURL, installerToken)
	dockerLogin(t, registryURL, "installer", installerToken)
	dockerPull(t, apiImage)
	t.Logf("  PASS: Pull works before restart")
	dockerLogout(t, registryURL)

	// Restart auth-api
	timeout := 10 * time.Second
	authAPIContainer.Stop(ctx, &timeout)
	time.Sleep(2 * time.Second)
	authAPIContainer.Start(ctx)
	time.Sleep(5 * time.Second)

	// authAPIURL (container IP:8443) is unchanged after restart; the registry's
	// token realm still points at it and the host can still reach it.

	// Get NEW token after restart
	installerRegistryTokenAfter := getInstallerRegistryToken(t, authAPIURL, registryURL, installerToken)

	// Verify the new token is different (newly issued)
	if installerRegistryTokenAfter == installerRegistryTokenBefore {
		t.Fatal("Expected new token after restart, got same token")
	}

	// Use the NEW token against the SAME running registry
	dockerLogin(t, registryURL, "installer", installerToken)
	dockerPull(t, apiImage)
	t.Logf("  PASS: Pull works with new token after Auth API restart")
	dockerLogout(t, registryURL)

	// Clean up test images
	dockerRmi(t, apiImage)
	dockerRmi(t, webImage)

	t.Log("Full registry E2E flow completed successfully")
}

func TestE2EUnauthenticatedPullDenied(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, _, cleanup, _ := setupAuthAPITest(t)
	defer cleanup()

	resp, err := http.Get(authAPIURL + "/token?service=registry.laymatched.io&scope=repository:laymatched-api:pull")
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("Expected 401 for missing auth, got %d", resp.StatusCode)
	}

	wwwAuth := resp.Header.Get("WWW-Authenticate")
	if !strings.Contains(wwwAuth, "Bearer") {
		t.Errorf("Expected WWW-Authenticate Bearer header, got: %s", wwwAuth)
	}
}

func TestE2EInvalidCredentialDenied(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, _, cleanup, _ := setupAuthAPITest(t)
	defer cleanup()

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

	authAPIURL, _, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	expiredToken := "lm_inst_expired1234567890123456"
	insertTestTokenForIntegration(t, db, "customer-expired", expiredToken)

	_, err := db.Exec(`
		UPDATE installer_tokens SET expires_at = datetime('now', '-1 hour') WHERE token_sha256 = ?
	`, fmt.Sprintf("%x", sha256.Sum256([]byte(expiredToken))))
	if err != nil {
		t.Fatalf("Failed to update token expiry: %v", err)
	}

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

	authAPIURL, _, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_pushdenied123456789012"
	insertTestTokenForIntegration(t, db, "customer-push", token)

	req, _ := http.NewRequest("GET", authAPIURL+"/token?service=registry.laymatched.io&scope=repository:laymatched-api:push", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(resp.Body)
		t.Errorf("Expected 403 for push scope with installer token, got %d: %s", resp.StatusCode, string(body))
	}
}

func TestE2ETokenCannotDelete(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	authAPIURL, _, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_deletedened12345678901"
	insertTestTokenForIntegration(t, db, "customer-delete", token)

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

	authAPIURL, _, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_unrelated12345678901234"
	insertTestTokenForIntegration(t, db, "customer-unrelated", token)

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

	authAPIURL, _, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_bothimages12345678901"
	insertTestTokenForIntegration(t, db, "customer-both", token)

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

	parser := jwt.NewParser(jwt.WithoutClaimsValidation())
	parsed, _, err := parser.ParseUnverified(tokenRespBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("JWT parse failed: %v", err)
	}
	claims := parsed.Claims.(jwt.MapClaims)
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

	authAPIURL, _, cleanup, db := setupAuthAPITest(t)
	defer cleanup()

	token := "lm_inst_expiretest1234567890123"
	insertTestTokenForIntegration(t, db, "customer-expire", token)

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

	if tokenRespBody.ExpiresIn != 3600 {
		t.Errorf("Expected expires_in 3600, got %d", tokenRespBody.ExpiresIn)
	}

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

func TestE2EDockerLoginWithOriginalCredentials(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	// This test verifies the Docker login pattern used in the release workflow:
	// - Owner original credential → docker login → push succeeds
	// - Installer original credential → docker login → pull succeeds
	// - Installer push remains denied
	// - Anonymous pull remains denied

	// Replicate the setup pattern from TestE2EFullRegistryFlow to use container IPs
	ctx := context.Background()

	// Create temp directory for test data (shared between registry and auth-api)
	tmpDir := filepath.Join("/tmp", "docker-login-test-"+fmt.Sprintf("%d", time.Now().UnixNano()))
	dataDir := filepath.Join(tmpDir, "data")
	if err := os.MkdirAll(dataDir, 0777); err != nil {
		t.Fatalf("Failed to create data dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Write approved_version.txt
	if err := os.WriteFile(filepath.Join(dataDir, "approved_version.txt"), []byte("v0.1.0"), 0644); err != nil {
		t.Fatalf("Failed to create approved_version.txt: %v", err)
	}

	// Start auth-api FIRST so it generates the cert/keys
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
	defer authAPIContainer.Terminate(ctx)

	// Wait for auth-api to generate keys and cert
	time.Sleep(5 * time.Second)

	// Verify cert was generated
	certPath := filepath.Join(dataDir, "auth-cert.pem")
	if _, err := os.Stat(certPath); err != nil {
		t.Fatalf("Auth cert not generated at %s: %v", certPath, err)
	}

	// Use the auth-api's container IP:8443 as the token realm
	authIP, err := authAPIContainer.ContainerIP(ctx)
	if err != nil {
		t.Fatalf("Failed to get auth-api container IP: %v", err)
	}
	authAPIURL := fmt.Sprintf("http://%s:8443", authIP)

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
	installerToken := "lm_inst_dockerlogintest12345678"
	insertTestTokenForIntegration(t, db, "customer-docker-login", installerToken)

	// Insert owner token (push and pull)
	ownerToken := "lm_owner_dockerlogintest12345678"
	insertOwnerTokenForIntegration(t, db, "ci-cd", ownerToken,
		"repository:laymatched-api:push,repository:laymatched-web:push,repository:laymatched-api:pull,repository:laymatched-web:pull")

	// Write a custom registry config that points the token realm at the local auth-api
	registryConfig := fmt.Sprintf(`version: 0.1
log:
  level: info
  formatter: json
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: false
auth:
  token:
    realm: %s/token
    service: registry.laymatched.io
    issuer: laymatched-auth
    rootcertbundle: /certs/auth-cert.pem
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
    X-Frame-Options: [DENY]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
compatibility:
  schema1:
    enabled: false
`, authAPIURL)
	registryConfigPath := filepath.Join(tmpDir, "registry-config.yml")
	if err := os.WriteFile(registryConfigPath, []byte(registryConfig), 0644); err != nil {
		t.Fatalf("Failed to write registry config: %v", err)
	}

	// Start Docker Distribution registry with testcontainers
	registryContainer, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "laymatched-registry:latest",
			ExposedPorts: []string{"5000/tcp"},
			Mounts: testcontainers.Mounts(
				testcontainers.BindMount(dataDir, "/certs"),
				testcontainers.BindMount(registryConfigPath, "/etc/docker/registry/config.yml"),
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
	registryHost := strings.TrimPrefix(registryURL, "http://")

	// Wait for registry to be ready
	time.Sleep(3 * time.Second)

	// Test tag unique per run
	testTag := fmt.Sprintf("docker-login-test-%d", time.Now().UnixNano())
	apiImage := fmt.Sprintf("%s/laymatched-api:%s", registryHost, testTag)
	webImage := fmt.Sprintf("%s/laymatched-web:%s", registryHost, testTag)

	baseImage := "busybox:latest"
	cmd := exec.Command("docker", "pull", baseImage)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Failed to pull base image: %v\n%s", err, string(output))
	}

	// =================================================================
	// TEST: Owner original credential → docker login → push succeeds
	// =================================================================
	t.Log("TEST: Owner original credential → docker login → push")
	cmd = exec.Command("docker", "login", registryURL, "-u", "owner", "-p", ownerToken)
	output, err = cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Owner docker login failed: %v\n%s", err, string(output))
	}
	t.Log("  PASS: Owner docker login succeeded with original credential")

	dockerTag(t, baseImage, apiImage)
	dockerPush(t, apiImage)
	t.Logf("  PASS: Owner push succeeded for %s", apiImage)

	dockerTag(t, baseImage, webImage)
	dockerPush(t, webImage)
	t.Logf("  PASS: Owner push succeeded for %s", webImage)

	dockerLogout(t, registryURL)

	// =================================================================
	// TEST: Installer original credential → docker login → pull succeeds
	// =================================================================
	t.Log("TEST: Installer original credential → docker login → pull")
	cmd = exec.Command("docker", "login", registryURL, "-u", "installer", "-p", installerToken)
	output, err = cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Installer docker login failed: %v\n%s", err, string(output))
	}
	t.Log("  PASS: Installer docker login succeeded with original credential")

	dockerPull(t, apiImage)
	t.Logf("  PASS: Installer pull succeeded for %s", apiImage)

	dockerPull(t, webImage)
	t.Logf("  PASS: Installer pull succeeded for %s", webImage)

	dockerLogout(t, registryURL)

	// =================================================================
	// TEST: Installer push remains denied
	// =================================================================
	t.Log("TEST: Installer push denied")
	cmd = exec.Command("docker", "login", registryURL, "-u", "installer", "-p", installerToken)
	output, err = cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Installer docker login failed: %v\n%s", err, string(output))
	}

	pushImage := fmt.Sprintf("%s/laymatched-api:push-denied-%d", registryHost, time.Now().UnixNano())
	dockerTag(t, baseImage, pushImage)
	cmd = exec.Command("docker", "push", pushImage)
	output, err = cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("Expected push to fail with installer token, but it succeeded")
	}
	lower := strings.ToLower(string(output))
	if !strings.Contains(lower, "denied") && !strings.Contains(lower, "unauthorized") && !strings.Contains(lower, "forbidden") && !strings.Contains(lower, "scope not authorized") {
		t.Fatalf("Expected push denial, but error was unrelated: %s", string(output))
	}
	t.Logf("  PASS: Installer push denied by registry (token scope check)")
	dockerLogout(t, registryURL)

	// =================================================================
	// TEST: Anonymous pull remains denied
	// =================================================================
	t.Log("TEST: Anonymous pull denied")
	cmd = exec.Command("docker", "pull", apiImage)
	output, err = cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("Expected anonymous pull to fail, but it succeeded")
	}
	t.Logf("  PASS: Anonymous pull denied")

	// =================================================================
	// TEST: Protected registry healthcheck - expects 401 Bearer challenge
	// =================================================================
	t.Log("TEST: Protected registry healthcheck returns 401 Bearer challenge")
	challenge := getRegistryChallenge(t, registryURL)
	if !strings.Contains(challenge, "Bearer") {
		t.Fatalf("Expected Bearer challenge, got: %s", challenge)
	}
	t.Log("  PASS: Registry returns Bearer challenge for unauthenticated access (healthy)")

	// Clean up
	dockerRmi(t, apiImage)
	dockerRmi(t, webImage)
	dockerRmi(t, pushImage)
	dockerRmi(t, baseImage)

	t.Log("Docker login with original credentials test completed successfully")
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
}