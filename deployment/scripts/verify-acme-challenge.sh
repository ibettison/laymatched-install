#!/bin/bash
# Valid ACME challenge verification
# Creates temporary challenge file, verifies through public hostname, cleans up

set -euo pipefail

TEST_TOKEN="laymatched-acme-test-$(date +%s)"
TEST_CONTENT="acme-validation-$TEST_TOKEN"
TEST_PATH="/var/www/letsencrypt/.well-known/acme-challenge/$TEST_TOKEN"

mkdir -p "$(dirname "$TEST_PATH")"
echo "$TEST_CONTENT" > "$TEST_PATH"
chown root:root "$TEST_PATH"
chmod 644 "$TEST_PATH"

echo "Testing ACME challenge for both domains..."

for domain in auth.matched.laysports.co.uk registry.matched.laysports.co.uk; do
    RESPONSE=$(curl -fsS "http://$domain/.well-known/acme-challenge/$TEST_TOKEN" 2>/dev/null || echo "FAIL")
    if [[ "$RESPONSE" != "$TEST_CONTENT" ]]; then
        echo "FAIL: ACME challenge failed for $domain"
        rm -f "$TEST_PATH"
        exit 1
    fi
    echo "PASS: ACME challenge works for $domain"
done

rm -f "$TEST_PATH"
echo "ACME challenge verification complete - test file removed"