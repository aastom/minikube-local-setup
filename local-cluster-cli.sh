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
HTTP_PROXY_ENV=""
HTTPS_PROXY_ENV=""
NO_PROXY_ENV="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.internal"
MINIKUBE_MEMORY="4096"
MINIKUBE_CPUS="2"
MINIKUBE_DISK_SIZE="40g"
MINIKUBE_DRIVER="docker"
KUBECTL_VERSION="v1.31.1"
PROFILE_NAME="enterprise-k8s"
REGISTRY_MIRRORS=""
INSECURE_REGISTRIES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
CONFIG_DIR="$HOME/.local-cluster-cli"
LOG_FILE="$CONFIG_DIR/cluster.log"

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

# Load proxy settings from environment or config file
load_proxy_settings() {
    # Check for proxy settings in environment
    if [[ -n "$http_proxy" || -n "$HTTP_PROXY" ]]; then
        HTTP_PROXY_ENV="${http_proxy:-$HTTP_PROXY}"
        log_info "Using HTTP proxy from environment: $HTTP_PROXY_ENV"
    fi
    
    if [[ -n "$https_proxy" || -n "$HTTPS_PROXY" ]]; then
        HTTPS_PROXY_ENV="${https_proxy:-$HTTPS_PROXY}"
        log_info "Using HTTPS proxy from environment: $HTTPS_PROXY_ENV"
    fi
    
    if [[ -n "$no_proxy" || -n "$NO_PROXY" ]]; then
        NO_PROXY_ENV="${no_proxy:-$NO_PROXY}"
        log_info "Using NO_PROXY from environment: $NO_PROXY_ENV"
    fi
    
    # Check for proxy config file
    local proxy_config="$CONFIG_DIR/proxy.conf"
    if [[ -f "$proxy_config" ]]; then
        log_info "Loading proxy settings from $proxy_config"
        source "$proxy_config"
    fi
    
    # Export proxy settings for subprocesses
    export http_proxy="$HTTP_PROXY_ENV"
    export https_proxy="$HTTPS_PROXY_ENV"
    export no_proxy="$NO_PROXY_ENV"
    export HTTP_PROXY="$HTTP_PROXY_ENV"
    export HTTPS_PROXY="$HTTPS_PROXY_ENV"
    export NO_PROXY="$NO_PROXY_ENV"
}

# Configure proxy settings
configure_proxy() {
    log_info "Configuring proxy settings..."
    
    # Prompt for proxy settings
    read -p "HTTP Proxy URL (leave empty to skip): " http_proxy_input
    read -p "HTTPS Proxy URL (leave empty to skip): " https_proxy_input
    read -p "No Proxy list (leave empty for default): " no_proxy_input
    
    # Set default for no_proxy if empty
    no_proxy_input=${no_proxy_input:-$NO_PROXY_ENV}
    
    # Save to config file
    local proxy_config="$CONFIG_DIR/proxy.conf"
    echo "# Proxy configuration - $(date)" > "$proxy_config"
    [[ -n "$http_proxy_input" ]] && echo "HTTP_PROXY_ENV=\"$http_proxy_input\"" >> "$proxy_config"
    [[ -n "$https_proxy_input" ]] && echo "HTTPS_PROXY_ENV=\"$https_proxy_input\"" >> "$proxy_config"
    [[ -n "$no_proxy_input" ]] && echo "NO_PROXY_ENV=\"$no_proxy_input\"" >> "$proxy_config"
    
    log_success "Proxy settings saved to $proxy_config"
    
    # Reload settings
    load_proxy_settings
}

# Configure registry mirrors
configure_registry_mirrors() {
    log_info "Configuring container registry mirrors..."
    
    # Prompt for registry mirrors
    read -p "Docker Hub mirror URL (leave empty to skip): " dockerhub_mirror
    read -p "Additional registry mirrors (comma-separated, leave empty to skip): " additional_mirrors
    
    # Combine mirrors
    local mirrors=""
    [[ -n "$dockerhub_mirror" ]] && mirrors="$dockerhub_mirror"
    [[ -n "$additional_mirrors" ]] && mirrors="${mirrors:+$mirrors,}$additional_mirrors"
    
    # Save to config file
    local registry_config="$CONFIG_DIR/registry.conf"
    echo "# Registry configuration - $(date)" > "$registry_config"
    echo "REGISTRY_MIRRORS=\"$mirrors\"" >> "$registry_config"
    echo "INSECURE_REGISTRIES=\"$INSECURE_REGISTRIES\"" >> "$registry_config"
    
    log_success "Registry settings saved to $registry_config"
    
    # Update current settings
    REGISTRY_MIRRORS="$mirrors"
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

# Install or update minikube
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
    local minikube_url="https://storage.googleapis.com/minikube/releases/latest/minikube-${os}-${arch}"
    local install_dir="/usr/local/bin"
    
    log_info "Downloading Minikube binary..."
    if [[ ! -w "$install_dir" ]]; then
        log_info "Installing to $install_dir requires sudo privileges"
        sudo wget $WGET_FLAGS -O "$install_dir/minikube" "$minikube_url"
        sudo chmod +x "$install_dir/minikube"
    else
        wget $WGET_FLAGS -O "$install_dir/minikube" "$minikube_url"
        chmod +x "$install_dir/minikube"
    fi
    
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

# Start minikube with enterprise settings
start_minikube() {
    log_info "Starting enterprise Kubernetes cluster..."
    
    # Load proxy and registry settings
    load_proxy_settings
    
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
    
    # Add proxy settings if configured
    if [[ -n "$HTTP_PROXY_ENV" ]]; then
        start_cmd+=" --docker-env=HTTP_PROXY=$HTTP_PROXY_ENV"
    fi
    if [[ -n "$HTTPS_PROXY_ENV" ]]; then
        start_cmd+=" --docker-env=HTTPS_PROXY=$HTTPS_PROXY_ENV"
    fi
    if [[ -n "$NO_PROXY_ENV" ]]; then
        start_cmd+=" --docker-env=NO_PROXY=$NO_PROXY_ENV"
    fi
    
    # Add registry mirrors if configured
    if [[ -n "$REGISTRY_MIRRORS" ]]; then
        IFS=',' read -ra MIRRORS <<< "$REGISTRY_MIRRORS"
        for mirror in "${MIRRORS[@]}"; do
            start_cmd+=" --registry-mirror=$mirror"
        done
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
    configure-proxy    Configure proxy settings
    configure-registry Configure container registry mirrors
    help               Show this help message

OPTIONS:
    --driver DRIVER         Set the driver (docker, virtualbox, kvm2, etc.) [default: docker]
    --memory MEMORY         Set memory allocation in MB [default: 8192]
    --cpus CPUS            Set number of CPUs [default: 4]
    --disk-size SIZE       Set disk size [default: 40g]
    --profile NAME         Set profile name [default: enterprise-k8s]
    --kubectl-version VER  Set specific kubectl version [default: latest stable]

EXAMPLES:
    $0 fresh-install                           # Fresh installation with Docker, Minikube, kubectl
    $0 fresh-install --memory 16384 --cpus 8  # Fresh install with more resources
    $0 install-docker                          # Install Docker only
    $0 start --driver virtualbox              # Start with VirtualBox driver
    $0 status                                  # Show cluster status
    $0 delete --profile my-cluster            # Delete specific profile

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
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Main function with enterprise commands
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi
    
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
        configure-proxy)
            configure_proxy
            ;;
        configure-registry)
            configure_registry_mirrors
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
