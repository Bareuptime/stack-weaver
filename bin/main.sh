#!/bin/bash
set -euo pipefail
IFS=$'\n\t'


# If bundling, the bundler will inline the content here.
# If not bundling, make sure lib/logging.sh exists.
if [[ -z "${BUNDLED:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  source "$PROJECT_ROOT/lib/logging.sh"
fi


# Cluster Forge - Nomad/Consul/Netmaker Cluster Setup Script
# Usage: 
#   For server: sudo NETMAKER_TOKEN=<token> ROLE=server NOMAD_SERVER_IP=10.0.1.10 ./cluster-forge.sh
#   For client: sudo NETMAKER_TOKEN=<token> ROLE=client NOMAD_SERVER_IP=10.0.1.10 ./cluster-forge.sh

# =============================================================================
# CONFIGURATION
# =============================================================================

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
VAULT_TOKRN="${VAULT_TOKEN:-}"

# =============================================================================
# LOGGING
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/cluster-forge.log
}

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
        error "VAULT_ADDR is mandatory. Please provide the Vault address."
    fi

    if [[ -z "$VAULT_TOKEN" ]]; then
        error "VAULT_TOKEN is mandatory. Please provide the Vault token."
    fi
}

# =============================================================================
# SYSTEM PREPARATION
# =============================================================================

prepare_system() {
    log "Preparing system for $ROLE node..."
    
    # Update system
    apt-get update -y
    apt-get upgrade -y
    
    # Install required packages
    apt-get install -y \
        curl wget unzip jq apt-transport-https ca-certificates \
        gnupg lsb-release software-properties-common ufw dnsmasq
    
    # Create directories
    mkdir -p /opt/{nomad,consul}
    mkdir -p /etc/{nomad.d,consul.d}
    mkdir -p /var/log/{nomad,consul}
    
    # Create users
    useradd --system --home /etc/nomad.d --shell /bin/false nomad 2>/dev/null || true
    useradd --system --home /etc/consul.d --shell /bin/false consul 2>/dev/null || true
    
    # Set ownership
    chown -R nomad:nomad /opt/nomad /etc/nomad.d /var/log/nomad
    chown -R consul:consul /opt/consul /etc/consul.d /var/log/consul
    
    log "System preparation completed"
}

# =============================================================================
# NETMAKER CLIENT INSTALLATION
# =============================================================================
validate_netclient() {
    log "Validating existing Netmaker client installation..."
    
    # Check if netclient binary exists and is executable
    # Check common locations where netclient might be installed
    local netclient_paths=(
        "/usr/local/bin/netclient"
        "/usr/bin/netclient"
        "/opt/netclient/netclient"
        "$(which netclient 2>/dev/null)"
    )
    
    local netclient_found=false
    local netclient_path=""
    
    for path in "${netclient_paths[@]}"; do
        if [[ -n "$path" && -x "$path" ]]; then
            netclient_found=true
            netclient_path="$path"
            break
        fi
    done
    
    # Also try command -v as fallback
    if [[ "$netclient_found" == false ]] && command -v netclient &> /dev/null; then
        netclient_found=true
        netclient_path=$(command -v netclient)
    fi
    
    if [[ "$netclient_found" == false ]]; then
        log "Netclient binary not found in PATH or common locations"
        return 1
    fi
    
    log "Found netclient at: $netclient_path"
    
    # Check if netclient service is running
    if ! systemctl is-active --quiet netclient 2>/dev/null; then
        log "Netclient service is not running"
        return 1
    fi
    
    # Verify netclient is functional by checking its status
    if ! "$netclient_path" list &> /dev/null; then
        log "Netclient binary exists but is not functional"
        return 1
    fi
    
    # Check if port 51821 is in use (indicating WireGuard is active)
    if ! netstat -tuln 2>/dev/null | grep -q ":$STATIC_PORT " && ! ss -tuln 2>/dev/null | grep -q ":$STATIC_PORT "; then
        log "Port $STATIC_PORT is not in use (WireGuard may not be active)"
        return 1
    fi
    
    # Check if netmaker interface exists and has an IP
    local netmaker_interface=$(ip link show | grep -o -E "(nm-[^:]*|netmaker)" | head -1)
    if [[ -z "$netmaker_interface" ]]; then
        log "No Netmaker interface found (no nm-* or netmaker interface)"
        return 1
    fi
    
    # Check if the interface has an IP address
    local netmaker_ip=$(ip addr show "$netmaker_interface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    if [[ -z "$netmaker_ip" ]]; then
        log "Netmaker interface $netmaker_interface has no IP address"
        return 1
    fi
    
    # Test connectivity through the interface
    if ! ping -c 1 -W 3 "$netmaker_ip" >/dev/null 2>&1; then
        log "Connectivity test failed for Netmaker IP: $netmaker_ip"
        return 1
    fi
    
    # If we get here, netclient is working properly
    log "✓ Netclient is already installed and working"
    log "  • Interface: $netmaker_interface"
    log "  • IP: $netmaker_ip"
    log "  • Port: $STATIC_PORT"
    log "  • Service: active"
    
    # Export the IP for use in other functions
    export NETMAKER_IP="$netmaker_ip"
    
    return 0
}

install_netclient() {
    log "Installing Netmaker client..."
    
    # Download and install netclient
    wget -O /tmp/netclient https://fileserver.netmaker.io/releases/download/v1.0.0/netclient-linux-amd64
    chmod +x /tmp/netclient
    /tmp/netclient install
    
    log "Netclient installed successfully"
}

join_netmaker_network() {
    log "Joining Netmaker network..."
    
    # Get the main bridge IP (usually the default route interface)
    local endpoint_ip=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' | head -1)
    log "Detected endpoint IP: $endpoint_ip"
    
    
    # Join the network with static port
    netclient join -t "$NETMAKER_TOKEN" \
        --static-port -p "$STATIC_PORT" \
        -s true \
        --endpoint-ip "$endpoint_ip"
    
    # Wait for network interface to be ready
    log "Waiting for Netmaker interface to be ready..."
    local attempts=0
    local netmaker_ip=""
    
    while [[ $attempts -lt 30 ]]; do
        # Look for netmaker interface (usually starts with nm-)
        netmaker_ip=$(ip addr show | grep -A 1 "nm-" | grep -oP 'inet \K[0-9.]+' | head -1 || echo "")
        if [[ -n "$netmaker_ip" ]]; then
            log "Netmaker interface ready with IP: $netmaker_ip"
            break
        fi
        sleep 2
        ((attempts++))
    done
    
    if [[ -z "$netmaker_ip" ]]; then
        error "Failed to detect Netmaker interface IP after 60 seconds"
    fi
    
    # Export for use in other functions
    export NETMAKER_IP="$netmaker_ip"
    
    log "Successfully joined Netmaker network with IP: $netmaker_ip"
}

setup_netmaker() {
    log "Setting up Netmaker client..."
    
    # First, validate if netclient is already working
    if validate_netclient; then
        log "Netclient is already installed and working - skipping installation"
        return 0
    fi
    
    # If validation failed, proceed with installation
    log "Netclient validation failed - proceeding with installation"
    install_netclient
    join_netmaker_network
}

# =============================================================================
# DNS CONFIGURATION
# =============================================================================

disable_systemd_resolved() {
    log "Disabling systemd-resolved to let dnsmasq handle DNS..."
    
    # Check if systemd-resolved is active and disable it completely
    if systemctl is-active --quiet systemd-resolved; then
        log "systemd-resolved is active, disabling it completely..."
        
        # Stop and disable systemd-resolved
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        
        log "systemd-resolved stopped and disabled"
    else
        log "systemd-resolved is not active"
    fi
    
    log "DNS will be handled entirely by dnsmasq"
}

configure_dnsmasq() {
    log "Configuring dnsmasq for Consul DNS..."
    
    # Get network interfaces
    local netmaker_ip="${NETMAKER_IP}"
    
    # Stop dnsmasq if running
    systemctl stop dnsmasq 2>/dev/null || true
    
    # Create dnsmasq configuration directory
    mkdir -p /etc/dnsmasq.d
    
    # Wait for Docker bridge to be available (since we just installed Docker)
    log "Waiting for Docker bridge to be available..."
    local attempts=0
    local docker_ip=""
    while [[ $attempts -lt 30 ]]; do
        if ip addr show docker0 >/dev/null 2>&1; then
            docker_ip=$(ip addr show docker0 | grep -oP 'inet \K[0-9.]+' | head -1)
            if [[ -n "$docker_ip" ]]; then
                log "Docker bridge ready at: $docker_ip"
                break
            fi
        fi
        sleep 2
        ((attempts++))
    done
    
    if [[ -z "$docker_ip" ]]; then
        error "Docker bridge not available after 60 seconds. Docker installation failed or Docker service is not running."
    fi
    
    # Create ONLY the 10-consul file - don't touch any other DNS configs
    log "Creating /etc/dnsmasq.d/10-consul configuration..."
    cat > /etc/dnsmasq.d/10-consul << EOF
# Forward .service.consul queries to Consul DNS
server=/service.consul/${CONSUL_SERVER_IP}#8600
server=/consul/${CONSUL_SERVER_IP}#8600

# Use Google DNS for other queries
server=8.8.8.8
server=1.1.1.1

# Listen on standard DNS port 53
listen-address=127.0.0.1
listen-address=${docker_ip}
listen-address=${netmaker_ip}

port=53

# Bind only to the interfaces we're listening on
bind-interfaces

# Cache settings
cache-size=1000
EOF
    
    log "Created /etc/dnsmasq.d/10-consul with:"
    log "  • Consul DNS: ${CONSUL_SERVER_IP}:8600"
    log "  • Listen addresses: 127.0.0.1, ${docker_ip}, ${netmaker_ip}"
    
    # Start and enable dnsmasq
    systemctl enable dnsmasq
    systemctl start dnsmasq
    
    # Verify dnsmasq is running
    if systemctl is-active --quiet dnsmasq; then
        log "✓ dnsmasq configured and running"
        log "DNS listeners: 127.0.0.1:53, ${docker_ip}:53, ${netmaker_ip}:53"
        log "Consul DNS: Forwarding .service.consul queries to ${CONSUL_SERVER_IP}:8600"
    else
        error "Failed to start dnsmasq"
    fi
}

reload_dns_services() {
    log "Reloading DNS-related services..."
    
    # Reload systemd
    systemctl daemon-reload
    
    # Restart dnsmasq to ensure it picks up all changes
    systemctl restart dnsmasq
    
    # Wait a moment for services to stabilize
    sleep 3
    
    # Test DNS resolution
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        log "✓ DNS resolution test passed"
    else
        log "⚠ Warning: DNS resolution test failed"
    fi
    
    log "DNS services reloaded"
}

# =============================================================================
# FIREWALL CONFIGURATION
# =============================================================================

configure_firewall() {
    log "Configuring firewall..."
    
    # Reset UFW
    ufw --force reset
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH
    ufw allow 22/tcp
    
    # Netmaker/WireGuard
    ufw allow "$STATIC_PORT"/udp comment "Netmaker WireGuard"
    
    # Nomad
    ufw allow 4646/tcp  # HTTP API
    ufw allow 4647/tcp  # RPC
    ufw allow 4648/tcp  # Serf WAN
    
    # Consul
    ufw allow 8300/tcp  # Server RPC
    ufw allow 8301/tcp  # Serf LAN
    ufw allow 8301/udp  # Serf LAN
    ufw allow 8302/tcp  # Serf WAN
    ufw allow 8302/udp  # Serf WAN
    ufw allow 8500/tcp  # HTTP API
    ufw allow 8600/tcp  # DNS
    ufw allow 8600/udp  # DNS
    
    # DNS
    ufw allow 53/tcp    # DNS TCP
    ufw allow 53/udp    # DNS UDP
    
    # Enable firewall
    ufw --force enable
    
    log "Firewall configuration completed"
}

# =============================================================================
# DOCKER INSTALLATION
# =============================================================================

install_docker() {
    log "Installing Docker..."
    
    # Detect OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION_CODENAME=$VERSION_CODENAME
    else
        error "Cannot detect OS. /etc/os-release not found."
    fi
    
    log "Detected OS: $OS $VERSION_CODENAME"
    
    # Clean up any existing Docker repositories and keys
    log "Cleaning up existing Docker repositories..."
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    
    # Use appropriate GPG key and repository based on OS
    if [[ "$OS" == "ubuntu" ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    elif [[ "$OS" == "debian" ]]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    else
        error "Unsupported OS: $OS. This script supports Ubuntu and Debian only."
    fi
    
    # Install Docker
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Configure Docker daemon
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

    # Start Docker and add nomad user to docker group
    systemctl enable docker
    systemctl start docker
    usermod -aG docker nomad
    
    log "Docker installation completed"
}

# =============================================================================
# INSTALL HASHICORP TOOLS
# =============================================================================

validate_hashicorp_tools() {
    log "Validating existing Nomad and Consul installations..."
    
    local nomad_installed=false
    local consul_installed=false
    
    # Check if Nomad is installed and functional
    if command -v nomad &> /dev/null; then
        if nomad version &> /dev/null; then
            local nomad_ver=$(nomad version | head -1)
            log "✓ Nomad is already installed: $nomad_ver"
            nomad_installed=true
        else
            log "Nomad binary found but not functional"
        fi
    else
        log "Nomad not found in PATH"
    fi
    
    # Check if Consul is installed and functional
    if command -v consul &> /dev/null; then
        if consul version &> /dev/null; then
            local consul_ver=$(consul version | head -1)
            log "✓ Consul is already installed: $consul_ver"
            consul_installed=true
        else
            log "Consul binary found but not functional"
        fi
    else
        log "Consul not found in PATH"
    fi
    
    # Return status: 0 if both installed, 1 if neither, 2 if partial
    if [[ "$nomad_installed" == true && "$consul_installed" == true ]]; then
        return 0  # Both installed
    elif [[ "$nomad_installed" == false && "$consul_installed" == false ]]; then
        return 1  # Neither installed
    else
        return 2  # Partial installation
    fi
}

install_hashicorp_tools() {
    log "Checking HashiCorp tools installation status..."
    
    # Validate existing installations
    if validate_hashicorp_tools; then
        log "Both Nomad and Consul are already installed and functional - skipping installation"
        return 0
    fi
    
    local validation_result=$?
    if [[ $validation_result -eq 2 ]]; then
        log "Partial installation detected - proceeding with full installation to ensure consistency"
    else
        log "HashiCorp tools not found - proceeding with installation"
    fi
    
    log "Installing Nomad and Consul..."
    
    # Check if HashiCorp repository is already configured
    if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
        log "Adding HashiCorp repository..."
        # Add HashiCorp's official GPG key and repository
        wget -q -O - https://apt.releases.hashicorp.com/gpg | gpg --dearmor --batch --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/hashicorp.list
    else
        log "HashiCorp repository already configured"
    fi
    
    # Update and install
    apt-get update -y
    apt-get install -y nomad consul consul
    
    # Verify installations
    if nomad version &> /dev/null && consul version &> /dev/null; && vault version &> /dev/null; then
        local nomad_ver=$(nomad version | head -1)
        local consul_ver=$(consul version | head -1)
        local vault_ver=$(vault version | head -1)
        log "✓ Installation successful:"
        log "  • $nomad_ver"
        log "  • $consul_ver"
        log "  • $vault_ver"
    else
        error "Installation verification failed - one or both tools are not working"
    fi
    
    log "Nomad and Consul installation completed"
}

configure_client_c() {
    log "Setting up Consul service mesh..."
    ./
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

start_services() {
    log "Starting services..."
    
    # Stop any existing services
    systemctl stop consul nomad 2>/dev/null || true
    
    # Reload systemd
    systemctl daemon-reload
    
    # Start and enable Consul first
    systemctl enable consul
    log "Starting Consul with timeout..."
    if timeout 30 systemctl start consul; then
        log "Consul start command completed"
    else
        log "Warning: Consul start command timed out, checking status..."
    fi
    
    # Check Consul status
    if systemctl is-active --quiet consul; then
        log "✓ Consul service is active"
    else
        log "✗ Consul service failed to start"
        systemctl status consul --no-pager -l
        error "Consul failed to start"
    fi
    
    # Wait for Consul to be ready
    log "Waiting for Consul to be ready..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -s http://127.0.0.1:8500/v1/status/leader >/dev/null 2>&1; then
            log "Consul is ready"
            break
        fi
        sleep 2
        ((attempts++))
    done
    
    # Start and enable Nomad
    systemctl enable nomad
    log "Starting Nomad with timeout..."
    if timeout 30 systemctl start nomad; then
        log "Nomad start command completed"
    else
        log "Warning: Nomad start command timed out, checking status..."
    fi
    
    # Check Nomad status
    if systemctl is-active --quiet nomad; then
        log "✓ Nomad service is active"
    else
        log "✗ Nomad service failed to start"
        systemctl status nomad --no-pager -l
        error "Nomad failed to start"
    fi
    
    # Wait for Nomad to be ready
    log "Waiting for Nomad to be ready..."
    attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -s http://127.0.0.1:4646/v1/status/leader >/dev/null 2>&1; then
            log "Nomad is ready"
            break
        fi
        sleep 2
        ((attempts++))
    done
    
    log "Services started successfully"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_installation() {
    log "Validating installation..."
    
    local errors=0
    
    # Check service status
    for service in consul nomad docker dnsmasq; do
        if systemctl is-active --quiet $service; then
            log "✓ $service is running"
        else
            log "✗ $service is not running"
            ((errors++))
        fi
    done
    
    # Check Netmaker connectivity
    if [[ -n "${NETMAKER_IP:-}" ]]; then
        if ping -c 1 -W 3 "$NETMAKER_IP" >/dev/null 2>&1; then
            log "✓ Netmaker network connectivity ($NETMAKER_IP)"
        else
            log "✗ Netmaker network connectivity failed"
            ((errors++))
        fi
    fi
    
    # Check API endpoints
    if curl -s "http://127.0.0.1:8500/v1/status/leader" >/dev/null 2>&1; then
        log "✓ Consul API is responding"
    else
        log "✗ Consul API is not responding"
        ((errors++))
    fi
    
    if curl -s "http://127.0.0.1:4646/v1/status/leader" >/dev/null 2>&1; then
        log "✓ Nomad API is responding"
    else
        log "✗ Nomad API is not responding"
        ((errors++))
    fi
    
    # Check Docker
    if docker info >/dev/null 2>&1; then
        log "✓ Docker is functional"
    else
        log "✗ Docker is not functional"
        ((errors++))
    fi
    
    # Check DNS resolution
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        log "✓ DNS resolution is working"
    else
        log "✗ DNS resolution failed"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        log "✓ All validations passed!"
        return 0
    else
        log "✗ Validation failed with $errors errors"
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log "Starting Cluster Forge - Nomad/Consul/Netmaker setup..."
    log "Role: $ROLE"
    log "Server IP: $NOMAD_SERVER_IP"
    log "Node Name: $NODE_NAME"
    log "Netmaker Token: [REDACTED]"
    
    validate_input
    prepare_system
    setup_netmaker
    install_docker
    disable_systemd_resolved
    configure_dnsmasq
    reload_dns_services
    configure_firewall
    install_hashicorp_tools
    start_services
    
    if validate_installation; then
        local main_ip=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' | head -1)
        
        log "============================================"
        log "🎉 Cluster Forge completed successfully!"
        log "============================================"
        log "Main IP: $main_ip"
        log "Netmaker IP: ${NETMAKER_IP:-N/A}"
        log ""
        log "🌐 Web Interfaces:"
        log "  • Consul UI: http://${NETMAKER_IP:-$main_ip}:8500"
        log "  • Nomad UI: http://${NETMAKER_IP:-$main_ip}:4646"
        log ""
        log "📁 Configuration files:"
        log "  • Consul: /etc/consul.d/consul.hcl"
        log "  • Nomad: /etc/nomad.d/nomad.hcl"
        log "  • dnsmasq: /etc/dnsmasq.d/10-consul"
        log ""
        log "🔧 Useful commands:"
        log "  • Check status: systemctl status consul nomad dnsmasq"
        log "  • View logs: journalctl -f -u consul -u nomad"
        log "  • Consul members: consul members"
        log "  • Nomad nodes: nomad node status"
        log "  • Netmaker status: netclient list"
        log ""
        log "🔑 Network Information:"
        if [[ -n "$ENCRYPT_KEY" ]]; then
            log "  • Consul encryption key: $ENCRYPT_KEY"
            log "    (Save this key - you'll need it for additional nodes)"
        fi
        log "  • Netmaker network: Connected via ${NETMAKER_IP}"
        log "  • DNS: Configured for .service.consul resolution"
        log ""
        log "🎯 Next Steps:"
        log "  1. Access the web UIs to verify cluster status"
        log "  2. Test DNS: nslookup consul.service.consul"
        log "  3. Deploy your first Nomad job"
        log "============================================"
    else
        error "Cluster Forge setup failed. Check the logs above for details."
    fi
}

# Execute main function
main "$@"