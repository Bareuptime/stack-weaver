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
CONSUL_AGENT_TOKEN="${CONSUL_AGENT_TOKEN:-}"  # Consul agent token (mandatory)
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

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
    CONSUL_AGENT_TOKEN    Consul agent token for authentication
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

EXAMPLES:
    # Server node setup
    sudo NETMAKER_TOKEN="xyz123" ROLE=server NOMAD_SERVER_IP=10.0.1.10 \\
         CONSUL_SERVER_IP=10.0.1.10 CONSUL_AGENT_TOKEN="abc123" \\
         VAULT_ADDR="https://vault.example.com:8200" VAULT_TOKEN="def456" \\
         $0

    # Client node setup
    sudo NETMAKER_TOKEN="xyz123" ROLE=client NOMAD_SERVER_IP=10.0.1.10 \\
         CONSUL_SERVER_IP=10.0.1.10 CONSUL_AGENT_TOKEN="abc123" \\
         VAULT_ADDR="https://vault.example.com:8200" VAULT_TOKEN="def456" \\
         $0

    # Validate configuration only
    NETMAKER_TOKEN="xyz123" NOMAD_SERVER_IP=10.0.1.10 \\
    CONSUL_SERVER_IP=10.0.1.10 CONSUL_AGENT_TOKEN="abc123" \\
    VAULT_ADDR="https://vault.example.com:8200" VAULT_TOKEN="def456" \\
    $0 --validate-only

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
    
    # Check if running as root (unless validate-only or dry-run)
    if [[ "$VALIDATE_ONLY" == false && "$DRY_RUN" == false && $EUID -ne 0 ]]; then
        log_error "This script must be run as root for actual deployment"
        ((errors++))
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

    if [[ -z "$CONSUL_AGENT_TOKEN" ]]; then
        log_error "CONSUL_AGENT_TOKEN is mandatory. Please provide the Consul agent token."
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
        
        # Source client configuration functions
        if [[ -f "$script_dir/configure_client_service_mesh.sh" ]]; then
            source "$script_dir/configure_client_service_mesh.sh"
        else
            log_error "Required module not found: configure_client_service_mesh.sh"
            exit 1
        fi
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    log_info "Starting Cluster Forge - Nomad/Consul/Netmaker setup..."
    log_info "Role: $ROLE"
    log_info "Server IP: $NOMAD_SERVER_IP"
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
        exit 0
    fi
    
    # Execute the main setup process
    log_info "Beginning cluster setup process..."
    
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
    
    # Client-specific configuration (from configure_client_service_mesh.sh)
    configure_client_service_mesh
    
    # Start services and validate
    start_services
    
    if validate_installation; then
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
