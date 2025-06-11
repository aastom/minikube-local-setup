#!/bin/bash

# Enterprise Kubernetes Local Cluster Management Tool
# Usage: ./local-cluster-cli.sh [COMMAND] [OPTIONS]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Enterprise environment configuration
WGET_FLAGS="--no-check-certificate --timeout=60 --tries=5 --retry-connrefused"
CURL_FLAGS="--insecure --connect-timeout 60 --retry 5 --retry-connrefused"
APT_FLAGS="-o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false"
MINIKUBE_MEMORY="2200"
MINIKUBE_CPUS="2"
MINIKUBE_DISK_SIZE="50g"
MINIKUBE_DRIVER="docker"
KUBECTL_VERSION="v1.31.1"
PROFILE_NAME="enterprise-k8s"
REGISTRY_MIRRORS=""
INSECURE_REGISTRIES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
CONFIG_DIR="$HOME/.local-cluster-cli"
LOG_FILE="$CONFIG_DIR/cluster.log"
# Enterprise mirror for binaries
ENTERPRISE_MIRROR=""

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Logging functions with timestamps
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[$timestamp] $level $message" | tee -a "$LOG_FILE"
}

log_info() {
    log "${BLUE}INFO${NC}" "$1"
}

log_success() {
    log "${GREEN}SUCCESS${NC}" "$1"
}

log_warning() {
    log "${YELLOW}WARNING${NC}" "$1"
}

log_error() {
    log "${RED}ERROR${NC}" "$1"
}

# Configure registry mirrors
configure_registry_mirrors() {
    log_info "Configuring container registry mirrors..."
    
    # Prompt for registry mirrors
    read -p "Docker Hub mirror URL (leave empty to skip): " dockerhub_mirror
    read -p "Additional registry mirrors (comma-separated, leave empty to skip): " additional_mirrors
    read -p "Kubernetes image registry (default: k8s.gcr.io): " k8s_registry
    read -p "Custom image repository prefix (leave empty to use default): " image_repository
    
    # Combine mirrors
    local mirrors=""
    [[ -n "$dockerhub_mirror" ]] && mirrors="$dockerhub_mirror"
    [[ -n "$additional_mirrors" ]] && mirrors="${mirrors:+$mirrors,}$additional_mirrors"
    
    # Set default for Kubernetes registry if empty
    [[ -z "$k8s_registry" ]] && k8s_registry="k8s.gcr.io"
    
    # Save to config file
    local registry_config="$CONFIG_DIR/registry.conf"
    echo "# Registry configuration - $(date)" > "$registry_config"
    echo "REGISTRY_MIRRORS=\"$mirrors\"" >> "$registry_config"
    echo "INSECURE_REGISTRIES=\"$INSECURE_REGISTRIES\"" >> "$registry_config"
    echo "K8S_REGISTRY=\"$k8s_registry\"" >> "$registry_config"
    echo "IMAGE_REPOSITORY=\"$image_repository\"" >> "$registry_config"
    
    log_success "Registry settings saved to $registry_config"
    
    # Update current settings
    REGISTRY_MIRRORS="$mirrors"
    K8S_REGISTRY="$k8s_registry"
    IMAGE_REPOSITORY="$image_repository"
}

# Start minikube with enterprise settings
start_minikube() {
    log_info "Starting enterprise Kubernetes cluster..."
    
    # Load registry settings if available
    local registry_config="$CONFIG_DIR/registry.conf"
    if [[ -f "$registry_config" ]]; then
        source "$registry_config"
    fi
    
    # Check if already running
    if minikube status -p "$PROFILE_NAME" | grep -q "Running"; then
        log_warning "Kubernetes cluster is already running"
        show_cluster_info
        return 0
    fi
    
    # Prepare start command with enterprise settings
    local start_cmd="minikube start"
    start_cmd+=" --driver=$MINIKUBE_DRIVER"
    start_cmd+=" --memory=$MINIKUBE_MEMORY"
    start_cmd+=" --cpus=$MINIKUBE_CPUS"
    start_cmd+=" --disk-size=$MINIKUBE_DISK_SIZE"
    start_cmd+=" --profile=$PROFILE_NAME"
    start_cmd+=" --insecure-registry=\"$INSECURE_REGISTRIES\""
    start_cmd+=" --embed-certs=true"
    
    # Add registry mirrors if configured
    if [[ -n "$REGISTRY_MIRRORS" ]]; then
        IFS=',' read -ra MIRRORS <<< "$REGISTRY_MIRRORS"
        for mirror in "${MIRRORS[@]}"; do
            start_cmd+=" --registry-mirror=$mirror"
        done
    fi
    
    # Add custom Kubernetes image registry if configured
    if [[ -n "$K8S_REGISTRY" && "$K8S_REGISTRY" != "k8s.gcr.io" ]]; then
        start_cmd+=" --image-repository=\"$K8S_REGISTRY\""
    fi
    
    # Add custom image repository prefix if configured
    if [[ -n "$IMAGE_REPOSITORY" ]]; then
        start_cmd+=" --image-repository=\"$IMAGE_REPOSITORY\""
    fi
    
    # Start the cluster
    log_info "Starting Kubernetes cluster with enterprise settings..."
    eval "$start_cmd"
    
    # Enable useful addons with error handling
    log_info "Enabling enterprise addons..."
    minikube addons enable dashboard -p "$PROFILE_NAME" || log_warning "Failed to enable dashboard addon"
    minikube addons enable metrics-server -p "$PROFILE_NAME" || log_warning "Failed to enable metrics-server addon"
    minikube addons enable ingress -p "$PROFILE_NAME" || log_warning "Failed to enable ingress addon"
    minikube addons enable registry -p "$PROFILE_NAME" || log_warning "Failed to enable registry addon"
    
    log_success "Enterprise Kubernetes cluster started successfully!"
    show_cluster_info
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running on Ubuntu/Debian
check_os_support() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine operating system"
        exit 1
    fi
    
    source /etc/os-release
    case $ID in
        ubuntu|debian)
            log_info "Detected $PRETTY_NAME"
            ;;
        *)
            log_warning "This script is optimized for Ubuntu/Debian systems"
            log_warning "Docker installation may not work on $PRETTY_NAME"
            ;;
    esac
}

# Install Docker on Ubuntu/Debian
install_docker() {
    log_info "Installing Docker..."
    
    # Check if Docker is already installed
    if command_exists docker; then
        log_info "Docker is already installed"
        # Check if docker daemon is running
        if docker info >/dev/null 2>&1; then
            log_success "Docker is installed and running"
            return 0
        else
            log_info "Docker is installed but not running. Starting Docker service..."
            sudo systemctl start docker
            sudo systemctl enable docker
            return 0
        fi
    fi
    
    # Update package index with corporate network settings
    log_info "Updating package index..."
    sudo apt-get $APT_FLAGS update
    
    # Remove any old Docker packages
    log_info "Removing old Docker packages..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Install Docker directly from apt repositories
    log_info "Installing Docker from apt repositories..."
    sudo apt-get $APT_FLAGS install -y docker.io docker-compose
    
    # Start and enable Docker service
    log_info "Starting Docker service..."
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Add current user to docker group
    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"
    
    # Test Docker installation (skip if behind corporate firewall)
    log_info "Testing Docker installation..."
    if sudo docker run --rm hello-world >/dev/null 2>&1; then
        log_success "Docker installed and configured successfully!"
    else
        log_warning "Docker installed but connectivity test failed (likely due to corporate firewall)"
        log_success "Docker installation completed"
    fi
    
    log_warning "Please logout and login again (or run 'newgrp docker') to use Docker without sudo"
}

# Check system requirements
check_requirements() {
    log_info "Checking system requirements..."
    
    # Check OS support
    check_os_support
    
    # Check for required commands
    local missing_deps=()
    
    if ! command_exists wget; then
        missing_deps+=("wget")
    fi
    
    if [[ "$MINIKUBE_DRIVER" == "virtualbox" ]] && ! command_exists vboxmanage; then
        missing_deps+=("virtualbox")
    fi
    
    # Install missing basic dependencies
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies: ${missing_deps[*]}"
        sudo apt-get $APT_FLAGS update
        for dep in "${missing_deps[@]}"; do
            case $dep in
                wget)
                    sudo apt-get $APT_FLAGS install -y wget
                    ;;
                virtualbox)
                    sudo apt-get $APT_FLAGS install -y virtualbox
                    ;;
            esac
        done
    fi
    
    # Handle Docker installation/check
    if [[ "$MINIKUBE_DRIVER" == "docker" ]]; then
        if ! command_exists docker; then
            log_info "Docker not found. Installing Docker..."
            install_docker
        elif ! docker info >/dev/null 2>&1; then
            log_info "Docker is installed but not accessible. Checking permissions..."
            if ! groups "$USER" | grep -q docker; then
                log_warning "User is not in docker group. Adding user to docker group..."
                sudo usermod -aG docker "$USER"
                log_warning "Please logout and login again, then re-run this script"
                exit 1
            else
                log_info "Starting Docker service..."
                sudo systemctl start docker
            fi
        fi
    fi
    
    log_success "System requirements check passed"
}

# Install or update minikube with enterprise mirror support
install_minikube() {
    log_info "Installing/updating Minikube..."
    
    local os
    case "$(uname -s)" in
        Linux*)     os="linux" ;;
        Darwin*)    os="darwin" ;;
        *)          log_error "Unsupported operating system"; exit 1 ;;
    esac
    
    local arch
    case "$(uname -m)" in
        x86_64)     arch="amd64" ;;
        arm64)      arch="arm64" ;;
        aarch64)    arch="arm64" ;;
        *)          log_error "Unsupported architecture"; exit 1 ;;
    esac
    
    # Download and install minikube
    local minikube_binary="minikube-${os}-${arch}"
    local minikube_url
    
    # Check if enterprise mirror is configured
    if [[ -n "$ENTERPRISE_MIRROR" ]]; then
        minikube_url="${ENTERPRISE_MIRROR}/minikube/releases/latest/download/${minikube_binary}"
        log_info "Using enterprise mirror for Minikube: $minikube_url"
    else
        minikube_url="https://github.com/kubernetes/minikube/releases/latest/download/${minikube_binary}"
    fi
    
    # Try to download from configured source
    log_info "Downloading Minikube binary from $minikube_url..."
    if ! wget $WGET_FLAGS -O "${minikube_binary}" "$minikube_url"; then
        # If download fails, try alternative method - local file
        log_warning "Download failed. Checking for local minikube binary..."
        if [[ -f "$CONFIG_DIR/${minikube_binary}" ]]; then
            log_info "Found local minikube binary. Installing..."
            cp "$CONFIG_DIR/${minikube_binary}" "./${minikube_binary}"
        else
            log_error "No local minikube binary found."
            log_info "Please manually download minikube and place it at:"
            log_info "$CONFIG_DIR/${minikube_binary}"
            log_info "Then run this command again."
            exit 1
        fi
    fi
    
    # Install the binary
    log_info "Installing minikube to /usr/local/bin/minikube..."
    sudo install "${minikube_binary}" /usr/local/bin/minikube
    
    # Clean up the downloaded binary
    rm -f "${minikube_binary}"
    
    log_success "Minikube installed successfully"
}

# Install or update kubectl
install_kubectl() {
    log_info "Installing/updating kubectl..."
    
    local os
    case "$(uname -s)" in
        Linux*)     os="linux" ;;
        Darwin*)    os="darwin" ;;
        *)          log_error "Unsupported operating system"; exit 1 ;;
    esac
    
    local arch
    case "$(uname -m)" in
        x86_64)     arch="amd64" ;;
        arm64)      arch="arm64" ;;
        aarch64)    arch="arm64" ;;
        *)          log_error "Unsupported architecture"; exit 1 ;;
    esac
    
    # Get kubectl version
    local version_url="https://dl.k8s.io/release/stable.txt"
    if [[ -n "$KUBECTL_VERSION" ]]; then
        local kubectl_version="$KUBECTL_VERSION"
    else
        log_info "Getting latest kubectl version..."
        local kubectl_version=$(wget $WGET_FLAGS -qO- "$version_url")
        if [[ -z "$kubectl_version" ]]; then
            log_warning "Could not fetch latest version, using fallback version"
            kubectl_version="v1.31.0"  # Updated fallback to latest stable
        fi
    fi
    
    # Download and install kubectl
    local kubectl_url="https://dl.k8s.io/release/${kubectl_version}/bin/${os}/${arch}/kubectl"
    local install_dir="/usr/local/bin"
    
    log_info "Downloading kubectl binary..."
    if [[ ! -w "$install_dir" ]]; then
        log_info "Installing to $install_dir requires sudo privileges"
        sudo wget $WGET_FLAGS -O "$install_dir/kubectl" "$kubectl_url"
        sudo chmod +x "$install_dir/kubectl"
    else
        wget $WGET_FLAGS -O "$install_dir/kubectl" "$kubectl_url"
        chmod +x "$install_dir/kubectl"
    fi
    
    log_success "kubectl installed successfully"
}

# Fresh installation
fresh_install() {
    log_info "Starting fresh Minikube installation..."
    
    # Check if running as root (not recommended)
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        log_info "Please run as a regular user (the script will prompt for sudo when needed)"
        exit 1
    fi
    
    check_requirements
    
    # Install minikube and kubectl
    install_minikube
    install_kubectl
    
    # Delete existing cluster if it exists
    if command_exists minikube && minikube status -p "$PROFILE_NAME" >/dev/null 2>&1; then
        log_warning "Existing Minikube cluster found. Deleting..."
        minikube delete -p "$PROFILE_NAME"
    fi
    
    # Start minikube with specified configuration
    start_minikube
    
    log_success "Fresh Minikube installation completed successfully!"
    log_info "If you just installed Docker, you may need to logout and login again for group permissions to take effect"
    show_cluster_info
}

# Stop minikube
stop_minikube() {
    log_info "Stopping Minikube cluster..."
    
    if ! command_exists minikube; then
        log_error "Minikube is not installed"
        exit 1
    fi
    
    if ! minikube status -p "$PROFILE_NAME" | grep -q "Running"; then
        log_warning "Minikube cluster is not running"
        return 0
    fi
    
    minikube stop -p "$PROFILE_NAME"
    log_success "Minikube cluster stopped successfully!"
}

# Delete minikube cluster
delete_minikube() {
    log_info "Deleting Minikube cluster..."
    
    if ! command_exists minikube; then
        log_error "Minikube is not installed"
        exit 1
    fi
    
    # Confirm deletion
    read -p "Are you sure you want to delete the Minikube cluster '$PROFILE_NAME'? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deletion cancelled"
        return 0
    fi
    
    minikube delete -p "$PROFILE_NAME"
    log_success "Minikube cluster deleted successfully!"
}

# Show cluster information
show_cluster_info() {
    log_info "Cluster Information:"
    echo "===================="
    
    if command_exists minikube && minikube status -p "$PROFILE_NAME" >/dev/null 2>&1; then
        echo "Profile: $PROFILE_NAME"
        minikube status -p "$PROFILE_NAME"
        echo
        
        if minikube status -p "$PROFILE_NAME" | grep -q "Running"; then
            echo "Cluster IP: $(minikube ip -p "$PROFILE_NAME")"
            echo "Dashboard URL: $(minikube dashboard --url -p "$PROFILE_NAME" 2>/dev/null || echo 'Not available')"
            echo
            echo "Useful commands:"
            echo "  kubectl get nodes"
            echo "  kubectl get pods --all-namespaces"
            echo "  minikube dashboard -p $PROFILE_NAME"
        fi
    else
        echo "No cluster found"
    fi
}

# Show help
show_help() {
    cat << EOF
Enterprise Kubernetes Local Cluster Management Tool

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    fresh-install       Install Docker, Minikube, kubectl, and create a new cluster
    start              Start the Minikube cluster
    stop               Stop the Minikube cluster
    delete             Delete the Minikube cluster
    status             Show cluster status and information
    install-docker     Install Docker only (Ubuntu/Debian)
    configure-registry Configure container registry mirrors and Kubernetes image repository
    configure-mirror   Configure enterprise mirror for binaries
    help               Show this help message

OPTIONS:
    --driver DRIVER         Set the driver (docker, virtualbox, kvm2, etc.) [default: docker]
    --memory MEMORY         Set memory allocation in MB [default: 8192]
    --cpus CPUS            Set number of CPUs [default: 2]
    --disk-size SIZE       Set disk size [default: 40g]
    --profile NAME         Set profile name [default: enterprise-k8s]
    --kubectl-version VER  Set specific kubectl version [default: latest stable]
    --image-repository REPO Set custom image repository for Kubernetes components

EXAMPLES:
    $0 fresh-install                           # Fresh installation with Docker, Minikube, kubectl
    $0 fresh-install --memory 16384 --cpus 8  # Fresh install with more resources
    $0 install-docker                          # Install Docker only
    $0 start --driver virtualbox              # Start with VirtualBox driver
    $0 status                                  # Show cluster status
    $0 delete --profile my-cluster            # Delete specific profile
    $0 configure-registry                      # Configure registry mirrors and Kubernetes image repository
    $0 start --image-repository registry.internal.company.com/k8s # Use custom registry

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --driver)
                MINIKUBE_DRIVER="$2"
                shift 2
                ;;
            --memory)
                MINIKUBE_MEMORY="$2"
                shift 2
                ;;
            --cpus)
                MINIKUBE_CPUS="$2"
                shift 2
                ;;
            --disk-size)
                MINIKUBE_DISK_SIZE="$2"
                shift 2
                ;;
            --profile)
                PROFILE_NAME="$2"
                shift 2
                ;;
            --kubectl-version)
                KUBECTL_VERSION="$2"
                shift 2
                ;;
            --image-repository)
                IMAGE_REPOSITORY="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Load enterprise mirror configuration
load_mirror_config() {
    local mirror_config="$CONFIG_DIR/mirror.conf"
    if [[ -f "$mirror_config" ]]; then
        log_info "Loading mirror configuration from $mirror_config"
        source "$mirror_config"
    else
        log_info "No mirror configuration found. Using default settings."
    fi
}

# Configure enterprise mirror
configure_mirror() {
    log_info "Configuring enterprise mirror..."
    
    # Prompt for mirror URL
    read -p "Enter the enterprise mirror URL (leave empty to skip): " mirror_url
    
    if [[ -n "$mirror_url" ]]; then
        # Save the mirror URL to the config file
        local mirror_config="$CONFIG_DIR/mirror.conf"
        echo "# Enterprise mirror configuration - $(date)" > "$mirror_config"
        echo "ENTERPRISE_MIRROR=\"$mirror_url\"" >> "$mirror_config"
        
        log_success "Mirror configuration saved to $mirror_config"
        
        # Reload the mirror configuration
        load_mirror_config
    else
        log_info "No mirror URL provided. Skipping mirror configuration."
    fi
}

# Main function with enterprise commands
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi
    
    # Load enterprise mirror configuration
    load_mirror_config
    
    local command=$1
    shift
    
    # Parse remaining arguments
    parse_args "$@"
    
    case $command in
        fresh-install)
            fresh_install
            ;;
        start)
            start_minikube
            ;;
        stop)
            stop_minikube
            ;;
        delete)
            delete_minikube
            ;;
        status)
            show_cluster_info
            ;;
        install-docker)
            check_os_support
            install_docker
            ;;
        configure-registry)
            configure_registry_mirrors
            ;;
        configure-mirror)
            configure_mirror
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
