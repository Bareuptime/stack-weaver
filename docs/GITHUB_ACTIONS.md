# GitHub Actions Build & Release Workflow

This document explains how to use the automated GitHub Actions workflow to build and release Cluster Forge bundles.

## Overview

The workflow creates single-file executables compatible with AMD64 systems running:
- Ubuntu 20.04 (Focal)
- Ubuntu 22.04 (Jammy)  
- Debian 11 (Bullseye)
- Debian 12 (Bookworm)

## Setup

### Prerequisites

1. **Repository Setup**
   - Fork/clone the repository
   - Ensure you have write access to the repository
   - The workflow files are in `.github/workflows/`

2. **GitHub Token**
   - The workflow uses `secrets.GITHUB_TOKEN` by default
   - For advanced features, you may need a Personal Access Token (PAT)

### Workflow Triggers

The build workflow can be triggered in three ways:

1. **Automatic Tag Push** (Recommended)
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

2. **Manual Workflow Dispatch**
   - Go to GitHub Actions tab
   - Select "Build and Release Cluster Forge Bundle"
   - Click "Run workflow"
   - Fill in the required parameters

3. **Using the Release Helper Script**
   ```bash
   ./scripts/release.sh -v v1.0.0 -m "Your Name"
   ```

## Usage Examples

### 1. Simple Release Using Helper Script

```bash
# Create a new release
./scripts/release.sh -v v1.0.0 -m "Bareuptime"

# Create a pre-release
./scripts/release.sh -v v1.0.0-beta1 --prerelease

# Dry run to see what would happen
./scripts/release.sh -v v1.0.0 --dry-run
```

### 2. Manual Git Tag Release

```bash
# Create and push a tag
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0

# The workflow will trigger automatically
```

### 3. Manual Workflow Dispatch

Via GitHub web interface:
1. Navigate to **Actions** tab
2. Select **Build and Release Cluster Forge Bundle**
3. Click **Run workflow**
4. Fill in parameters:
   - **maintainer_name**: Your name or organization
   - **ghc_token**: Leave as default (`secrets.GITHUB_TOKEN`)
   - **release_tag**: Version tag (e.g., `v1.0.0`)
   - **prerelease**: Check if this is a pre-release

## Workflow Process

The automated workflow performs these steps:

### 1. Build Phase
- **Validation**: Runs ShellCheck on all shell scripts
- **Testing**: Tests the bundler functionality
- **Multi-OS Build**: Creates binaries for each supported OS
- **Integration Testing**: Tests binaries in Docker containers

### 2. Bundle Creation
For each OS target:
- Creates a bundled executable using `bin/bundler.sh`
- Adds metadata (version, build date, git commit)
- Generates SHA256 checksums
- Tests the bundle functionality

### 3. Release Phase
- Creates GitHub release with release notes
- Uploads all binaries and checksums
- Marks as pre-release if specified

## Output Artifacts

Each release produces:

```
cluster-forge-v1.0.0-linux-amd64-ubuntu-focal       # Ubuntu 20.04 binary
cluster-forge-v1.0.0-linux-amd64-ubuntu-focal.sha256   # Checksum
cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy       # Ubuntu 22.04 binary  
cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy.sha256   # Checksum
cluster-forge-v1.0.0-linux-amd64-debian-bullseye    # Debian 11 binary
cluster-forge-v1.0.0-linux-amd64-debian-bullseye.sha256 # Checksum
cluster-forge-v1.0.0-linux-amd64-debian-bookworm    # Debian 12 binary
cluster-forge-v1.0.0-linux-amd64-debian-bookworm.sha256 # Checksum
```

## Using Released Binaries

### Download and Verify

```bash
# Download the appropriate binary for your system
wget https://github.com/Bareuptime/stack-weaver/releases/download/v1.0.0/cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy

# Download the checksum
wget https://github.com/Bareuptime/stack-weaver/releases/download/v1.0.0/cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy.sha256

# Verify integrity
sha256sum -c cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy.sha256

# Make executable
chmod +x cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy
```

### Basic Usage

```bash
# Set environment variables
export NETMAKER_TOKEN="your-token"
export NOMAD_SERVER_IP="10.0.1.10"
export CONSUL_SERVER_IP="10.0.1.10"
export CONSUL_AGENT_TOKEN="your-consul-token"
export VAULT_ADDR="https://vault.example.com:8200"
export VAULT_TOKEN="your-vault-token"

# Validate configuration
./cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy --validate-only

# Deploy (requires root)
sudo -E ./cluster-forge-v1.0.0-linux-amd64-ubuntu-jammy
```

## Environment Variables for Workflow

You can customize the workflow behavior using these inputs:

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `maintainer_name` | Name to include in release metadata | `Bareuptime` | Yes |
| `ghc_token` | GitHub token for releases | `secrets.GITHUB_TOKEN` | Yes |
| `release_tag` | Version tag for the release | - | Yes |
| `prerelease` | Mark as pre-release | `false` | No |

## Troubleshooting

### Common Issues

1. **Workflow doesn't trigger**
   - Check if the tag follows semantic versioning (`v1.0.0`)
   - Ensure you have write permissions to the repository
   - Verify the workflow file syntax

2. **Build fails**
   - Check ShellCheck errors in the workflow logs
   - Ensure all required files exist in the repository
   - Verify bundler script works locally

3. **Release creation fails**
   - Check if the tag already exists
   - Verify GitHub token permissions
   - Ensure repository has releases enabled

### Debug Steps

```bash
# Test bundler locally
./bin/bundler.sh test-bundle.sh
./test-bundle.sh --help

# Test release script in dry-run mode
./scripts/release.sh -v v1.0.0 --dry-run

# Validate shell scripts
find . -name "*.sh" -not -path "./.git/*" | xargs shellcheck
```

## Security Considerations

1. **Token Security**
   - Never commit tokens to the repository
   - Use GitHub secrets for sensitive data
   - Regularly rotate access tokens

2. **Binary Verification**
   - Always verify SHA256 checksums
   - Download from official releases only
   - Review release notes before deployment

3. **Environment Variables**
   - Use secure methods to pass secrets
   - Consider using Vault or other secret management
   - Avoid logging sensitive information

## Contributing

When modifying the workflow:

1. Test changes in a fork first
2. Validate YAML syntax
3. Test with different trigger methods
4. Update documentation as needed
5. Consider backward compatibility

## Support

For issues related to:
- **Workflow failures**: Check GitHub Actions logs
- **Bundle functionality**: Test locally first
- **Release process**: Use the helper script with `--dry-run`
- **Binary usage**: Refer to main documentation
