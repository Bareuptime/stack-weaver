#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CLUSTER FORGE - Main Entry Point (Legacy Interface)
# Nomad/Consul/Netmaker Cluster Setup Script
# 
# This is the main entry point that maintains backward compatibility
# with the original interface while using the new modular system.
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
# BACKWARD COMPATIBILITY FUNCTIONS
# =============================================================================

# Legacy log function for backward compatibility
log() {
    log_info "$@"
}

# Legacy error function for backward compatibility  
error() {
    log_error "$@"
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
# SOURCE ADDITIONAL MODULES
# =============================================================================

source_modules() {
    if [[ -z "${BUNDLED:-}" ]]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        
        # Source setup functions
        if [[ -f "$script_dir/setup_service_mesh.sh" ]]; then
            source "$script_dir/setup_service_mesh.sh"
        else
            error "Required module not found: setup_service_mesh.sh"
        fi
        
        # Source client configuration functions
        if [[ -f "$script_dir/configure_client_service_mesh.sh" ]]; then
            source "$script_dir/configure_client_service_mesh.sh"
        else
            error "Required module not found: configure_client_service_mesh.sh"
        fi
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
    source_modules
    
    # Core system setup
    prepare_system
    setup_netmaker
    install_docker
    disable_systemd_resolved
    configure_dnsmasq
    reload_dns_services
    configure_firewall
    install_hashicorp_tools
    
    # Service mesh setup
    setup_service_mesh
    
    # Client-specific configuration 
    configure_client_service_mesh
    
    # Start services and validate
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