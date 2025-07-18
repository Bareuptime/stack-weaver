#!/bin/bash
# =============================================================================
# CLUSTER FORGE - EXAMPLE ENVIRONMENT CONFIGURATION
# Copy this file to .env and customize the values for your environment
# =============================================================================

# REQUIRED ENVIRONMENT VARIABLES
# ===============================

# Netmaker enrollment token (obtain from your Netmaker dashboard)
export NETMAKER_TOKEN="your-netmaker-enrollment-token-here"

# IP addresses of your cluster nodes
export NOMAD_SERVER_IP="10.0.1.10"     # IP of the Nomad server node
export CONSUL_SERVER_IP="10.0.1.10"    # IP of the Consul server node (usually same as Nomad)


# Vault configuration
export VAULT_ADDR="https://vault.example.com:8200"       # Vault server address
export VAULT_TOKEN="your-vault-token-here"               # Vault authentication token

# OPTIONAL ENVIRONMENT VARIABLES
# ===============================

# Node configuration
export ROLE="client"                    # 'server' or 'client' (default: client)
export NODE_NAME="$(hostname)"          # Node name (default: hostname)
export DATACENTER="dc1"                 # Datacenter name (default: dc1)

# Networking
export STATIC_PORT="51821"              # Netmaker static port (default: 51821)

# Security
export ENCRYPT_KEY=""                   # Consul encryption key (auto-generated if empty)

# =============================================================================
# USAGE EXAMPLES
# =============================================================================

# After customizing this file, you can use it like this:

# 1. Source the environment file:
#    source env.example.sh

# 2. Run validation only:
#    ./cluster-forge-bundled.sh --validate-only

# 3. Run dry-run to see what would be done:
#    ./cluster-forge-bundled.sh --dry-run

# 4. Run the actual deployment (requires root):
#    sudo -E ./cluster-forge-bundled.sh

# 5. Or use the modular version:
#    sudo -E ./bin/cluster-forge.sh

# 6. Or use the legacy interface:
#    sudo -E ./bin/main.sh

# =============================================================================
# SECURITY NOTES
# =============================================================================

# - Never commit actual tokens/secrets to version control
# - Use a proper secrets management system in production
# - Ensure proper file permissions (600) for files containing secrets
# - Consider using Vault or other secure secret stores
