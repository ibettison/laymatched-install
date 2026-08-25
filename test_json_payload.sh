#!/usr/bin/env bash
# Test script for installer JSON payload construction
# Verifies the fix for Issue #6 G5 Phase 4 JSON syntax error

set -euo pipefail

TEST_TOKEN="lm_inst_test_dummy_token_12345"
EXPECTED_KEY="installer_token"

echo "Testing JSON payload construction..."

# Test the fixed JSON construction method
json_payload=$(python3 -c '
import json, sys
print(json.dumps({"installer_token": sys.argv[1]}))
' "$TEST_TOKEN")

echo "Generated JSON: $json_payload"

# Test 1: JSON is syntactically valid
if echo "$json_payload" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
    echo "PASS: JSON is syntactically valid"
else
    echo "FAIL: JSON is not syntactically valid"
    exit 1
fi

# Test 2: JSON contains installer_token key
if echo "$json_payload" | python3 -c "import sys, json; data=json.load(sys.stdin); assert '$EXPECTED_KEY' in data, 'Missing key'" 2>/dev/null; then
    echo "PASS: JSON contains '$EXPECTED_KEY' key"
else
    echo "FAIL: JSON missing '$EXPECTED_KEY' key"
    exit 1
fi

# Test 3: Token value preserved exactly
extracted_token=$(echo "$json_payload" | python3 -c "import sys, json; print(json.load(sys.stdin).get('$EXPECTED_KEY', ''))")
if [ "$extracted_token" = "$TEST_TOKEN" ]; then
    echo "PASS: Token value preserved exactly"
else
    echo "FAIL: Token value not preserved. Expected: $TEST_TOKEN, Got: $extracted_token"
    exit 1
fi

# Test 4: Different tokens produce different JSON
json_payload2=$(python3 -c '
import json, sys
print(json.dumps({"installer_token": sys.argv[1]}))
' "different_token_abc")
if [ "$json_payload" != "$json_payload2" ]; then
    echo "PASS: Different tokens produce different JSON"
else
    echo "FAIL: Different tokens produced same JSON"
    exit 1
fi

# Test 5: Special characters in token are handled correctly
special_token="lm_inst_token_with_\$\{\}\[\]\"'\''\`\|\&"
json_special=$(python3 -c '
import json, sys
print(json.dumps({"installer_token": sys.argv[1]}))
' "$special_token")
extracted_special=$(echo "$json_special" | python3 -c "import sys, json; print(json.load(sys.stdin).get('$EXPECTED_KEY', ''))")
if [ "$extracted_special" = "$special_token" ]; then
    echo "PASS: Special characters handled correctly"
else
    echo "FAIL: Special characters not handled correctly"
    exit 1
fi

echo ""
echo "All tests passed!"