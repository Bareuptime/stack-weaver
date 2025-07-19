#!/bin/bash

# The rest of the existing content from setup_service_mesh.sh follows below...
# This allows the existing functions to still work while providing the main entry point

# Complete Vault-Based Node Bootstrap Script
# This script sets up a new node with automatic certificate management using Vault PKI

set -e

# Source logging functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"


ROLE="${ROLE:-client}"                    # server or client
NOMAD_SERVER_IP="${NOMAD_SERVER_IP:-}"    # IP of the server node
CONSUL_SERVER_IP="${CONSUL_SERVER_IP:-}"    # IP of the server node
NODE_NAME="${NODE_NAME:-$(hostname)}"     # Node name
DATACENTER="${DATACENTER:-dc1}"           # Datacenter name
ENCRYPT_KEY="${ENCRYPT_KEY:-}"            # Consul encryption key (auto-generated if empty)
NETMAKER_TOKEN="${NETMAKER_TOKEN:-}"      # Netmaker enrollment token (mandatory)
STATIC_PORT="${STATIC_PORT:-51821}"       # Netmaker static port
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"


error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# =============================================================================
# BINARY PATH DETECTION
# =============================================================================

detect_binary_paths() {
    log_info "Detecting binary paths..."
    
    # Detect Vault binary
    VAULT_BIN=""
    for path in "/usr/bin/vault" "/usr/local/bin/vault" "/opt/vault/bin/vault"; do
        if [ -x "$path" ]; then
            VAULT_BIN="$path"
            break
        fi
    done
    
    if [ -z "$VAULT_BIN" ]; then
        VAULT_BIN=$(which vault 2>/dev/null || echo "")
    fi
    
    if [ -z "$VAULT_BIN" ]; then
        error "Vault binary not found. Please install Vault first."
    fi
    
    # Detect Consul binary
    CONSUL_BIN=""
    for path in "/usr/bin/consul" "/usr/local/bin/consul" "/opt/consul/bin/consul"; do
        if [ -x "$path" ]; then
            CONSUL_BIN="$path"
            break
        fi
    done
    
    if [ -z "$CONSUL_BIN" ]; then
        CONSUL_BIN=$(which consul 2>/dev/null || echo "")
    fi
    
    if [ -z "$CONSUL_BIN" ]; then
        error "Consul binary not found. Please install Consul first."
    fi
    
    # Detect Nomad binary
    NOMAD_BIN=""
    for path in "/usr/bin/nomad" "/usr/local/bin/nomad" "/opt/nomad/bin/nomad"; do
        if [ -x "$path" ]; then
            NOMAD_BIN="$path"
            break
        fi
    done
    
    if [ -z "$NOMAD_BIN" ]; then
        NOMAD_BIN=$(which nomad 2>/dev/null || echo "")
    fi
    
    if [ -z "$NOMAD_BIN" ]; then
        error "Nomad binary not found. Please install Nomad first."
    fi
    
    log_info "✅ Binary paths detected:"
    log_info "  Vault: $VAULT_BIN"
    log_info "  Consul: $CONSUL_BIN"
    log_info "  Nomad: $NOMAD_BIN"
}

verify_binary_versions() {
    log_info "Verifying binary versions..."
    
    # Check Vault version
    if ! VAULT_VERSION=$("$VAULT_BIN" version 2>/dev/null | head -n1); then
        error "Failed to get Vault version from $VAULT_BIN"
    fi
    log_info "  Vault: $VAULT_VERSION"
    
    # Check Consul version
    if ! CONSUL_VERSION=$("$CONSUL_BIN" version 2>/dev/null | head -n1); then
        error "Failed to get Consul version from $CONSUL_BIN"
    fi
    log_info "  Consul: $CONSUL_VERSION"
    
    # Check Nomad version
    if ! NOMAD_VERSION=$("$NOMAD_BIN" version 2>/dev/null | head -n1); then
        error "Failed to get Nomad version from $NOMAD_BIN"
    fi
    log_info "  Nomad: $NOMAD_VERSION"
    
    log_info "✅ All binaries are functional"
}

create_service_users() {
    log_info "Creating service users..."
    
    # Create vault user if it doesn't exist
    if ! id -u vault >/dev/null 2>&1; then
        useradd --system --home /var/lib/vault --shell /bin/false vault
        log_info "✅ Created vault user"
    else
        log_info "  Vault user already exists"
    fi
    
    # Create consul user if it doesn't exist
    if ! id -u consul >/dev/null 2>&1; then
        useradd --system --home /opt/consul --shell /bin/false consul
        log_info "✅ Created consul user"
    else
        log_info "  Consul user already exists"
    fi
    
    # Create nomad user if it doesn't exist
    if ! id -u nomad >/dev/null 2>&1; then
        useradd --system --home /opt/nomad --shell /bin/false nomad
        log_info "✅ Created nomad user"
    else
        log_info "  Nomad user already exists"
    fi
    
    log_info "✅ Service users verified"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_input() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
    
    if [[ "$ROLE" != "server" && "$ROLE" != "client" ]]; then
        error "ROLE must be 'server' or 'client'"
    fi
    
    if [[ -z "$NOMAD_SERVER_IP" ]]; then
        error "NOMAD_SERVER_IP must be provided (use the server node's IP address)"
    fi
    
    if ! [[ "$NOMAD_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "NOMAD_SERVER_IP must be a valid IP address"
    fi

    if [[ -z "$CONSUL_SERVER_IP" ]]; then
        error "CONSUL_SERVER_IP must be provided (use the server node's IP address)"
    fi

    if ! [[ "$CONSUL_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "CONSUL_SERVER_IP must be a valid IP address"
    fi

    if [[ -z "$NETMAKER_TOKEN" ]]; then
        error "NETMAKER_TOKEN is mandatory. Please provide the Netmaker enrollment token."
    fi

    if [[ -z "$VAULT_ADDR" ]]; then
        error "VAULT_ADDR must be set to the Vault server address"
    fi
    if [[ -z "$VAULT_TOKEN" ]]; then
        error "VAULT_TOKEN must be set to the Vault authentication token"
    fi
}

create_service_directories() {
    log_info "Creating service directories..."
    
    # Vault Agent directories
    mkdir -p /etc/vault-agent/templates
    mkdir -p /var/lib/vault-agent
    mkdir -p /var/log/vault-agent
    
    # Service directories
    mkdir -p /etc/consul.d/tls
    mkdir -p /etc/nomad.d/tls
    mkdir -p /opt/consul/data
    mkdir -p /opt/consul/logs
    mkdir -p /opt/nomad/data
    mkdir -p /opt/nomad/logs
    
    # Set ownership
    chown -R root:root /var/lib/vault-agent /var/log/vault-agent
    chown -R consul:consul /etc/consul.d /opt/consul
    chown -R nomad:nomad /etc/nomad.d /opt/nomad
    # TLS directory needs to be owned by consul so consul service can read the certificates
    chown -R consul:consul /etc/consul.d/tls
    # TLS directory needs to be owned by nomad so nomad service can read the certificates
    chown -R nomad:nomad /etc/nomad.d/tls
    
    log_success "✅ Directories created"
}

# =============================================================================
# CREATE HOST VOLUMES
# =============================================================================

create_host_volumes() {
    log_info "Creating Nomad host volume directories..."
    
    # Create host volumes directory
    mkdir -p /opt/nomad/host_volumes
    
    # Create some common host volumes
    local volumes=(
        "/opt/nomad/host_volumes/data"
        "/opt/nomad/host_volumes/logs"
        "/opt/nomad/host_volumes/config"
        "/opt/nomad/host_volumes/netmaker-data"
    )
    
    for volume in "${volumes[@]}"; do
        mkdir -p "$volume"
        chown nomad:nomad "$volume"
        chmod 755 "$volume"
    done
    
    chown -R nomad:nomad /opt/nomad
    
    log_success "Host volumes created"
}

create_vault_agent_config() {
    log_info "Creating Vault Agent configuration..."
    
    # Create backup of existing config if it exists
    if [ -f "/etc/vault-agent/vault-agent.hcl" ]; then
        local backup_file="/etc/vault-agent/vault-agent.hcl.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up existing Vault Agent config to: $backup_file"
        cp "/etc/vault-agent/vault-agent.hcl" "$backup_file"
        log_info "✅ Backup created: $backup_file"
    fi
    
    cat > /etc/vault-agent/vault-agent.hcl << EOF
pid_file = "/var/lib/vault-agent/vault-agent.pid"

vault {
  address = "$VAULT_ADDR"
  tls_skip_verify = true
}

auto_auth {
  method "token_file" {
    config = {
      token_file_path = "/etc/vault-agent/token"
    }
  }
  
  sink "file" {
    config = {
      path = "/var/lib/vault-agent/token"
    }
  }
}

template {
  source      = "/etc/vault-agent/templates/consul-cert.tpl"
  destination = "/etc/consul.d/tls/consul.pem"
  perms       = 0644
  command     = "/etc/vault-agent/fix-consul-cert-ownership.sh"
}

template {
  source      = "/etc/vault-agent/templates/consul-key.tpl"
  destination = "/etc/consul.d/tls/consul-key.pem"
  perms       = 0600
  command     = "/etc/vault-agent/fix-consul-key-ownership.sh"
}

template {
  source      = "/etc/vault-agent/templates/ca-cert.tpl"
  destination = "/etc/consul.d/tls/ca.pem"
  perms       = 0644
  command     = "/etc/vault-agent/fix-ca-cert-ownership.sh"
}

template {
  source      = "/etc/vault-agent/templates/nomad-cert.tpl"
  destination = "/etc/nomad.d/tls/nomad.pem"
  perms       = 0644
  command     = "/etc/vault-agent/fix-nomad-cert-ownership.sh"
}

template {
  source      = "/etc/vault-agent/templates/nomad-key.tpl"
  destination = "/etc/nomad.d/tls/nomad-key.pem"
  perms       = 0600
  command     = "/etc/vault-agent/fix-nomad-key-ownership.sh"
}

template {
  source      = "/etc/vault-agent/templates/ca-cert.tpl"
  destination = "/etc/nomad.d/tls/ca.pem"
  perms       = 0644
  command     = "/etc/vault-agent/fix-nomad-ca-ownership.sh"
}
EOF
    
    log_success "✅ Vault Agent config created"
}

create_certificate_templates() {
    log_info "Creating certificate templates..."

    log_info "Restarting Vault Agent to apply changes..."
    systemctl restart vault-agent
    log_info "✅ Vault Agent restarted"
    
    # CA certificate template
    cat > /etc/vault-agent/templates/ca-cert.tpl << 'EOF'
{{- with secret "pki-nodes/cert/ca" -}}
{{ .Data.certificate }}
{{- end -}}
EOF

    # Consul certificate template  
    cat > /etc/vault-agent/templates/consul-cert.tpl << EOF
{{- with secret "pki-nodes/issue/node-cert" 
    "common_name=nomad-consul-vault-cluster"
    "ip_sans=$NODE_IP,127.0.0.1"
    "alt_names=localhost,consul,nomad,vault,nomad.service.consul,consul.service.consul,vault.service.consul,*.nomad.service.consul,*.consul.service.consul,*.vault.service.consul,*.client.dc1.consul"
    "ttl=12h" -}}
{{ .Data.certificate }}
{{- end -}}
EOF

    # Private key template
    cat > /etc/vault-agent/templates/consul-key.tpl << EOF
{{- with secret "pki-nodes/issue/node-cert" 
    "common_name=nomad-consul-vault-cluster"
    "ip_sans=$NODE_IP,127.0.0.1"
    "alt_names=localhost,consul,nomad,vault,nomad.service.consul,consul.service.consul,vault.service.consul,*.nomad.service.consul,*.consul.service.consul,*.vault.service.consul,*.client.dc1.consul"
    "ttl=12h" -}}
{{ .Data.private_key }}
{{- end -}}
EOF

    # FIXED: Nomad certificate template - Added server.global.nomad and client.global.nomad
    cat > /etc/vault-agent/templates/nomad-cert.tpl << EOF
{{- with secret "pki-nodes/issue/node-cert" 
    "common_name=nomad-consul-vault-cluster"
    "ip_sans=$NODE_IP,127.0.0.1"
    "alt_names=localhost,nomad,consul,vault,server.global.nomad,client.global.nomad,nomad.service.consul,consul.service.consul,vault.service.consul,*.nomad.service.consul,*.consul.service.consul,*.vault.service.consul"
    "ttl=12h" -}}
{{ .Data.certificate }}
{{- end -}}
EOF

    # FIXED: Nomad private key template - Added server.global.nomad and client.global.nomad
    cat > /etc/vault-agent/templates/nomad-key.tpl << EOF
{{- with secret "pki-nodes/issue/node-cert" 
    "common_name=nomad-consul-vault-cluster"
    "ip_sans=$NODE_IP,127.0.0.1"
    "alt_names=localhost,nomad,consul,vault,server.global.nomad,client.global.nomad,nomad.service.consul,consul.service.consul,vault.service.consul,*.nomad.service.consul,*.consul.service.consul,*.vault.service.consul"
    "ttl=12h" -}}
{{ .Data.private_key }}
{{- end -}}
EOF
    
    log_success "✅ Certificate templates created"
}

create_ownership_scripts() {
    log_info "Creating certificate ownership scripts..."
    
    # Script for consul certificate
    cat > /etc/vault-agent/fix-consul-cert-ownership.sh << 'EOF'
#!/bin/bash
chown consul:consul /etc/consul.d/tls/consul.pem
chmod 644 /etc/consul.d/tls/consul.pem
# Only reload if consul is already running
if systemctl is-active --quiet consul; then
    systemctl reload consul || true
fi
EOF
    chmod +x /etc/vault-agent/fix-consul-cert-ownership.sh
    
    # Script for consul private key
    cat > /etc/vault-agent/fix-consul-key-ownership.sh << 'EOF'
#!/bin/bash
chown consul:consul /etc/consul.d/tls/consul-key.pem
chmod 600 /etc/consul.d/tls/consul-key.pem
EOF
    chmod +x /etc/vault-agent/fix-consul-key-ownership.sh
    
    # Script for CA certificate
    cat > /etc/vault-agent/fix-ca-cert-ownership.sh << 'EOF'
#!/bin/bash
chown consul:consul /etc/consul.d/tls/ca.pem
chmod 644 /etc/consul.d/tls/ca.pem
EOF
    chmod +x /etc/vault-agent/fix-ca-cert-ownership.sh
    
    # Script for nomad certificate
    cat > /etc/vault-agent/fix-nomad-cert-ownership.sh << 'EOF'
#!/bin/bash
chown nomad:nomad /etc/nomad.d/tls/nomad.pem
chmod 644 /etc/nomad.d/tls/nomad.pem
# Only reload if nomad is already running
if systemctl is-active --quiet nomad; then
    systemctl reload nomad || true
fi
EOF
    chmod +x /etc/vault-agent/fix-nomad-cert-ownership.sh
    
    # Script for nomad private key
    cat > /etc/vault-agent/fix-nomad-key-ownership.sh << 'EOF'
#!/bin/bash
chown nomad:nomad /etc/nomad.d/tls/nomad-key.pem
chmod 600 /etc/nomad.d/tls/nomad-key.pem
EOF
    chmod +x /etc/vault-agent/fix-nomad-key-ownership.sh
    
    # Script for nomad CA certificate
    cat > /etc/vault-agent/fix-nomad-ca-ownership.sh << 'EOF'
#!/bin/bash
chown nomad:nomad /etc/nomad.d/tls/ca.pem
chmod 644 /etc/nomad.d/tls/ca.pem
EOF
    chmod +x /etc/vault-agent/fix-nomad-ca-ownership.sh
    
    log_success "✅ Certificate ownership scripts created"
}

create_vault_token_file() {
    log_info "Creating Vault token file..."
    
    echo "$VAULT_TOKEN" > /etc/vault-agent/token
    chown root:root /etc/vault-agent/token
    chmod 600 /etc/vault-agent/token

    log_success "✅ Vault token file created"
}

create_vault_agent_service() {
    log_info "Creating Vault Agent systemd service..."
    
    cat > /etc/systemd/system/vault-agent.service << EOF
[Unit]
Description=Vault Agent
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$VAULT_BIN agent -config=/etc/vault-agent/vault-agent.hcl
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_info "✅ Vault Agent service created"
}

create_consul_config() {
    log_info "Creating Consul configuration 1 2 3..."
    local bind_ip="${NETMAKER_IP}"
    
    # Create backup of existing config if it exists
    if [ -f "/etc/consul.d/consul.hcl" ]; then
        local backup_file="/etc/consul.d/consul.hcl.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up existing Consul config to: $backup_file"
        cp "/etc/consul.d/consul.hcl" "$backup_file"
        log_info "✅ Backup created: $backup_file"
    fi
    
    cat > /etc/consul.d/consul.hcl << EOF
datacenter = "$DATACENTER"
data_dir = "/opt/consul"
log_level = "INFO"
node_name = "$NODE_NAME"
bind_addr = "$bind_ip"
client_addr = "0.0.0.0"
retry_join = ["consul.service.consul"]
server = false

advertise_addr = "$bind_ip"
client_addr = "0.0.0.0"

connect {
  enabled = true
}

ports {
  grpc = 8502
  grpc_tls = 8503
  https = 8501
  dns = 8600
}

tls {
  defaults {
    verify_incoming = true
    verify_outgoing = true
    ca_file = "/etc/consul.d/tls/ca.pem"
    cert_file = "/etc/consul.d/tls/consul.pem"
    key_file = "/etc/consul.d/tls/consul-key.pem"
  }
  internal_rpc {
    verify_server_hostname = true
  }
}

acl = {
  enabled = true
  default_policy = "allow"
}

ui_config {
  enabled = true
}

auto_reload_config = true
EOF
    
    log_info "✅ Consul configuration created"
    chown consul:consul /etc/consul.d/consul.hcl
    chmod 640 /etc/consul.d/consul.hcl
    
    log_info "Consul configuration generated with bind address: $bind_ip"
}

create_nomad_config() {
    log_info "Creating Nomad configuration..."
    local bind_ip="${NETMAKER_IP}"
    
    # Create backup of existing config if it exists
    if [ -f "/etc/nomad.d/nomad.hcl" ]; then
        local backup_file="/etc/nomad.d/nomad.hcl.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up existing Nomad config to: $backup_file"
        cp "/etc/nomad.d/nomad.hcl" "$backup_file"
        log_info "✅ Backup created: $backup_file"
    fi
    
    cat > /etc/nomad.d/nomad.hcl << EOF
datacenter = "dc1"
data_dir = "/opt/nomad/data"
log_level = "INFO"
log_json = true
log_file = "/opt/nomad/logs/"
name = "$NODE_NAME"
bind_addr = "$bind_ip"

server {
  enabled = false
}

client {
  enabled = true
  servers = ["$NOMAD_SERVER_IP:4647"]
  host_volume "docker-sock" {
    path = "/var/run/docker.sock"
    read_only = false
  }
}

consul {
  address = "127.0.0.1:8500"
}

tls {
  http = true
  rpc = true
  ca_file = "/etc/nomad.d/tls/ca.pem"
  cert_file = "/etc/nomad.d/tls/nomad.pem"
  key_file = "/etc/nomad.d/tls/nomad-key.pem"
  verify_server_hostname = false
  verify_https_client = false
  rpc_upgrade_mode = false           # ADDED: Prevents RPC upgrade issues
  verify_incoming = false            # ADDED: Relaxed for client connections
}

acl {
  enabled = true
}

vault {
  enabled = true
  address = "$VAULT_ADDR"
  create_from_role = "nomad-cluster"
  task_token_ttl = "1h"
  ca_path = "/etc/nomad.d/tls/ca.pem"
  cert_path = "/etc/nomad.d/tls/nomad.pem"
  key_path = "/etc/nomad.d/tls/nomad-key.pem"
}
EOF
    
    log_info "✅ Nomad configuration created"
    chown nomad:nomad /etc/nomad.d/nomad.hcl
    chmod 640 /etc/nomad.d/nomad.hcl
    
    log_info "Nomad configuration generated with bind address: $bind_ip"
}

create_consul_service() {
    log_info "Creating Consul systemd service..."
    
    cat > /etc/systemd/system/consul.service << EOF
[Unit]
Description=Consul
Documentation=https://www.consul.io/
Requires=network-online.target vault-agent.service
After=network-online.target vault-agent.service
ConditionFileNotEmpty=/etc/consul.d/consul.hcl

[Service]
Type=simple
User=consul
Group=consul
ExecStart=$CONSUL_BIN agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    log_info "✅ Consul service created"
}

create_nomad_service() {
    log_info "Creating Nomad systemd service..."
    
    cat > /etc/systemd/system/nomad.service << EOF
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/
Requires=network-online.target consul.service
After=network-online.target consul.service
ConditionFileNotEmpty=/etc/nomad.d/nomad.hcl

[Service]
Type=notify
User=root
Group=root
ExecStart=$NOMAD_BIN agent -config=/etc/nomad.d/nomad.hcl
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    log_info "✅ Nomad service created"
}

start_services() {
    log_info "Starting services..."
    
    systemctl daemon-reload
    
    # Start Vault Agent first
    systemctl enable vault-agent
    systemctl start vault-agent
    log_info "Vault Agent started"
    
    # Wait for Consul certificates to be generated
    log_info "Waiting for Consul certificates to be generated..."
    printf "Progress: "
    for i in {1..60}; do
        if [ -f "/etc/consul.d/tls/consul.pem" ] && [ -f "/etc/consul.d/tls/consul-key.pem" ] && [ -f "/etc/consul.d/tls/ca.pem" ]; then
            printf "\n"
            log_info "✅ Consul certificates generated successfully"
            # Fix ownership of certificate files for consul service
            chown consul:consul /etc/consul.d/tls/consul.pem
            chown consul:consul /etc/consul.d/tls/consul-key.pem
            chown consul:consul /etc/consul.d/tls/ca.pem
            chmod 644 /etc/consul.d/tls/consul.pem
            chmod 600 /etc/consul.d/tls/consul-key.pem
            chmod 644 /etc/consul.d/tls/ca.pem
            log_info "✅ Consul certificate permissions fixed"
            break
        fi
        printf "%d " $i
        sleep 2
        if [ $i -eq 60 ]; then
            printf "\n"
            log_error "⚠️  Timeout waiting for Consul certificates"
            log_error "Following Consul certificates were generated:"
            ls -la /etc/consul.d/tls/ || true
            log_error "Please check Vault Agent logs for more details"
            log_info "You can also check the status of Vault Agent with: [sudo systemctl status vault-agent] and [journalctl -u vault-agent -n 100] "
            return 1
        fi
    done
    
    # Wait for Nomad certificates to be generated
    log_info "Waiting for Nomad certificates to be generated..."
    printf "Progress: "
    for i in {1..60}; do
        if [ -f "/etc/nomad.d/tls/nomad.pem" ] && [ -f "/etc/nomad.d/tls/nomad-key.pem" ] && [ -f "/etc/nomad.d/tls/ca.pem" ]; then
            printf "\n"
            log_info "✅ Nomad certificates generated successfully"
            # Fix ownership of certificate files for nomad service
            chown nomad:nomad /etc/nomad.d/tls/nomad.pem
            chown nomad:nomad /etc/nomad.d/tls/nomad-key.pem
            chown nomad:nomad /etc/nomad.d/tls/ca.pem
            chmod 644 /etc/nomad.d/tls/nomad.pem
            chmod 600 /etc/nomad.d/tls/nomad-key.pem
            chmod 644 /etc/nomad.d/tls/ca.pem
            log_info "✅ Nomad certificate permissions fixed"
            break
        fi
        printf "%d " $i
        sleep 2
        if [ $i -eq 60 ]; then
            printf "\n"
            log_error "⚠️  Timeout waiting for Nomad certificates"
            log_error "Following Nomad certificates were generated:"
            ls -la /etc/nomad.d/tls/ || true
            log_error "Please check Vault Agent logs for more details"
            log_info "You can also check the status of Vault Agent with: [sudo systemctl status vault-agent] and [journalctl -u vault-agent -n 100] "
            return 1
        fi
    done
    
    # Start Consul
    systemctl enable consul
    
    # Try to start Consul with timeout handling
    log_info "Starting Consul (with timeout protection)..."
    if timeout 30 systemctl start consul; then
        log_info "Consul started successfully"
    else
        log_info "⚠️  Consul start command timed out, checking if service is actually running..."
        
        # Check if Consul is actually running despite the timeout
        sleep 3
        if systemctl is-active --quiet consul; then
            log_success "✅ Consul is running (timeout was false positive)"
        else
            log_info "❌ Consul failed to start properly"
            # Try to get more information about the failure
            log_info "Consul status:"
            systemctl status consul --no-pager || true
            log_info "Recent Consul log_infos:"
            journalctl -u consul --no-pager -n 20 || true
            log_error "Failed to start Consul service"
            return 1
        fi
    fi
    
    # Wait for Consul to be ready
    sleep 5
    
    # Start Nomad
    systemctl enable nomad
    
    # Try to start Nomad with timeout handling
    log_info "Starting Nomad (with timeout protection)..."
    if timeout 30 systemctl start nomad; then
        log_info "Nomad started successfully"
    else
        log_info "⚠️  Nomad start command timed out, checking if service is actually running..."
        
        # Check if Nomad is actually running despite the timeout
        sleep 3
        if systemctl is-active --quiet nomad; then
            log_success "✅ Nomad is running (timeout was false positive)"
        else
            log_info "❌ Nomad failed to start properly"
            # Try to get more information about the failure
            log_info "Nomad status:"
            systemctl status nomad --no-pager || true
            log_info "Recent Nomad logs:"
            journalctl -u nomad --no-pager -n 20 || true
            log_error "Failed to start Nomad service"
            return 1
        fi
    fi
    
    log_success "✅ All services started"
}

check_service_status() {
    log_info "Checking service status..."
    
    echo "=== Vault Agent Status ==="
    systemctl status vault-agent --no-pager || true
    
    echo ""
    echo "=== Consul Status ==="
    systemctl status consul --no-pager || true
    
    echo ""
    echo "=== Nomad Status ==="
    systemctl status nomad --no-pager || true
    
    echo ""
    echo "=== Certificate Files ==="
    echo "Consul certificates:"
    ls -la /etc/consul.d/tls/ || true
    echo "Nomad certificates:"
    ls -la /etc/nomad.d/tls/ || true
    
    echo ""
    echo "=== Certificate Verification ==="
    if [ -f "/etc/consul.d/tls/consul.pem" ]; then
        echo "Consul certificate:"
        openssl x509 -in /etc/consul.d/tls/consul.pem -text -noout | grep -A 5 "Subject Alternative Name" || true
    fi
    if [ -f "/etc/nomad.d/tls/nomad.pem" ]; then
        echo "Nomad certificate:"
        openssl x509 -in /etc/nomad.d/tls/nomad.pem -text -noout | grep -A 5 "Subject Alternative Name" || true
    fi
}

setup_service_mesh() {
    export NODE_IP=$NETMAKER_IP
    log_info "🚀 Starting Vault-based node bootstrap process..."
    log_info "Node IP: $NODE_IP"
    log_info "Vault Address: $VAULT_ADDR"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_info "❌ This script must be run as root"
        exit 1
    fi
    
    # Validate node IP
    if [[ -z "$NODE_IP" ]]; then
        log_info "❌ Could not determine node IP address"
        exit 1
    fi
    
    # Detect binary paths before proceeding
    detect_binary_paths
    
    # Verify that binaries are functional
    verify_binary_versions
    
    # Create service users
    create_service_users
    
    create_host_volumes
    create_service_directories
    create_vault_agent_config
    create_certificate_templates
    create_ownership_scripts
    create_vault_token_file
    create_vault_agent_service
    create_consul_config
    create_nomad_config
    create_consul_service
    create_nomad_service
    start_services
    
    log_info "🎉 Node bootstrap completed successfully!"
    log_info "Node $NODE_IP has been configured with Vault-based certificate management"
    
    # Show final status
    check_service_status
    
    log_info "📋 Summary:"
    log_info "  • Vault Agent: Automatically manages certificates (12h renewal)"
    log_info "  • Consul: Configured with individual node certificate"
    log_info "  • Nomad: Client node with TLS certificates and workload identity"
    log_info "  • Certificates: /etc/consul.d/tls/ and /etc/nomad.d/tls/"
    log_info ""
    log_info "🔧 Monitoring commands:"
    log_info "  • Check Vault Agent: sudo journalctl -u vault-agent -f"
    log_info "  • Check Consul: sudo journalctl -u consul -f"
    log_info "  • Check Nomad: sudo journalctl -u nomad -f"
    log_info "  • View certificates: ls -la /etc/consul.d/tls/ && ls -la /etc/nomad.d/tls/"
}