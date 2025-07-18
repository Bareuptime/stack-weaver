#!/bin/bash
# =============================================================================
# RELEASE HELPER SCRIPT
# Helps trigger GitHub Actions workflow for building and releasing
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

show_help() {
    cat << EOF
Release Helper Script for Cluster Forge

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    This script helps you trigger GitHub Actions workflows to build and release
    Cluster Forge bundles. It can create git tags and trigger the build process.

OPTIONS:
    -h, --help              Show this help message
    -v, --version VERSION   Release version (e.g., v1.0.0)
    -m, --maintainer NAME   Maintainer name (default: Bareuptime)
    -t, --tag-only          Only create git tag, don't trigger workflow
    -d, --dry-run           Show what would be done without making changes
    --prerelease            Mark release as pre-release

ENVIRONMENT VARIABLES:
    GITHUB_TOKEN            GitHub personal access token (required for API calls)

EXAMPLES:
    # Create a new release
    $0 -v v1.0.0 -m "Your Name"

    # Create a pre-release
    $0 -v v1.0.0-beta1 --prerelease

    # Only create git tag
    $0 -v v1.0.0 --tag-only

    # Dry run to see what would happen
    $0 -v v1.0.0 --dry-run

WORKFLOW TRIGGER:
    This script can either:
    1. Create a git tag (which triggers the workflow automatically)
    2. Use GitHub API to trigger the workflow_dispatch event

EOF
}

# Default values
VERSION=""
MAINTAINER="Bareuptime"
TAG_ONLY=false
DRY_RUN=false
PRERELEASE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -m|--maintainer)
            MAINTAINER="$2"
            shift 2
            ;;
        -t|--tag-only)
            TAG_ONLY=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --prerelease)
            PRERELEASE=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate inputs
if [[ -z "$VERSION" ]]; then
    log_error "Version is required. Use -v or --version to specify."
    exit 1
fi

# Ensure version starts with 'v'
if [[ ! "$VERSION" =~ ^v ]]; then
    VERSION="v$VERSION"
fi

# Validate version format
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]; then
    log_error "Invalid version format. Expected: v1.0.0 or v1.0.0-beta1"
    exit 1
fi

log_info "Preparing release: $VERSION"
log_info "Maintainer: $MAINTAINER"
log_info "Pre-release: $PRERELEASE"
log_info "Tag only: $TAG_ONLY"
log_info "Dry run: $DRY_RUN"

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    log_error "Not in a git repository"
    exit 1
fi

# Check if there are uncommitted changes
if ! git diff-index --quiet HEAD --; then
    log_warn "There are uncommitted changes in the repository"
    if [[ "$DRY_RUN" == false ]]; then
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 1
        fi
    fi
fi

# Check if tag already exists
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    log_error "Tag $VERSION already exists"
    exit 1
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current)
log_info "Current branch: $CURRENT_BRANCH"

if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN MODE - Would perform the following actions:"
    log_info "1. Create git tag: $VERSION"
    log_info "2. Push tag to origin"
    if [[ "$TAG_ONLY" == false ]]; then
        log_info "3. Trigger GitHub Actions workflow"
    fi
    log_info ""
    log_info "Git command that would be executed:"
    log_info "  git tag -a $VERSION -m \"Release $VERSION\""
    log_info "  git push origin $VERSION"
    exit 0
fi

# Create the git tag
log_info "Creating git tag: $VERSION"
git tag -a "$VERSION" -m "Release $VERSION"

log_info "Pushing tag to origin..."
git push origin "$VERSION"

if [[ "$TAG_ONLY" == false ]]; then
    # Check if GitHub CLI is available
    if command -v gh &> /dev/null; then
        log_info "Triggering GitHub Actions workflow using GitHub CLI..."
        gh workflow run build-release.yml \
            -f maintainer_name="$MAINTAINER" \
            -f ghc_token="\${{ secrets.GITHUB_TOKEN }}" \
            -f release_tag="$VERSION" \
            -f prerelease="$PRERELEASE"
        
        log_info "Workflow triggered successfully!"
        log_info "You can monitor the progress at:"
        log_info "https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions"
    else
        log_info "GitHub CLI not found. The workflow will be triggered automatically by the tag push."
        log_info "You can also trigger it manually in the GitHub Actions tab."
    fi
fi

log_info "✅ Release process initiated successfully!"
log_info ""
log_info "📋 What happens next:"
log_info "1. GitHub Actions will build binaries for multiple OS versions"
log_info "2. Integration tests will run on different container images"
log_info "3. A GitHub release will be created with all artifacts"
log_info "4. SHA256 checksums will be generated for security"
log_info ""
log_info "🔗 Monitor progress at:"
log_info "https://github.com/Bareuptime/stack-weaver/actions"
