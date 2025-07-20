# Stack Weaver: Cluster.sh In# 🚀 Cluster Forge

**Modern Nomad/Consul/Netmaker cluster setup and management tool**

[![Build Status](https://github.com/Bareuptime/stack-weaver/workflows/Build%20Release/badge.svg)](https://github.com/Bareuptime/stack-weaver/actions)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Cluster Forge is a comprehensive bash-based tool for setting up and managing Nomad/Consul clusters with Netmaker networking. It features a modern modular architecture with automated bundling and CI/CD capabilities.

## 📋 Table of Contents

- [Quick Start](#-quick-start)
- [Installation Methods](#-installation-methods)
- [Building from Source](#-building-from-source)
- [Usage](#-usage)
- [Environment Variables](#-environment-variables)
- [Examples](#-examples)
- [Development](#-development)
- [CI/CD & Releases](#-cicd--releases)
- [Architecture](#-architecture)
- [Troubleshooting](#-troubleshooting)

## 🚀 Quick Start

### Download Pre-built Binary

```bash
# Download the latest release for your platform
wget https://github.com/Bareuptime/stack-weaver/releases/latest/download/cluster-forge-ubuntu-22.04
chmod +x cluster-forge-ubuntu-22.04

# Validate configuration
NETMAKER_TOKEN="your-token" NOMAD_SERVER_IP="10.0.1.10" 
CONSUL_SERVER_IP="10.0.1.10" CONSUL_AGENT_TOKEN="your-token" 
VAULT_ADDR="https://vault:8200" VAULT_TOKEN="your-token" 
./cluster-forge-ubuntu-22.04 --validate-only

# Deploy cluster
sudo NETMAKER_TOKEN="your-token" NOMAD_SERVER_IP="10.0.1.10" 
CONSUL_SERVER_IP="10.0.1.10" CONSUL_AGENT_TOKEN="your-token" 
VAULT_ADDR="https://vault:8200" VAULT_TOKEN="your-token" 
./cluster-forge-ubuntu-22.04
```

### One-liner Installation

```bash
# Server node
curl -fsSL https://raw.githubusercontent.com/Bareuptime/stack-weaver/main/install.sh | 
  sudo NETMAKER_TOKEN="your-token" ROLE=server NOMAD_SERVER_IP="10.0.1.10" 
  CONSUL_SERVER_IP="10.0.1.10" CONSUL_AGENT_TOKEN="your-token" 
  VAULT_ADDR="https://vault:8200" VAULT_TOKEN="your-token" bash

# Client node  
curl -fsSL https://raw.githubusercontent.com/Bareuptime/stack-weaver/main/install.sh | 
  sudo NETMAKER_TOKEN="your-token" ROLE=client NOMAD_SERVER_IP="10.0.1.10" 
  CONSUL_SERVER_IP="10.0.1.10" CONSUL_AGENT_TOKEN="your-token" 
  VAULT_ADDR="https://vault:8200" VAULT_TOKEN="your-token" bash
```

## 📦 Installation Methods

### Method 1: Pre-built Binaries (Recommended)

Download platform-specific binaries from the [releases page](https://github.com/Bareuptime/stack-weaver/releases):

| Platform | Download |
|----------|----------|
| Ubuntu 20.04 | [cluster-forge-ubuntu-20.04](https://github.com/Bareuptime/stack-weaver/releases/latest/download/cluster-forge-ubuntu-20.04) |
| Ubuntu 22.04 | [cluster-forge-ubuntu-22.04](https://github.com/Bareuptime/stack-weaver/releases/latest/download/cluster-forge-ubuntu-22.04) |
| Debian 11 | [cluster-forge-debian-11](https://github.com/Bareuptime/stack-weaver/releases/latest/download/cluster-forge-debian-11) |
| Debian 12 | [cluster-forge-debian-12](https://github.com/Bareuptime/stack-weaver/releases/latest/download/cluster-forge-debian-12) |

```bash
# Example for Ubuntu 22.04
wget https://github.com/Bareuptime/stack-weaver/releases/latest/download/cluster-forge-ubuntu-22.04
chmod +x cluster-forge-ubuntu-22.04
sudo mv cluster-forge-ubuntu-22.04 /usr/local/bin/cluster-forge
```

### Method 2: Build from Source

```bash
# Clone the repository
git clone https://github.com/Bareuptime/stack-weaver.git
cd stack-weaver

# Build using the bundler
./bin/bundler.sh --output cluster-forge-custom --validate

# Install globally (optional)
sudo mv cluster-forge-custom /usr/local/bin/cluster-forge
```

### Method 3: Direct Repository Usage

```bash
# Clone and use modular scripts directly
git clone https://github.com/Bareuptime/stack-weaver.git
cd stack-weaver

# Make scripts executable
chmod +x bin/*.sh

# Use the modern interface
./bin/cluster-forge.sh --help

# Or use legacy interface for backward compatibility
./bin/main.sh
```

## 🔨 Building from Source

### Prerequisites

- Bash 4.0+
- Basic Unix tools (sed, grep, chmod)
- ShellCheck (optional, for validation)

### Build Process

```bash
# 1. Clone the repository
git clone https://github.com/Bareuptime/stack-weaver.git
cd stack-weaver

# 2. Make scripts executable
chmod +x bin/*.sh scripts/*.sh

# 3. Create a bundle
./bin/bundler.sh --output my-cluster-forge

# 4. Validate the bundle (optional)
./bin/bundler.sh --output my-cluster-forge --validate

# 5. Test the bundle
./my-cluster-forge --help
```

### Build Options

```bash
# Default bundle
./bin/bundler.sh

# Custom output name
./bin/bundler.sh --output production-cluster-forge

# With validation
./bin/bundler.sh --output cluster-forge --validate

# View bundler help
./bin/bundler.sh --help
```

## 📖 Usage

### Command Line Interface

```bash
cluster-forge [OPTIONS]

OPTIONS:
    -h, --help          Show help message with examples
    -v, --version       Show version information  
    --validate-only     Only validate environment variables
    --dry-run          Show what would be done without making changes

EXAMPLES:
    # Show detailed help
    cluster-forge --help
    
    # Validate configuration
    cluster-forge --validate-only
    
    # Preview actions without execution
    cluster-forge --dry-run
    
    # Full deployment
    sudo cluster-forge
```

### Backward Compatibility

The legacy interface is still available for existing deployments:

```bash
# Legacy main.sh interface
./bin/main.sh

# Legacy environment variable approach
export NETMAKER_TOKEN="your-token"
export ROLE=server
./bin/main.sh
```

## 🔧 Environment Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `NETMAKER_TOKEN` | Netmaker enrollment token | `nm-abc123def456` |
| `NOMAD_SERVER_IP` | Nomad server IP address | `10.0.1.10` |
| `CONSUL_SERVER_IP` | Consul server IP address | `10.0.1.10` |
| `CONSUL_AGENT_TOKEN` | Consul agent authentication token | `consul-token-123` |
| `VAULT_ADDR` | Vault server address | `https://vault.example.com:8200` |
| `VAULT_TOKEN` | Vault authentication token | `vault-token-456` |

### Optional Variables

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `ROLE` | Node role | `client` | `server` or `client` |
| `NODE_NAME` | Custom node name | `$(hostname)` | `web-server-01` |
| `DATACENTER` | Datacenter name | `dc1` | `us-west-1` |
| `ENCRYPT_KEY` | Consul encryption key | `auto-generated` | `base64-key` |
| `STATIC_PORT` | Netmaker static port | `51821` | `51822` |

### Setting Environment Variables

```bash
# Method 1: Export before running
export NETMAKER_TOKEN="your-token"
export NOMAD_SERVER_IP="10.0.1.10"
# ... other variables
sudo -E cluster-forge

# Method 2: Inline with command
sudo NETMAKER_TOKEN="token" NOMAD_SERVER_IP="10.0.1.10" cluster-forge

# Method 3: Using environment file
cat > cluster.env << EOF
NETMAKER_TOKEN=your-token
NOMAD_SERVER_IP=10.0.1.10
CONSUL_SERVER_IP=10.0.1.10
CONSUL_AGENT_TOKEN=your-consul-token
VAULT_ADDR=https://vault:8200
VAULT_TOKEN=your-vault-token
ROLE=server
EOF

# Load and run
set -a; source cluster.env; set +a
sudo -E cluster-forge
```

## 💡 Examples

### Server Node Setup

```bash
# Complete server setup
sudo NETMAKER_TOKEN="nm-abc123" 
     ROLE="server" 
     NOMAD_SERVER_IP="10.0.1.10" 
     CONSUL_SERVER_IP="10.0.1.10" 
     CONSUL_AGENT_TOKEN="consul-123" 
     VAULT_ADDR="https://vault.internal:8200" 
     VAULT_TOKEN="vault-456" 
     NODE_NAME="cluster-server-01" 
     DATACENTER="production" 
     cluster-forge
```

### Client Node Setup

```bash
# Client node joining existing cluster
sudo NETMAKER_TOKEN="nm-abc123" 
     ROLE="client" 
     NOMAD_SERVER_IP="10.0.1.10" 
     CONSUL_SERVER_IP="10.0.1.10" 
     CONSUL_AGENT_TOKEN="consul-123" 
     VAULT_ADDR="https://vault.internal:8200" 
     VAULT_TOKEN="vault-456" 
     NODE_NAME="worker-node-01" 
     cluster-forge
```

### Configuration Validation

```bash
# Validate before deployment
NETMAKER_TOKEN="nm-abc123" 
NOMAD_SERVER_IP="10.0.1.10" 
CONSUL_SERVER_IP="10.0.1.10" 
CONSUL_AGENT_TOKEN="consul-123" 
VAULT_ADDR="https://vault.internal:8200" 
VAULT_TOKEN="vault-456" 
cluster-forge --validate-only
```

### Dry Run Preview

```bash
# See what would be executed
sudo NETMAKER_TOKEN="nm-abc123" 
     NOMAD_SERVER_IP="10.0.1.10" 
     CONSUL_SERVER_IP="10.0.1.10" 
     CONSUL_AGENT_TOKEN="consul-123" 
     VAULT_ADDR="https://vault.internal:8200" 
     VAULT_TOKEN="vault-456" 
     cluster-forge --dry-run
```

## 🛠️ Development

### Project Structure

```
cluster-forge/
├── bin/
│   ├── cluster-forge.sh          # Modern CLI interface
│   ├── main.sh                  # Legacy interface
│   ├── bundler.sh               # Bundle creation tool
│   ├── setup_service_mesh.sh    # Service mesh setup
│   └── configure_client_service_mesh.sh  # Client configuration
├── lib/
│   ├── logging.sh               # Logging functions
│   └── system_core.sh           # Core system functions
├── scripts/
│   └── release.sh               # Release automation
├── .github/workflows/
│   └── build-release.yml        # CI/CD pipeline
├── docs/                        # Documentation
└── test/                        # Test scripts
```

### Local Development

```bash
# Clone and setup
git clone https://github.com/Bareuptime/stack-weaver.git
cd stack-weaver

# Make scripts executable
find . -name "*.sh" -exec chmod +x {} \;

# Test the modern interface
./bin/cluster-forge.sh --help

# Test bundling
./bin/bundler.sh --output test-bundle --validate

# Run validation
./test-bundle --validate-only
```

### Adding New Features

1. **Modify Core Functions**: Edit `lib/system_core.sh`
2. **Update CLI Interface**: Modify `bin/cluster-forge.sh`
3. **Test Changes**: Use `--validate-only` and `--dry-run`
4. **Create Bundle**: Run `./bin/bundler.sh --validate`
5. **Test Bundle**: Validate the generated bundle

### Code Style

- Follow existing bash coding patterns
- Use `set -euo pipefail` for error handling
- Document functions with comments
- Use meaningful variable names
- Test with ShellCheck when available

## 🔄 CI/CD & Releases

### Automated Builds

The project uses GitHub Actions for automated building and releasing:

- **Triggers**: Git tags, manual workflow dispatch
- **Platforms**: Ubuntu 20.04/22.04, Debian 11/12
- **Testing**: Docker-based validation
- **Artifacts**: Platform-specific binaries

### Creating Releases

```bash
# Method 1: Using the release helper
./scripts/release.sh -v v1.2.0 -m "Your Name"

# Method 2: Manual git tag
git tag v1.2.0
git push origin v1.2.0

# Method 3: GitHub web interface
# Create release through GitHub UI
```

### Release Helper Script

```bash
# Show help
./scripts/release.sh --help

# Create standard release
./scripts/release.sh -v v1.0.0 -m "Release Manager"

# Create pre-release
./scripts/release.sh -v v1.0.0-beta1 --prerelease

# Just create tag (no GitHub release)
./scripts/release.sh -v v1.0.0 --tag-only

# Dry run to preview
./scripts/release.sh -v v1.0.0 --dry-run
```

### Workflow Environment Variables

For automated releases, configure these GitHub secrets:

- `GITHUB_TOKEN`: Automatically provided
- Custom variables can be set in repository settings

## 🏗️ Architecture

### Modular Design

Cluster Forge uses a modular architecture that separates concerns:

- **CLI Interface** (`cluster-forge.sh`): User interaction and argument parsing
- **Core Functions** (`system_core.sh`): System setup and configuration
- **Service Mesh** (`setup_service_mesh.sh`): Nomad/Consul setup
- **Client Config** (`configure_client_service_mesh.sh`): Client-specific setup
- **Logging** (`logging.sh`): Centralized logging functions

### Bundle System

The bundler combines all modules into a single executable:

1. **Function Extraction**: Intelligent parsing to include only necessary code
2. **Dependency Resolution**: Ensures proper function ordering
3. **Validation**: Syntax checking and optional linting
4. **Optimization**: Removes comments and unnecessary code

### Backward Compatibility

- Legacy `main.sh` interface preserved
- All environment variables maintained
- Function signatures unchanged
- Migration path available

## 🚨 Troubleshooting

### Common Issues

#### Bundle Creation Fails
```bash
# Check file permissions
ls -la bin/*.sh lib/*.sh

# Validate source files
bash -n bin/cluster-forge.sh
bash -n lib/system_core.sh

# Use verbose bundling
./bin/bundler.sh --output debug-bundle --validate
```

#### Environment Variable Issues
```bash
# Validate configuration first
cluster-forge --validate-only

# Check for missing variables
env | grep -E "NETMAKER|NOMAD|CONSUL|VAULT"

# Use dry-run to see what would execute
cluster-forge --dry-run
```

#### Permission Errors
```bash
# Ensure bundle is executable
chmod +x cluster-forge-bundled.sh

# Check if running with sudo when needed
sudo cluster-forge --validate-only
```

#### GitHub Actions Issues
```bash
# Check workflow status
# View logs in GitHub Actions tab
# Verify secrets are set correctly
# Check workflow file syntax
```

### Getting Help

1. **Check Documentation**: Review this README and docs/ folder
2. **Validate Configuration**: Always run `--validate-only` first
3. **Use Dry Run**: Preview actions with `--dry-run`
4. **Check Logs**: Review output for error messages
5. **File Issues**: Create GitHub issues with error details

### Debug Mode

```bash
# Enable bash debug mode
bash -x cluster-forge --validate-only

# Check bundled script
bash -x cluster-forge-bundled.sh --help
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/Bareuptime/stack-weaver/issues)
- **Discussions**: [GitHub Discussions](https://github.com/Bareuptime/stack-weaver/discussions)
- **Documentation**: [docs/](docs/) foldern Guide

This repository contains the `clustrize.sh` script for easy cluster setup and management.

## Download and Install

To download and install `clustrize.sh` on your system, run the following command in your terminal:

### Server Node Setup

**One-liner:**

```bash
export NETMAKER_TOKEN="<token>"
export ROLE=client
export NOMAD_SERVER_IP="<ip>"
export CONSUL_SERVER_IP="<ip>"
wget -O clustrize.sh "https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s)" && sudo chmod +x clustrize.sh && sudo -E ./clustrize.sh
```



```bash
sudo NETMAKER_TOKEN=<your-token> ROLE=server NOMAD_SERVER_IP=<server-ip> CONSUL_SERVER_IP=<consul-server-ip> bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s))"
```


**Multi-line (clearer input format):**

```bash
export NETMAKER_TOKEN=<your-token>
export ROLE=server
export NOMAD_SERVER_IP=<server-ip>
export CONSUL_SERVER_IP=<consul-server-ip>
wget -O clustrize.sh "https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s)" && sudo chmod +x clustrize.sh && sudo -E ./clustrize.sh

# sudo -E bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/main/clustrize.sh?$(date +%s))"
```

### Client Node Setup

**One-liner:**

```bash
sudo NETMAKER_TOKEN=<your-token> ROLE=client NOMAD_SERVER_IP=<server-ip> CONSUL_SERVER_IP=<consul-server-ip> bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s))"
```

**Multi-line (clearer input format):**

```bash
export NETMAKER_TOKEN=<your-token>
export ROLE=client
export NOMAD_SERVER_IP=<server-ip>
export CONSUL_SERVER_IP=<consul-server-ip>
wget -O clustrize.sh "https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s)" && sudo chmod +x clustrize.sh && sudo -E ./clustrize.sh

# sudo -E bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s))"
```

### Required Environment Variables

- `NETMAKER_TOKEN`: Your Netmaker enrollment token (mandatory)
- `ROLE`: Either `server` or `client`
- `NOMAD_SERVER_IP`: IP address of the server node
- `CONSUL_SERVER_IP`: IP address of the Consul server node

### Optional Environment Variables

- `NODE_NAME`: Custom node name (defaults to hostname)
- `DATACENTER`: Datacenter name (defaults to dc1)
- `ENCRYPT_KEY`: Consul encryption key (auto-generated if empty)
- `NETMAKER_ENDPOINT`: Netmaker server endpoint (auto-detected if empty)
- `STATIC_PORT`: Netmaker static port (defaults to 51821)

