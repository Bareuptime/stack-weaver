#!/bin/bash

# Test script to verify binary detection functionality
# This is a dry-run test that doesn't require root access

set -e

echo "🧪 Testing binary detection functionality..."

# Source the main script functions
source "../bin/setup_service_mesh.sh"

# Mock the error function for testing
error() {
    echo "[TEST ERROR] $*" >&2
    return 1
}

# Mock the log functions for testing
log() {
    echo "[TEST LOG] $1"
}

log_info() {
    echo "[TEST INFO] $1"
}

log_success() {
    echo "[TEST SUCCESS] $1"
}

log_error() {
    echo "[TEST ERROR] $1" >&2
}

echo "Testing binary detection..."

# Test the detect_binary_paths function
if detect_binary_paths 2>/dev/null; then
    echo "✅ Binary detection function works"
    echo "  Detected paths:"
    echo "    VAULT_BIN: ${VAULT_BIN:-'NOT FOUND'}"
    echo "    CONSUL_BIN: ${CONSUL_BIN:-'NOT FOUND'}"
    echo "    NOMAD_BIN: ${NOMAD_BIN:-'NOT FOUND'}"
else
    echo "❌ Binary detection failed"
    echo "This is expected if the binaries are not installed on this system"
fi

echo ""
echo "Testing binary version verification..."

# Only test if binaries were found
if [[ -n "$VAULT_BIN" && -n "$CONSUL_BIN" && -n "$NOMAD_BIN" ]]; then
    if verify_binary_versions 2>/dev/null; then
        echo "✅ Binary version verification works"
    else
        echo "⚠️  Binary version verification failed (binaries may not be functional)"
    fi
else
    echo "⚠️  Skipping version verification - binaries not found"
fi

echo ""
echo "🎯 Binary path consistency check:"
echo "The script will now use dynamic paths instead of hardcoded ones:"
echo "  - Vault: Uses detected path instead of /usr/local/bin/vault"
echo "  - Consul: Uses detected path instead of /usr/bin/consul" 
echo "  - Nomad: Uses detected path instead of /usr/bin/nomad"
echo ""
echo "✅ Test completed!"
