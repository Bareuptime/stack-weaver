#!/bin/bash
# =============================================================================
# SYSTEM CORE FUNCTIONS
# Core system preparation, docker, dns, firewall, and infrastructure setup
# =============================================================================

# =============================================================================
# SYSTEM PREPARATION
# =============================================================================

prepare_system() {
    log_info "Preparing system for $ROLE node..."
    
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
    
    log_info "System preparation completed"
}

# =============================================================================
# NETMAKER CLIENT INSTALLATION
# =============================================================================

validate_netclient() {
    log_info "Validating existing Netmaker client installation..."
    
    # Check if netclient binary exists and is executable
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
        log_info "Netclient binary not found in PATH or common locations"
        return 1
    fi
    
    log_info "Found netclient at: $netclient_path"
    
    # Check if netclient service is running
    if ! systemctl is-active --quiet netclient 2>/dev/null; then
        log_info "Netclient service is not running"
        return 1
    fi
    
    # Verify netclient is functional by checking its status
    if ! "$netclient_path" list &> /dev/null; then
        log_info "Netclient binary exists but is not functional"
        return 1
    fi
    
    # Check if port is in use (indicating WireGuard is active)
    if ! netstat -tuln 2>/dev/null | grep -q ":$STATIC_PORT " && ! ss -tuln 2>/dev/null | grep -q ":$STATIC_PORT "; then
        log_info "Port $STATIC_PORT is not in use (WireGuard may not be active)"
        return 1
    fi
    
    # Check if netmaker interface exists and has an IP
    local netmaker_interface=$(ip link show | grep -o -E "(nm-[^:]*|netmaker)" | head -1)
    if [[ -z "$netmaker_interface" ]]; then
        log_info "No Netmaker interface found (no nm-* or netmaker interface)"
        return 1
    fi
    
    # Check if the interface has an IP address
    local netmaker_ip=$(ip addr show "$netmaker_interface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    if [[ -z "$netmaker_ip" ]]; then
        log_info "Netmaker interface $netmaker_interface has no IP address"
        return 1
    fi
    
    # Test connectivity through the interface
    if ! ping -c 1 -W 3 "$netmaker_ip" >/dev/null 2>&1; then
        log_info "Connectivity test failed for Netmaker IP: $netmaker_ip"
        return 1
    fi
    
    # If we get here, netclient is working properly
    log_info "✓ Netclient is already installed and working"
    log_info "  • Interface: $netmaker_interface"
    log_info "  • IP: $netmaker_ip"
    log_info "  • Port: $STATIC_PORT"
    log_info "  • Service: active"
    
    # Export the IP for use in other functions
    export NETMAKER_IP="$netmaker_ip"
    
    return 0
}

install_netclient() {
    log_info "Installing Netmaker client..."
    
    # Download and install netclient
    wget -O /tmp/netclient https://fileserver.netmaker.io/releases/download/v1.0.0/netclient-linux-amd64
    chmod +x /tmp/netclient
    /tmp/netclient install
    
    log_info "Netclient installed successfully"
}

join_netmaker_network() {
    log_info "Joining Netmaker network..."
    
    # Get the main bridge IP (usually the default route interface)
    local endpoint_ip=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' | head -1)
    log_info "Detected endpoint IP: $endpoint_ip"
    
    # Join the network with static port
    netclient join -t "$NETMAKER_TOKEN" \
        --static-port -p "$STATIC_PORT" \
        -s true \
        --endpoint-ip "$endpoint_ip"
    
    # Wait for network interface to be ready
    log_info "Waiting for Netmaker interface to be ready..."
    local attempts=0
    local netmaker_ip=""
    
    while [[ $attempts -lt 30 ]]; do
        # Look for netmaker interface (usually starts with nm-)
        netmaker_ip=$(ip addr show | grep -A 1 "nm-" | grep -oP 'inet \K[0-9.]+' | head -1 || echo "")
        if [[ -n "$netmaker_ip" ]]; then
            log_info "Netmaker interface ready with IP: $netmaker_ip"
            break
        fi
        sleep 2
        ((attempts++))
    done
    
    if [[ -z "$netmaker_ip" ]]; then
        log_error "Failed to detect Netmaker interface IP after 60 seconds"
        return 1
    fi
    
    # Export for use in other functions
    export NETMAKER_IP="$netmaker_ip"
    
    log_info "Successfully joined Netmaker network with IP: $netmaker_ip"
}

setup_netmaker() {
    log_info "Setting up Netmaker client..."
    
    # First, validate if netclient is already working
    if validate_netclient; then
        log_info "Netclient is already installed and working - skipping installation"
        return 0
    fi
    
    # If validation failed, proceed with installation
    log_info "Netclient validation failed - proceeding with installation"
    install_netclient
    join_netmaker_network
}

# =============================================================================
# DNS CONFIGURATION
# =============================================================================

disable_systemd_resolved() {
    log_info "Disabling systemd-resolved to let dnsmasq handle DNS..."
    
    # Check if systemd-resolved is active and disable it completely
    if systemctl is-active --quiet systemd-resolved; then
        log_info "systemd-resolved is active, disabling it completely..."
        
        # Stop and disable systemd-resolved
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        
        log_info "systemd-resolved stopped and disabled"
    else
        log_info "systemd-resolved is not active"
    fi
    
    log_info "DNS will be handled entirely by dnsmasq"
}

configure_dnsmasq() {
    log_info "Configuring dnsmasq for Consul DNS..."
    
    # Get network interfaces
    local netmaker_ip="${NETMAKER_IP}"
    
    # Stop dnsmasq if running
    systemctl stop dnsmasq 2>/dev/null || true
    
    # Create dnsmasq configuration directory
    mkdir -p /etc/dnsmasq.d
    
    # Wait for Docker bridge to be available (since we just installed Docker)
    log_info "Waiting for Docker bridge to be available..."
    local attempts=0
    local docker_ip=""
    while [[ $attempts -lt 30 ]]; do
        if ip addr show docker0 >/dev/null 2>&1; then
            docker_ip=$(ip addr show docker0 | grep -oP 'inet \K[0-9.]+' | head -1)
            if [[ -n "$docker_ip" ]]; then
                log_info "Docker bridge ready at: $docker_ip"
                break
            fi
        fi
        sleep 2
        ((attempts++))
    done
    
    if [[ -z "$docker_ip" ]]; then
        log_error "Docker bridge not available after 60 seconds. Docker installation failed or Docker service is not running."
        return 1
    fi
    
    # Create ONLY the 10-consul file - don't touch any other DNS configs
    log_info "Creating /etc/dnsmasq.d/10-consul configuration..."
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
    
    log_info "Created /etc/dnsmasq.d/10-consul with:"
    log_info "  • Consul DNS: ${CONSUL_SERVER_IP}:8600"
    log_info "  • Listen addresses: 127.0.0.1, ${docker_ip}, ${netmaker_ip}"
    
    # Start and enable dnsmasq
    systemctl enable dnsmasq
    systemctl start dnsmasq
    
    # Verify dnsmasq is running
    if systemctl is-active --quiet dnsmasq; then
        log_info "✓ dnsmasq configured and running"
        log_info "DNS listeners: 127.0.0.1:53, ${docker_ip}:53, ${netmaker_ip}:53"
        log_info "Consul DNS: Forwarding .service.consul queries to ${CONSUL_SERVER_IP}:8600"
    else
        log_error "Failed to start dnsmasq"
        return 1
    fi
}

reload_dns_services() {
    log_info "Reloading DNS-related services..."
    
    # Reload systemd
    systemctl daemon-reload
    
    # Restart dnsmasq to ensure it picks up all changes
    systemctl restart dnsmasq
    
    # Wait a moment for services to stabilize
    sleep 3
    
    # Test DNS resolution
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        log_info "✓ DNS resolution test passed"
    else
        log_warn "⚠ Warning: DNS resolution test failed"
    fi
    
    log_info "DNS services reloaded"
}

# =============================================================================
# FIREWALL CONFIGURATION
# =============================================================================

configure_firewall() {
    log_info "Configuring firewall..."
    
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
    
    log_info "Firewall configuration completed"
}

# =============================================================================
# DOCKER INSTALLATION
# =============================================================================

install_docker() {
    log_info "Installing Docker..."
    
    # Detect OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION_CODENAME=$VERSION_CODENAME
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        return 1
    fi
    
    log_info "Detected OS: $OS $VERSION_CODENAME"
    
    # Clean up any existing Docker repositories and keys
    log_info "Cleaning up existing Docker repositories..."
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
        log_error "Unsupported OS: $OS. This script supports Ubuntu and Debian only."
        return 1
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
    
    log_info "Docker installation completed"
}

# =============================================================================
# INSTALL HASHICORP TOOLS
# =============================================================================

validate_hashicorp_tools() {
    log_info "Validating existing Nomad, Consul, and Vault installations..."
    
    local nomad_installed=false
    local consul_installed=false
    local vault_installed=false
    
    # Check if Nomad is installed and functional
    if command -v nomad &> /dev/null; then
        if nomad version &> /dev/null; then
            local nomad_ver=$(nomad version | head -1)
            log_info "✓ Nomad is already installed: $nomad_ver"
            nomad_installed=true
        else
            log_info "Nomad binary found but not functional"
        fi
    else
        log_info "Nomad not found in PATH"
    fi
    
    # Check if Consul is installed and functional
    if command -v consul &> /dev/null; then
        if consul version &> /dev/null; then
            local consul_ver=$(consul version | head -1)
            log_info "✓ Consul is already installed: $consul_ver"
            consul_installed=true
        else
            log_info "Consul binary found but not functional"
        fi
    else
        log_info "Consul not found in PATH"
    fi
    
    # Check if Vault is installed and functional
    if command -v vault &> /dev/null; then
        if vault version &> /dev/null; then
            local vault_ver=$(vault version | head -1)
            log_info "✓ Vault is already installed: $vault_ver"
            vault_installed=true
        else
            log_info "Vault binary found but not functional"
        fi
    else
        log_info "Vault not found in PATH"
    fi
    
    # Return status: 0 if all installed, 1 if none, 2 if partial
    if [[ "$nomad_installed" == true && "$consul_installed" == true && "$vault_installed" == true ]]; then
        return 0  # All installed
    elif [[ "$nomad_installed" == false && "$consul_installed" == false && "$vault_installed" == false ]]; then
        return 1  # None installed
    else
        return 2  # Partial installation
    fi
}

install_hashicorp_tools() {
    log_info "Checking HashiCorp tools installation status..."
    
    # Validate existing installations
    if validate_hashicorp_tools; then
        log_info "All HashiCorp tools are already installed and functional - skipping installation"
        return 0
    fi
    
    local validation_result=$?
    if [[ $validation_result -eq 2 ]]; then
        log_info "Partial installation detected - proceeding with full installation to ensure consistency"
    else
        log_info "HashiCorp tools not found - proceeding with installation"
    fi
    
    log_info "Installing Nomad, Consul, and Vault..."
    
    # Check if HashiCorp repository is already configured
    if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
        log_info "Adding HashiCorp repository..."
        # Add HashiCorp's official GPG key and repository
        wget -q -O - https://apt.releases.hashicorp.com/gpg | gpg --dearmor --batch --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/hashicorp.list
    else
        log_info "HashiCorp repository already configured"
    fi
    
    # Update and install
    apt-get update -y
    apt-get install -y nomad consul vault
    
    # Verify installations
    if nomad version &> /dev/null && consul version &> /dev/null && vault version &> /dev/null; then
        local nomad_ver=$(nomad version | head -1)
        local consul_ver=$(consul version | head -1)
        local vault_ver=$(vault version | head -1)
        log_info "✓ Installation successful:"
        log_info "  • $nomad_ver"
        log_info "  • $consul_ver"
        log_info "  • $vault_ver"
    else
        log_error "Installation verification failed - one or more tools are not working"
        return 1
    fi
    
    log_info "HashiCorp tools installation completed"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

start_services() {
    log_info "Starting services..."
    
    # Stop any existing services
    systemctl stop consul nomad 2>/dev/null || true
    
    # Reload systemd
    systemctl daemon-reload
    
    # Start and enable Consul first
    systemctl enable consul
    log_info "Starting Consul with timeout..."
    if timeout 30 systemctl start consul; then
        log_info "Consul start command completed"
    else
        log_warn "Warning: Consul start command timed out, checking status..."
    fi
    
    # Check Consul status
    if systemctl is-active --quiet consul; then
        log_info "✓ Consul service is active"
    else
        log_error "✗ Consul service failed to start"
        systemctl status consul --no-pager -l
        return 1
    fi
    
    # Wait for Consul to be ready
    log_info "Waiting for Consul to be ready..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -s http://127.0.0.1:8500/v1/status/leader >/dev/null 2>&1; then
            log_info "Consul is ready"
            break
        fi
        sleep 2
        ((attempts++))
    done
    
    # Start and enable Nomad
    systemctl enable nomad
    log_info "Starting Nomad with timeout..."
    if timeout 30 systemctl start nomad; then
        log_info "Nomad start command completed"
    else
        log_warn "Warning: Nomad start command timed out, checking status..."
    fi
    
    # Check Nomad status
    if systemctl is-active --quiet nomad; then
        log_info "✓ Nomad service is active"
    else
        log_error "✗ Nomad service failed to start"
        systemctl status nomad --no-pager -l
        return 1
    fi
    
    # Wait for Nomad to be ready
    log_info "Waiting for Nomad to be ready..."
    attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -s http://127.0.0.1:4646/v1/status/leader >/dev/null 2>&1; then
            log_info "Nomad is ready"
            break
        fi
        sleep 2
        ((attempts++))
    done
    
    log_info "Services started successfully"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_installation() {
    log_info "Validating installation..."
    
    local errors=0
    
    # Check service status
    for service in consul nomad docker dnsmasq; do
        if systemctl is-active --quiet $service; then
            log_info "✓ $service is running"
        else
            log_error "✗ $service is not running"
            ((errors++))
        fi
    done
    
    # Check Netmaker connectivity
    if [[ -n "${NETMAKER_IP:-}" ]]; then
        if ping -c 1 -W 3 "$NETMAKER_IP" >/dev/null 2>&1; then
            log_info "✓ Netmaker network connectivity ($NETMAKER_IP)"
        else
            log_error "✗ Netmaker network connectivity failed"
            ((errors++))
        fi
    fi
    
    # Check API endpoints
    if curl -s "http://127.0.0.1:8500/v1/status/leader" >/dev/null 2>&1; then
        log_info "✓ Consul API is responding"
    else
        log_error "✗ Consul API is not responding"
        ((errors++))
    fi
    
    if curl -s "http://127.0.0.1:4646/v1/status/leader" >/dev/null 2>&1; then
        log_info "✓ Nomad API is responding"
    else
        log_error "✗ Nomad API is not responding"
        ((errors++))
    fi
    
    # Check Docker
    if docker info >/dev/null 2>&1; then
        log_info "✓ Docker is functional"
    else
        log_error "✗ Docker is not functional"
        ((errors++))
    fi
    
    # Check DNS resolution
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        log_info "✓ DNS resolution is working"
    else
        log_error "✗ DNS resolution failed"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        log_info "✓ All validations passed!"
        return 0
    else
        log_error "✗ Validation failed with $errors errors"
        return 1
    fi
}
