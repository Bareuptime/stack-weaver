#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CLUSTER FORGE - Main Entry Point
# Nomad/Consul/Netmaker Cluster Setup Script
# =============================================================================

# If bundling, the bundler will inline the content here.
# If not bundling, make sure lib/logging.sh exists.
if [[ -z "${BUNDLED:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  source "$PROJECT_ROOT/lib/logging.sh"
  source "$PROJECT_ROOT/lib/system_core.sh"
fi

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

ROLE="${ROLE:-client}"                    # server or client
NOMAD_SERVER_IP="${NOMAD_SERVER_IP:-}"    # IP of the server node
CONSUL_SERVER_IP="${CONSUL_SERVER_IP:-}"  # IP of the server node
NODE_NAME="${NODE_NAME:-$(hostname)}"     # Node name
DATACENTER="${DATACENTER:-dc1}"           # Datacenter name
ENCRYPT_KEY="${ENCRYPT_KEY:-}"            # Consul encryption key (auto-generated if empty)
NETMAKER_TOKEN="${NETMAKER_TOKEN:-}"      # Netmaker enrollment token (mandatory)
STATIC_PORT="${STATIC_PORT:-51821}"       # Netmaker static port
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

# Guided installation settings
GUIDED_MODE="${GUIDED_MODE:-false}"           # Enable guided installation mode

# =============================================================================
# HELP AND USAGE
# =============================================================================

show_help() {
    cat << EOF
Cluster Forge - Nomad/Consul/Netmaker Cluster Setup Script

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    Sets up a Nomad/Consul cluster node with Netmaker networking.
    All configuration is done via environment variables.

REQUIRED ENVIRONMENT VARIABLES:
    NETMAKER_TOKEN        Netmaker enrollment token
    NOMAD_SERVER_IP       IP address of the Nomad server node
    CONSUL_SERVER_IP      IP address of the Consul server node
    VAULT_ADDR           Vault server address
    VAULT_TOKEN          Vault authentication token

OPTIONAL ENVIRONMENT VARIABLES:
    ROLE                 Node role: 'server' or 'client' (default: client)
    NODE_NAME           Node name (default: hostname)
    DATACENTER          Datacenter name (default: dc1)
    ENCRYPT_KEY         Consul encryption key (auto-generated if empty)
    STATIC_PORT         Netmaker static port (default: 51821)

OPTIONS:
    -h, --help          Show this help message
    -v, --version       Show version information
    --validate-only     Only validate environment variables, don't run setup
    --dry-run          Show what would be done without making changes
    --guided           Enable guided installation mode with step-by-step prompts

EXAMPLES:
    # Server node setup
    sudo NETMAKER_TOKEN="xyz123" ROLE=server NOMAD_SERVER_IP=10.0.1.10 \\
         CONSUL_SERVER_IP=10.0.1.10 \\
         VAULT_ADDR="https://vault.example.com:8200" VAULT_TOKEN="def456" \\
         $0

    # Client node setup
    sudo NETMAKER_TOKEN="xyz123" ROLE=client NOMAD_SERVER_IP=10.0.1.10 \\
         CONSUL_SERVER_IP=10.0.1.10 \\
         VAULT_ADDR="https://vault.example.com:8200" VAULT_TOKEN="def456" \\
         $0

    # Validate configuration only
    NETMAKER_TOKEN="xyz123" NOMAD_SERVER_IP=10.0.1.10 \\
    CONSUL_SERVER_IP=10.0.1.10 \\
    VAULT_ADDR="https://vault.example.com:8200" VAULT_TOKEN="def456" \\
    $0 --validate-only

    # Guided installation mode
    sudo $0 --guided

EOF
}

show_version() {
    echo "Cluster Forge v1.0.0"
    echo "Nomad/Consul/Netmaker cluster setup tool"
    echo "Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "Repository: https://github.com/Bareuptime/stack-weaver"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

VALIDATE_ONLY=false
DRY_RUN=false
GUIDED_MODE=false

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            --validate-only)
                VALIDATE_ONLY=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --guided)
                GUIDED_MODE=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_input() {
    local errors=0
    
    log_info "Validating configuration..."
    
    # Check if running as root (unless validate-only, dry-run, or guided mode)
    if [[ "$VALIDATE_ONLY" == false && "$DRY_RUN" == false && "$GUIDED_MODE" == false && $EUID -ne 0 ]]; then
        log_error "This script must be run as root for actual deployment"
        ((errors++))
    elif [[ "$GUIDED_MODE" == true && $EUID -ne 0 ]]; then
        log_warn "Guided mode: You are not running as root. Some steps may require sudo privileges."
    fi
    
    # Validate role
    if [[ "$ROLE" != "server" && "$ROLE" != "client" ]]; then
        log_error "ROLE must be 'server' or 'client', got: '$ROLE'"
        ((errors++))
    fi
    
    # Validate required IPs
    if [[ -z "$NOMAD_SERVER_IP" ]]; then
        log_error "NOMAD_SERVER_IP must be provided"
        ((errors++))
    elif ! [[ "$NOMAD_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "NOMAD_SERVER_IP must be a valid IP address, got: '$NOMAD_SERVER_IP'"
        ((errors++))
    fi

    if [[ -z "$CONSUL_SERVER_IP" ]]; then
        log_error "CONSUL_SERVER_IP must be provided"
        ((errors++))
    elif ! [[ "$CONSUL_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "CONSUL_SERVER_IP must be a valid IP address, got: '$CONSUL_SERVER_IP'"
        ((errors++))
    fi

    # Validate required tokens
    if [[ -z "$NETMAKER_TOKEN" ]]; then
        log_error "NETMAKER_TOKEN is mandatory. Please provide the Netmaker enrollment token."
        ((errors++))
    fi
    
    # Validate Vault configuration
    if [[ -z "$VAULT_ADDR" ]]; then
        log_error "VAULT_ADDR is mandatory. Please provide the Vault address."
        ((errors++))
    fi

    if [[ -z "$VAULT_TOKEN" ]]; then
        log_error "VAULT_TOKEN is mandatory. Please provide the Vault token."
        ((errors++))
    fi
    
    # Validate network ports
    if ! [[ "$STATIC_PORT" =~ ^[0-9]+$ ]] || [[ "$STATIC_PORT" -lt 1024 || "$STATIC_PORT" -gt 65535 ]]; then
        log_error "STATIC_PORT must be a valid port number between 1024-65535, got: '$STATIC_PORT'"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        log_info "✓ Configuration validation passed"
        log_info "  • Role: $ROLE"
        log_info "  • Node Name: $NODE_NAME"
        log_info "  • Datacenter: $DATACENTER"
        log_info "  • Nomad Server: $NOMAD_SERVER_IP"
        log_info "  • Consul Server: $CONSUL_SERVER_IP"
        log_info "  • Vault Address: $VAULT_ADDR"
        log_info "  • Static Port: $STATIC_PORT"
        return 0
    else
        log_error "Configuration validation failed with $errors errors"
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION FUNCTIONS
# =============================================================================

# Source additional modules when not bundled
source_modules() {
    if [[ -z "${BUNDLED:-}" ]]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        
        # Source setup functions
        if [[ -f "$script_dir/setup_service_mesh.sh" ]]; then
            source "$script_dir/setup_service_mesh.sh"
        else
            log_error "Required module not found: setup_service_mesh.sh"
            exit 1
        fi
    fi
}

# =============================================================================
# NETMAKER DETECTION FUNCTIONS
# =============================================================================

detect_netmaker_ip() {
    log_info "Attempting to detect existing Netmaker IP..."
    
    # Check if NETMAKER_IP is already set
    if [[ -n "${NETMAKER_IP:-}" ]]; then
        log_info "NETMAKER_IP already set to: $NETMAKER_IP"
        return 0
    fi
    
    # Check if netclient is installed and get netmaker interfaces
    local netmaker_interface=$(ip link show 2>/dev/null | grep -o -E "(nm-[^:]*|netmaker)" | head -1)
    if [[ -z "$netmaker_interface" ]]; then
        log_warn "No Netmaker interface found (no nm-* or netmaker interface)"
        log_warn "Unable to auto-detect Netmaker IP. You may need to set NETMAKER_IP manually."
        return 1
    fi
    
    # Get IP address from the interface
    local netmaker_ip=$(ip addr show "$netmaker_interface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    if [[ -z "$netmaker_ip" ]]; then
        log_warn "Netmaker interface $netmaker_interface has no IP address"
        log_warn "Unable to auto-detect Netmaker IP. You may need to set NETMAKER_IP manually."
        return 1
    fi
    
    # Test connectivity through the interface
    if ! ping -c 1 -W 3 "$netmaker_ip" >/dev/null 2>&1; then
        log_warn "Connectivity test failed for detected Netmaker IP: $netmaker_ip"
        log_warn "The interface exists but may not be fully functional."
    fi
    
    # Export the detected IP
    export NETMAKER_IP="$netmaker_ip"
    log_success "✓ Auto-detected Netmaker IP: $netmaker_ip"
    log_info "  • Interface: $netmaker_interface"
    
    return 0
}

# =============================================================================
# GUIDED INSTALLATION FUNCTIONS
# =============================================================================

prompt_user() {
    local step_name="$1"
    local step_description="$2"
    
    echo ""
    log_info "=========================================="
    log_info "Step: $step_name"
    log_info "Description: $step_description"
    log_info "=========================================="
    
    while true; do
        echo -n "Execute this step? [Y]es/[N]o/[Q]uit: "
        
        # Read a single character without requiring Enter
        read -n 1 -s choice
        echo "$choice"  # Echo the pressed key
        
        case $choice in
            [Yy]|"")
                echo
                return 0  # Execute
                ;;
            [Nn])
                echo
                log_info "Skipping: $step_name"
                return 1  # Skip
                ;;
            [Qq])
                echo
                log_info "Installation aborted by user."
                exit 0
                ;;
            *)
                echo
                echo "Please press Y for Yes, N for No, or Q for Quit."
                ;;
        esac
    done
}

execute_step() {
    local step_name="$1"
    local step_function="$2"
    local step_description="$3"
    
    if prompt_user "$step_name" "$step_description"; then
        log_info "Executing: $step_name"
        
        # Check if we need root privileges for this step
        local needs_root=false
        case "$step_function" in
            prepare_system|setup_netmaker|install_docker|disable_systemd_resolved|configure_dnsmasq|reload_dns_services|configure_firewall|install_hashicorp_tools|setup_service_mesh|start_services)
                needs_root=true
                ;;
        esac
        
        if [[ "$needs_root" == true && $EUID -ne 0 ]]; then
            log_warn "This step requires root privileges. You may be prompted for sudo."
        fi
        
        if $step_function; then
            log_info "✓ Completed: $step_name"
        else
            log_error "✗ Failed: $step_name"
            echo ""
            log_error "Possible reasons for failure:"
            log_error "  • Insufficient privileges (try running with sudo)"
            log_error "  • Network connectivity issues"
            log_error "  • Missing dependencies"
            log_error "  • Configuration errors"
            echo ""
            read -p "Continue anyway? [y/N]: " choice
            case $choice in
                [Yy]|[Yy][Ee][Ss])
                    log_info "Continuing despite failure..."
                    ;;
                *)
                    log_error "Installation aborted due to step failure."
                    exit 1
                    ;;
            esac
        fi
    else
        # Handle special case when setup_netmaker is skipped
        if [[ "$step_function" == "setup_netmaker" ]]; then
            log_info "Netmaker setup skipped - attempting to auto-detect existing Netmaker IP..."
            detect_netmaker_ip || true  # Don't fail if detection fails
        fi
    fi
}

guided_installation() {
    log_info "Starting Guided Installation Mode"
    log_info "You will be prompted for each step. You can choose to execute, skip, or quit."
    log_warn "If you trying for the first time, we recommend executing all steps."
    log_warn "You can also skip steps if you want to customize the installation later."
    log_info "Press Enter to continue..."
    read -r  # Wait for user input
    echo ""
    
    # Define installation steps with descriptions
    execute_step "System Preparation" "prepare_system" \
        "Update packages, create users, and prepare the system for installation"
    
    execute_step "Netmaker Setup" "setup_netmaker" \
        "Install and configure Netmaker client for network connectivity"
    
    execute_step "Docker Installation" "install_docker" \
        "Install Docker container runtime environment"
    
    execute_step "Disable systemd-resolved" "disable_systemd_resolved" \
        "Disable systemd-resolved to prevent DNS conflicts"
    
    execute_step "Configure dnsmasq" "configure_dnsmasq" \
        "Setup dnsmasq for local DNS resolution"
    
    execute_step "Reload DNS Services" "reload_dns_services" \
        "Restart and reload DNS services to apply changes"
    
    execute_step "Configure Firewall" "configure_firewall" \
        "Setup firewall rules for cluster communication"
    
    execute_step "Install HashiCorp Tools" "install_hashicorp_tools" \
        "Install Nomad, Consul, and Vault binaries"
    
    execute_step "Setup Service Mesh" "setup_service_mesh" \
        "Configure service mesh components and policies"
    
    execute_step "Start Services" "start_services" \
        "Start all cluster services (Consul, Nomad, etc.)"
    
    # Final validation
    echo ""
    log_info "=========================================="
    log_info "Installation Steps Complete"
    log_info "=========================================="
    log_info "Running final validation..."
    
    if validate_installation; then
        return 0
    else
        log_warn "Some validation checks failed. The installation may be incomplete."
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    log_info "Starting Cluster Forge - Nomad/Consul/Netmaker [$ROLE] setup..."
    log_info "Role: $ROLE"
    log_info "Nomad Server IP: $NOMAD_SERVER_IP"
    log_info "Node Name: $NODE_NAME"
    log_info "Netmaker Token: [REDACTED]"
    
    # Validate configuration
    if ! validate_input; then
        exit 1
    fi
    
    # If only validation requested, exit here
    if [[ "$VALIDATE_ONLY" == true ]]; then
        log_info "Validation completed successfully. Exiting."
        exit 0
    fi
    
    # Load additional modules
    source_modules
    
    # Show what would be done in dry-run mode
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN MODE - Would execute the following steps:"
        log_info "1. Prepare system (update packages, create users)"
        log_info "2. Setup Netmaker client"
        log_info "3. Install Docker"
        log_info "4. Configure DNS (disable systemd-resolved, setup dnsmasq)"
        log_info "5. Configure firewall"
        log_info "6. Install HashiCorp tools (Nomad, Consul, Vault)"
        log_info "7. Setup service mesh configuration"
        log_info "8. Configure client-specific settings"
        log_info "9. Start and validate services"
        log_info ""
        log_info "No actual changes would be made. Remove --dry-run to proceed."
        log_info "Use --guided for step-by-step interactive installation."
        exit 0
    fi
    
    # Execute the main setup process
    log_info "Beginning cluster setup process..."
    
    if [[ "$GUIDED_MODE" == true ]]; then
        # Run guided installation
        if guided_installation; then
            validation_passed=true
        else
            validation_passed=false
        fi
    else
        # Run automated installation
        # Core system setup (from main.sh functionality)
        prepare_system
        setup_netmaker
        install_docker
        disable_systemd_resolved
        configure_dnsmasq
        reload_dns_services
        configure_firewall
        install_hashicorp_tools
        
        # Service mesh setup (from setup_service_mesh.sh)
        setup_service_mesh
        
        # Start services and validate
        start_services
        
        if validate_installation; then
            validation_passed=true
        else
            validation_passed=false
        fi
    fi
    
    
    if [[ "$validation_passed" == true ]]; then
        local main_ip=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' | head -1)
        
        log_info "============================================"
        log_info "🎉 Cluster Forge completed successfully!"
        log_info "============================================"
        log_info "Main IP: $main_ip"
        log_info "Netmaker IP: ${NETMAKER_IP:-N/A}"
        log_info ""
        log_info "🌐 Web Interfaces:"
        log_info "  • Consul UI: http://${NETMAKER_IP:-$main_ip}:8500"
        log_info "  • Nomad UI: http://${NETMAKER_IP:-$main_ip}:4646"
        log_info ""
        log_info "📁 Configuration files:"
        log_info "  • Consul: /etc/consul.d/consul.hcl"
        log_info "  • Nomad: /etc/nomad.d/nomad.hcl"
        log_info "  • dnsmasq: /etc/dnsmasq.d/10-consul"
        log_info ""
        log_info "🔧 Useful commands:"
        log_info "  • Check status: systemctl status consul nomad dnsmasq"
        log_info "  • View logs: journalctl -f -u consul -u nomad"
        log_info "  • Consul members: consul members"
        log_info "  • Nomad nodes: nomad node status"
        log_info "  • Netmaker status: netclient list"
        log_info "============================================"
    else
        log_error "Cluster Forge setup failed. Check the logs above for details."
        exit 1
    fi
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
