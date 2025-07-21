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
    
    log_success "System preparation completed"
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
    log_success "✓ Netclient is already installed and working"
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
    
    log_success "Netclient installed successfully"
}

join_netmaker_network() {
    log_info "Joining Netmaker network..."
    
    # Get the main bridge IP (usually the default route interface)
    local endpoint_ip=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' | head -1)
    log_info "Detected endpoint IP: $endpoint_ip"

    export DNS_MODE="off"
    log_info "Setting DNS mode to 'off' for Netmaker client"
    # Join the network with static port
    netclient join -t "$NETMAKER_TOKEN" \
        --static-port -p "$STATIC_PORT" \
        -s true \
        --endpoint-ip "$endpoint_ip"
    
    # Wait for network interface to be ready
    log_info "Waiting for Netmaker interface to be ready..."
    local attempts=0
    local netmaker_ip=""
    local netmaker_interface=""
    
    set +e
    while [[ $attempts -lt 90 ]]; do
        log_info "Waiting for Netmaker interface... attempt $((attempts + 1))/90"

        # First, find the netmaker interface (usually starts with nm-)
        ip link show
        netmaker_interface=$(ip link show 2>/dev/null | grep -oE "(nm-[^:]*|netmaker[^:]*)" 2>/dev/null | head -1 || true)
        log_info "Checking for Netmaker interface: $netmaker_interface"

        
        if [[ -n "$netmaker_interface" ]]; then
            log_info "Found Netmaker interface: $netmaker_interface"
            # Now get the IP from that specific interface
            netmaker_ip=$(ip addr show "$netmaker_interface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1 || echo "")
            
            if [[ -n "$netmaker_ip" ]]; then
                log_info "Netmaker interface ready with IP: $netmaker_ip"
                set -e
                break
            else
                log_info "Interface $netmaker_interface found but no IP assigned yet"
            fi
        else
            log_info "No Netmaker interface found yet (looking for nm-* or netmaker*)"
        fi
        
        sleep 3
        ((attempts++))
    done
    
    if [[ -z "$netmaker_ip" ]]; then
        log_error "Failed to detect Netmaker interface IP after 60 seconds"
        log_info "Available network interfaces:"
        ip link show
        ip link show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | sed 's/:$//'
        log_info "Checking for ip addr:"
        ip addr show
        log_info "Checking for any WireGuard interfaces:"
        ip link show type wireguard 2>/dev/null || log_info "  No WireGuard interfaces found"
        exit 1
    fi
    
    # Export for use in other functions
    export NETMAKER_IP="$netmaker_ip"
    
    log_success "Successfully joined Netmaker network with IP: $netmaker_ip"
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
    
    log_success "DNS will be handled entirely by dnsmasq"
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

    log_info "Disabling systemd-resolved to avoid conflicts..."
    disable_systemd_resolved
    log_success "systemd-resolved disabled"

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
        log_success "✓ DNS resolution test passed"
    else
        log_warn "⚠ Warning: DNS resolution test failed"
    fi
    
    log_success "DNS services reloaded"
}

# =============================================================================
# FIREWALL CONFIGURATION
# =============================================================================

configure_firewall() {
    log_info "Configuring firewall..."
    log_info "Opening required ports for HashiCorp stack and network communication..."
    
    # Ensure UFW is installed
    if ! command -v ufw &> /dev/null; then
        log_info "UFW not found, installing it..."
        apt-get update -y
        apt-get install -y ufw
        log_info "UFW installed successfully"
    else
        log_info "UFW is already available"
    fi
    
    # Reset UFW
    log_info "Resetting UFW to default state..."
    ufw --force reset
    
    # Default policies
    log_info "Setting default policies: DENY incoming, ALLOW outgoing"
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH
    log_info "Opening port 22/tcp for SSH access (remote administration)"
    ufw allow 22/tcp
    
    # Netmaker/WireGuard
    log_info "Opening port $STATIC_PORT/udp for Netmaker WireGuard VPN (secure mesh networking)"
    ufw allow "$STATIC_PORT"/udp comment "Netmaker WireGuard"
    
    # Get WireGuard network CIDR for security restrictions
    local netmaker_interface=$(ip link show | grep -o -E "(nm-[^:]*|netmaker)" | head -1)
    local wireguard_cidr=""
    
    if [[ -n "$netmaker_interface" ]]; then
        # Extract network CIDR from WireGuard interface
        wireguard_cidr=$(ip route show dev "$netmaker_interface" | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -1)
        log_info "Detected WireGuard network: $wireguard_cidr"
    fi
    
    if [[ -z "$wireguard_cidr" ]]; then
        log_error "Could not detect WireGuard network CIDR. HashiCorp ports will be restricted to localhost only for security."
        # wireguard_cidr="127.0.0.1"
        return 1
    fi

    # Nomad ports - RESTRICTED to WireGuard network + localhost for API access
    log_info "Opening Nomad cluster ports (restricted to WireGuard network + localhost):"
    log_info "  • 4646/tcp - Nomad HTTPS API (web UI and client communication)"
    ufw allow from "$wireguard_cidr" to any port 4646 proto tcp comment "Nomad HTTPS API"
    ufw allow from 127.0.0.1 to any port 4646 proto tcp comment "Nomad HTTPS API localhost"
    log_info "  • 4647/tcp - Nomad RPC (internal server communication)"
    ufw allow from "$wireguard_cidr" to any port 4647 proto tcp comment "Nomad RPC"
    log_info "  • 4648/tcp - Nomad Serf WAN (cross-datacenter clustering)"
    ufw allow from "$wireguard_cidr" to any port 4648 proto tcp comment "Nomad Serf WAN"
    
    # Consul ports - RESTRICTED to WireGuard network only
    log_info "Opening Consul cluster ports (restricted to WireGuard network):"
    log_info "  • 8300/tcp - Consul Server RPC (server-to-server communication)"
    ufw allow from "$wireguard_cidr" to any port 8300 proto tcp comment "Consul Server RPC"
    log_info "  • 8301/tcp - Consul Serf LAN TCP (local cluster membership)"
    ufw allow from "$wireguard_cidr" to any port 8301 proto tcp comment "Consul Serf LAN TCP"
    log_info "  • 8301/udp - Consul Serf LAN UDP (local cluster membership)"
    ufw allow from "$wireguard_cidr" to any port 8301 proto udp comment "Consul Serf LAN UDP"
    log_info "  • 8302/tcp - Consul Serf WAN TCP (cross-datacenter communication)"
    ufw allow from "$wireguard_cidr" to any port 8302 proto tcp comment "Consul Serf WAN TCP"
    log_info "  • 8302/udp - Consul Serf WAN UDP (cross-datacenter communication)"
    ufw allow from "$wireguard_cidr" to any port 8302 proto udp comment "Consul Serf WAN UDP"
    log_info "  • 8500/tcp - Consul HTTP API (web UI and service discovery)"
    ufw allow from "$wireguard_cidr" to any port 8500 proto tcp comment "Consul HTTP API"
    log_info "  • 8600/tcp - Consul DNS TCP (service name resolution)"
    ufw allow from "$wireguard_cidr" to any port 8600 proto tcp comment "Consul DNS TCP"
    log_info "  • 8600/udp - Consul DNS UDP (service name resolution)"
    ufw allow from "$wireguard_cidr" to any port 8600 proto udp comment "Consul DNS UDP"
    
    # DNS
    log_info "Opening DNS ports for dnsmasq service:"
    log_info "  • 53/tcp - DNS TCP queries (zone transfers and large responses)"
    ufw allow 53/tcp    # DNS TCP
    log_info "  • 53/udp - DNS UDP queries (standard DNS resolution)"
    ufw allow 53/udp    # DNS UDP
    
    # Enable firewall
    log_info "Enabling UFW firewall with configured rules..."
    ufw --force enable
    
    log_success "Firewall configuration completed successfully"
    log_info "🔒 SECURITY: HashiCorp ports are RESTRICTED to WireGuard network only"
    log_info "Summary of opened ports:"
    log_info "  SSH: 22/tcp (PUBLIC - for remote administration)"
    log_info "  Netmaker VPN: $STATIC_PORT/udp (PUBLIC - for WireGuard connections)"
    log_info "  Nomad: 4646-4648/tcp (RESTRICTED to $wireguard_cidr + localhost for API)"
    log_info "  Consul: 8300-8302/tcp+udp, 8500/tcp, 8600/tcp+udp (RESTRICTED to $wireguard_cidr)"
    log_info "  DNS: 53/tcp+udp (PUBLIC - for DNS resolution)"
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
    log_info "Validating existing Nomad, Consul, Vault, and Terraform installations..."
    
    local nomad_installed=false
    local consul_installed=false
    local vault_installed=false
    local terraform_installed=false
    
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
    
    # Check if Terraform is installed and functional
    if command -v terraform &> /dev/null; then
        if terraform version &> /dev/null; then
            local terraform_ver=$(terraform version | head -1)
            log_info "✓ Terraform is already installed: $terraform_ver"
            terraform_installed=true
        else
            log_info "Terraform binary found but not functional"
        fi
    else
        log_info "Terraform not found in PATH"
    fi
    
    # Return status: 0 if all installed, 1 if none, 2 if partial
    if [[ "$nomad_installed" == true && "$consul_installed" == true && "$vault_installed" == true && "$terraform_installed" == true ]]; then
        return 0  # All installed
    elif [[ "$nomad_installed" == false && "$consul_installed" == false && "$vault_installed" == false && "$terraform_installed" == false ]]; then
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
    
    log_info "Installing Nomad, Consul, Vault, and Terraform..."
    
    # Check if HashiCorp repository is already configured
    if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
        log_info "Adding HashiCorp repository..."
        
        # Ensure required packages are installed
        apt-get update -y
        apt-get install -y gpg wget lsb-release
        
        # Clean up any existing incomplete keys
        rm -f /usr/share/keyrings/hashicorp-archive-keyring.gpg
        
        # Create keyrings directory if it doesn't exist
        mkdir -p /usr/share/keyrings
        
        # Download and add HashiCorp's official GPG key using the official method
        log_info "Downloading HashiCorp GPG key using official method..."
        if ! wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; then
            log_error "Failed to download and import HashiCorp GPG key"
            return 1
        fi
        
        # Verify the key's fingerprint (optional but recommended)
        local key_fingerprint=$(gpg --no-default-keyring --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg --fingerprint 2>/dev/null | grep -o "798A EC65 4E5C 1542 8C8E 42EE AA16 FCBC A621 E701" || echo "")
        if [[ -n "$key_fingerprint" ]]; then
            log_info "✓ HashiCorp GPG key fingerprint verified: $key_fingerprint"
        else
            log_warn "⚠ Warning: Could not verify GPG key fingerprint, but proceeding..."
        fi
        
        # Detect OS and appropriate codename for repository configuration
        . /etc/os-release
        local os_id="$ID"
        local codename=""
        
        if [[ "$os_id" == "ubuntu" ]]; then
            # For Ubuntu, use UBUNTU_CODENAME if available, fallback to VERSION_CODENAME
            codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
            log_info "Detected Ubuntu, using codename: $codename"
        elif [[ "$os_id" == "debian" ]]; then
            # For Debian, use lsb_release or VERSION_CODENAME
            if command -v lsb_release &> /dev/null; then
                codename=$(lsb_release -cs)
            else
                codename="$VERSION_CODENAME"
            fi
            log_info "Detected Debian, using codename: $codename"
        else
            # Fallback for other distributions
            if command -v lsb_release &> /dev/null; then
                codename=$(lsb_release -cs)
            else
                codename="$VERSION_CODENAME"
            fi
            log_info "Detected $os_id, using codename: $codename"
        fi
        
        if [[ -z "$codename" ]]; then
            log_error "Could not determine OS codename for repository configuration"
            return 1
        fi
        
        # Add repository using the official format
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $codename main" | tee /etc/apt/sources.list.d/hashicorp.list
        
        log_info "HashiCorp repository added successfully for $os_id $codename"
    else
        log_info "HashiCorp repository already configured"
    fi
    
    # Update and install (including Terraform)
    log_info "Updating package lists..."
    apt-get update -y
    
    log_info "Installing HashiCorp tools: Nomad, Consul, Vault, and Terraform..."
    apt-get install -y nomad consul vault terraform
    
    # Verify installations
    if nomad version &> /dev/null && consul version &> /dev/null && vault version &> /dev/null && terraform version &> /dev/null; then
        local nomad_ver=$(nomad version | head -1)
        local consul_ver=$(consul version | head -1)
        local vault_ver=$(vault version | head -1)
        local terraform_ver=$(terraform version | head -1)
        log_success "✓ Installation successful:"
        log_info "  • $nomad_ver"
        log_info "  • $consul_ver"
        log_info "  • $vault_ver"
        log_info "  • $terraform_ver"
    else
        log_error "Installation verification failed - one or more tools are not working"
        return 1
    fi
    
    log_success "HashiCorp tools installation completed"
}

install_cni() {
    log_info "Installing CNI plugins for Nomad..."
    
    # Check if CNI is already installed
    if [[ -d "/opt/cni/bin" ]] && [[ -n "$(ls -A /opt/cni/bin 2>/dev/null)" ]]; then
        log_info "CNI plugins already installed, checking version..."
        if [[ -x "/opt/cni/bin/bridge" ]]; then
            local existing_version=$(/opt/cni/bin/bridge 2>&1 | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || echo "unknown")
            log_info "Existing CNI version: ${existing_version:-unknown}"
            log_success "CNI plugins already installed and functional"
            return 0
        fi
    fi
    
    # Detect system architecture
    local arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    local cni_arch=""
    
    case "$arch" in
        amd64|x86_64)
            cni_arch="amd64"
            ;;
        arm64|aarch64)
            cni_arch="arm64"
            ;;
        armhf|armv7l)
            cni_arch="arm"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
    
    log_info "Detected architecture: $arch -> CNI architecture: $cni_arch"
    
    # CNI version and download URL
    local cni_version="v1.7.1"
    local cni_url="https://github.com/containernetworking/plugins/releases/download/${cni_version}/cni-plugins-linux-${cni_arch}-${cni_version}.tgz"
    
    log_info "Downloading CNI plugins from: $cni_url"
    
    # Create CNI directory structure
    mkdir -p /opt/cni/bin
    
    # Download and install CNI plugins with error handling
    local temp_file="/tmp/cni-plugins.tgz"
    
    if ! wget -q -O "$temp_file" "$cni_url"; then
        log_error "Failed to download CNI plugins from $cni_url"
        rm -f "$temp_file"
        return 1
    fi
    
    # Verify download
    if [[ ! -f "$temp_file" ]] || [[ ! -s "$temp_file" ]]; then
        log_error "Downloaded CNI plugins file is empty or missing"
        rm -f "$temp_file"
        return 1
    fi
    
    # Extract plugins
    if ! tar xzf "$temp_file" -C /opt/cni/bin; then
        log_error "Failed to extract CNI plugins"
        rm -f "$temp_file"
        return 1
    fi
    
    # Clean up temporary file
    rm -f "$temp_file"
    
    # Set proper permissions
    chmod +x /opt/cni/bin/*
    
    # Verify installation
    local plugin_count=$(ls -1 /opt/cni/bin | wc -l)
    if [[ $plugin_count -lt 5 ]]; then
        log_error "CNI installation verification failed: only $plugin_count plugins found"
        return 1
    fi
    
    # Test a core plugin
    if [[ -x "/opt/cni/bin/bridge" ]]; then
        local installed_version=$(/opt/cni/bin/bridge 2>&1 | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || echo "unknown")
        log_info "Installed CNI version: ${installed_version:-unknown}"
    fi
    
    log_success "CNI plugins installed successfully ($plugin_count plugins)"
    log_info "CNI plugins location: /opt/cni/bin"
    log_info "Available plugins: $(ls /opt/cni/bin | tr '\n' ' ')"
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
    
    # Wait for Nomad to be ready (HTTPS only)
    log_info "Waiting for Nomad to be ready..."
    attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -sk https://127.0.0.1:4646/v1/status/leader >/dev/null 2>&1; then
            log_info "Nomad is ready (HTTPS)"
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
    
    # Check Nomad API (HTTPS only)
    if curl -sk "https://127.0.0.1:4646/v1/status/leader" >/dev/null 2>&1; then
        log_info "✓ Nomad API is responding (HTTPS)"
    else
        log_error "✗ Nomad API is not responding (HTTPS)"
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


diagnose_system() {
    echo "=== Consul Client Diagnostic ==="

    echo "1. Consul service status:"
    sudo systemctl status consul --no-pager

    echo -e "\n2. Consul configuration:"
    sudo cat /etc/consul.d/consul.hcl | grep -E "(retry_join|server|datacenter)"

    echo -e "\n3. Network connectivity to server:"
    ping -c 3 10.10.85.1

    echo -e "\n4. Consul server HTTP test:"
    curl -m 5 -k http://10.10.85.1:8500/v1/status/leader 2>/dev/null || echo "Connection failed"

    echo -e "\n5. Consul member status:"
    consul members 2>/dev/null || echo "Not connected to cluster"

    echo -e "\n6. Recent Consul logs:"
    sudo journalctl -u consul -n 10 --no-pager

    echo -e "\n7. DNS test to server IP:"
    dig @127.0.0.1 -p 8600 10.10.85.1

    echo "=== Diagnostic Complete ==="
}