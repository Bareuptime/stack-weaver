#!/bin/bash
# =============================================================================
# SERVICE MESH SETUP MODULE
# Handles Nomad/Consul/Vault service mesh configuration
# =============================================================================

# =============================================================================
# SERVICE MESH SETUP FUNCTION
# =============================================================================

setup_service_mesh() {
    log_info "Setting up service mesh configuration..."
    
    # This function will be implemented to handle:
    # - Consul server/client configuration
    # - Nomad server/client configuration 
    # - Vault integration
    # - Certificate management
    # - Service mesh connectivity
    
    log_info "Service mesh setup completed (placeholder)"
}

# The rest of the existing content from setup_service_mesh.sh follows below...
# This allows the existing functions to still work while providing the main entry point

# Complete Vault-Based Node Bootstrap Script
# This script sets up a new node with automatic certificate management using Vault PKI

set -e


ROLE="${ROLE:-client}"                    # server or client
NOMAD_SERVER_IP="${NOMAD_SERVER_IP:-}"    # IP of the server node
CONSUL_SERVER_IP="${CONSUL_SERVER_IP:-}"    # IP of the server node
NODE_NAME="${NODE_NAME:-$(hostname)}"     # Node name
DATACENTER="${DATACENTER:-dc1}"           # Datacenter name
ENCRYPT_KEY="${ENCRYPT_KEY:-}"            # Consul encryption key (auto-generated if empty)
NETMAKER_TOKEN="${NETMAKER_TOKEN:-}"      # Netmaker enrollment token (mandatory)
STATIC_PORT="${STATIC_PORT:-51821}"       # Netmaker static port
CONSUL_AGENT_TOKEN="${CONSUL_AGENT_TOKEN:-}"  # Consul agent token (mandatory)
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"


error() {
    echo "[ERROR] $*" >&2
    exit 1
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

    if [[ -z "$CONSUL_AGENT_TOKEN" ]]; then
        error "CONSUL_AGENT_TOKEN is mandatory. Please provide the Consul agent token."
    fi

    if [[ -z "$VAULT_ADDR" ]]; then
        error "VAULT_ADDR must be set to the Vault server address"
    fi
    if [[ -z "$VAULT_TOKEN" ]]; then
        error "VAULT_TOKEN must be set to the Vault authentication token"
    fi
}


log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

create_service_directories() {
    log "Creating service directories..."
    
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
    chown -R vault:vault /var/lib/vault-agent /var/log/vault-agent
    chown -R consul:consul /etc/consul.d /opt/consul
    chown -R nomad:nomad /etc/nomad.d /opt/nomad
    chown -R vault:vault /etc/consul.d/tls
    
    log_success "✅ Directories created"
}

# =============================================================================
# CREATE HOST VOLUMES
# =============================================================================

create_host_volumes() {
    log "Creating Nomad host volume directories..."
    
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
    log "Creating Vault Agent configuration..."
    
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
}

template {
  source      = "/etc/vault-agent/templates/consul-key.tpl"
  destination = "/etc/consul.d/tls/consul-key.pem"
  perms       = 0600
}

template {
  source      = "/etc/vault-agent/templates/ca-cert.tpl"
  destination = "/etc/consul.d/tls/ca.pem"
  perms       = 0644
}
EOF
    
    log "✅ Vault Agent config created"
}

create_certificate_templates() {
    log "Creating certificate templates..."
    
    # CA certificate template
    cat > /etc/vault-agent/templates/ca-cert.tpl << 'EOF'
{{- with secret "pki-nodes/ca_chain" -}}
{{ .Data.certificate }}
{{- end -}}
EOF

    # Consul certificate template  
    cat > /etc/vault-agent/templates/consul-cert.tpl << EOF
{{- with secret "pki-nodes/issue/node-cert" 
    "common_name=consul.service.consul"
    "ip_sans=$NODE_IP,127.0.0.1"
    "alt_names=localhost,consul"
    "ttl=12h" -}}
{{ .Data.certificate }}
{{- end -}}
EOF

    # Private key template
    cat > /etc/vault-agent/templates/consul-key.tpl << EOF
{{- with secret "pki-nodes/issue/node-cert" 
    "common_name=consul.service.consul"
    "ip_sans=$NODE_IP,127.0.0.1"
    "alt_names=localhost,consul"
    "ttl=12h" -}}
{{ .Data.private_key }}
{{- end -}}
EOF
    
    log_success "✅ Certificate templates created"
}

create_vault_token_file() {
    log "Creating Vault token file..."
    
    echo "$VAULT_TOKEN" > /etc/vault-agent/token
    chown vault:vault /etc/vault-agent/token
    chmod 600 /etc/vault-agent/token

    log_success "✅ Vault token file created"
}

create_vault_agent_service() {
    log "Creating Vault Agent systemd service..."
    
    cat > /etc/systemd/system/vault-agent.service << 'EOF'
[Unit]
Description=Vault Agent
After=network.target
Wants=network.target

[Service]
Type=simple
User=vault
Group=vault
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/vault-agent.hcl
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log "✅ Vault Agent service created"
}

create_consul_config() {
    log "Creating Consul configuration..."
    local bind_ip="${NETMAKER_IP}"
    
    cat > /etc/consul.d/consul.hcl << EOF
datacenter = "$DATACENTER"
data_dir = "/opt/consul"
log_level = "INFO"
node_name = "$NODE_NAME"
bind_addr = "$bind_ip"
client_addr = "0.0.0.0"
retry_join = ["$CONSUL_SERVER_IP"]
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
    
    log "✅ Consul configuration created"
    chown consul:consul /etc/consul.d/consul.hcl
    chmod 640 /etc/consul.d/consul.hcl
    
    log "Consul configuration generated with bind address: $bind_ip"
}

create_nomad_config() {
    log "Creating Nomad configuration..."
    local bind_ip="${NETMAKER_IP}"
    
    cat > /etc/nomad.d/nomad.hcl << EOF
datacenter = "dc1"
data_dir = "/opt/nomad/data"
log_level = "INFO"
log_json = true
log_file = "/opt/nomad/logs/"
node_name = "$NODE_NAME"

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

acl {
  enabled = true
}
EOF
    
    log "✅ Nomad configuration created"
    chown nomad:nomad /etc/nomad.d/nomad.hcl
    chmod 640 /etc/nomad.d/nomad.hcl
    
    log "Nomad configuration generated with bind address: $bind_ip"
}

create_consul_service() {
    log "Creating Consul systemd service..."
    
    cat > /etc/systemd/system/consul.service << 'EOF'
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
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    log "✅ Consul service created"
}

create_nomad_service() {
    log "Creating Nomad systemd service..."
    
    cat > /etc/systemd/system/nomad.service << 'EOF'
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
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d/nomad.hcl
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    log "✅ Nomad service created"
}

start_services() {
    log "Starting services..."
    
    systemctl daemon-reload
    
    # Start Vault Agent first
    systemctl enable vault-agent
    systemctl start vault-agent
    log "Vault Agent started"
    
    # Wait for certificates to be generated
    log "Waiting for certificates to be generated..."
    for i in {1..60}; do
        if [ -f "/etc/consul.d/tls/consul.pem" ] && [ -f "/etc/consul.d/tls/consul-key.pem" ]; then
            log "✅ Certificates generated successfully"
            break
        fi
        sleep 2
        if [ $i -eq 60 ]; then
            log "⚠️  Timeout waiting for certificates"
        fi
    done
    
    # Start Consul
    systemctl enable consul
    systemctl start consul
    log "Consul started"
    
    # Wait for Consul to be ready
    sleep 5
    
    # Start Nomad
    systemctl enable nomad
    systemctl start nomad
    log "Nomad started"
    
    log "✅ All services started"
}

check_service_status() {
    log "Checking service status..."
    
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
    ls -la /etc/consul.d/tls/ || true
    
    echo ""
    echo "=== Certificate Verification ==="
    if [ -f "/etc/consul.d/tls/consul.pem" ]; then
        openssl x509 -in /etc/consul.d/tls/consul.pem -text -noout | grep -A 5 "Subject Alternative Name" || true
    fi
}

main() {
    export NODE_IP=$NETMAKER_IP
    log "🚀 Starting Vault-based node bootstrap process..."
    log "Node IP: $NODE_IP"
    log "Vault Address: $VAULT_ADDR"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "❌ This script must be run as root"
        exit 1
    fi
    
    # Validate node IP
    if [[ -z "$NODE_IP" ]]; then
        log "❌ Could not determine node IP address"
        exit 1
    fi
    
    create_host_volumes
    create_service_directories
    create_vault_agent_config
    create_certificate_templates
    create_vault_token_file
    create_vault_agent_service
    create_consul_config
    create_nomad_config
    create_consul_service
    create_nomad_service
    start_services
    
    log "🎉 Node bootstrap completed successfully!"
    log "Node $NODE_IP has been configured with Vault-based certificate management"
    
    # Show final status
    check_service_status
    
    log "📋 Summary:"
    log "  • Vault Agent: Automatically manages certificates (12h renewal)"
    log "  • Consul: Configured with individual node certificate"
    log "  • Nomad: Client node ready to join cluster"
    log "  • Certificates: /etc/consul.d/tls/"
    log ""
    log "🔧 Monitoring commands:"
    log "  • Check Vault Agent: sudo journalctl -u vault-agent -f"
    log "  • Check Consul: sudo journalctl -u consul -f"
    log "  • Check Nomad: sudo journalctl -u nomad -f"
    log "  • View certificates: ls -la /etc/consul.d/tls/"
}

# Run main function
main "$@"