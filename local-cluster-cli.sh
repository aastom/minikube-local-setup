#!/bin/bash

# Minikube Management CLI Tool for SoI engineers
# Usage: ./local-cluster.sh [COMMAND] [OPTIONS]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Network configuration for corporate environments
WGET_FLAGS="--no-check-certificate --timeout=30 --tries=3"
APT_FLAGS="-o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false"
MINIKUBE_MEMORY="4096"
MINIKUBE_CPUS="2"
MINIKUBE_DISK_SIZE="20g"
KUBECTL_VERSION=""
PROFILE_NAME="minikube"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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
            kubectl_version="v1.30.0"  # Fallback version
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

# Start minikube
start_minikube() {
    log_info "Starting Minikube cluster..."
    
    if ! command_exists minikube; then
        log_error "Minikube is not installed. Please run with --fresh-install first."
        exit 1
    fi
    
    # Check if already running
    if minikube status -p "$PROFILE_NAME" | grep -q "Running"; then
        log_warning "Minikube cluster is already running"
        show_cluster_info
        return 0
    fi
    
    # Start minikube with corporate network settings
    log_info "Starting Minikube with corporate network settings..."
    minikube start \
        --driver="$MINIKUBE_DRIVER" \
        --memory="$MINIKUBE_MEMORY" \
        --cpus="$MINIKUBE_CPUS" \
        --disk-size="$MINIKUBE_DISK_SIZE" \
        --profile="$PROFILE_NAME" \
        --insecure-registry="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" \
        --embed-certs=true
    
    # Enable useful addons (with error handling for corporate networks)
    log_info "Enabling useful addons..."
    minikube addons enable dashboard -p "$PROFILE_NAME" || log_warning "Failed to enable dashboard addon"
    minikube addons enable metrics-server -p "$PROFILE_NAME" || log_warning "Failed to enable metrics-server addon"
    minikube addons enable ingress -p "$PROFILE_NAME" || log_warning "Failed to enable ingress addon"
    
    log_success "Minikube cluster started successfully!"
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
Minikube Management CLI Tool for SoI engineers

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    fresh-install       Install Docker, Minikube, kubectl, and create a new cluster
    start              Start the Minikube cluster
    stop               Stop the Minikube cluster
    delete             Delete the Minikube cluster
    status             Show cluster status and information
    install-docker     Install Docker only (Ubuntu/Debian)
    help               Show this help message

OPTIONS:
    --driver DRIVER         Set the driver (docker, virtualbox, kvm2, etc.) [default: docker]
    --memory MEMORY         Set memory allocation in MB [default: 4096]
    --cpus CPUS            Set number of CPUs [default: 2]
    --disk-size SIZE       Set disk size [default: 20g]
    --profile NAME         Set profile name [default: minikube]
    --kubectl-version VER  Set specific kubectl version [default: latest stable]

EXAMPLES:
    $0 fresh-install                           # Fresh installation with Docker, Minikube, kubectl
    $0 fresh-install --memory 8192 --cpus 4   # Fresh install with more resources
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

# Main function
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