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
MINIKUBE_MEMORY="4096"  # Increased default memory
MINIKUBE_CPUS="2"
MINIKUBE_DISK_SIZE="50g"
MINIKUBE_DRIVER="docker"
KUBECTL_VERSION="v1.31.1"
PROFILE_NAME="enterprise-k8s"
REGISTRY_MIRRORS=""
INSECURE_REGISTRIES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,europe-docker.pkg.dev"
CONFIG_DIR="$HOME/.local-cluster-cli"
LOG_FILE="$CONFIG_DIR/cluster.log"
# Enterprise mirror for binaries
ENTERPRISE_MIRROR=""
# Default image repository - updated based on the image
IMAGE_REPOSITORY="europe-docker.pkg.dev/mgmt-bak-bld-1d47/staging/ap/edh/a107595/images/platform-tools/registry.k8s.io"

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

# Pre-pull required images using wget/docker where possible
pre_pull_images() {
    log_info "Pre-pulling required Kubernetes images..."
    
    # Define required images with fallback URLs
    local images=(
        "pause:3.9"
        "kube-apiserver:v1.31.1"
        "kube-controller-manager:v1.31.1"
        "kube-scheduler:v1.31.1"
        "kube-proxy:v1.31.1"
        "etcd:3.5.15-0"
        "coredns:v1.11.1"
    )
    
    # Try to pre-pull images using docker
    if command_exists docker && docker info >/dev/null 2>&1; then
        for image in "${images[@]}"; do
            local full_image=""
            if [[ -n "$IMAGE_REPOSITORY" ]]; then
                full_image="${IMAGE_REPOSITORY}/k8s-minikube/${image}"
            else
                full_image="registry.k8s.io/${image}"
            fi
            
            log_info "Attempting to pull image: $full_image"
            if ! docker pull "$full_image" 2>/dev/null; then
                log_warning "Failed to pull $full_image, will try fallback during cluster start"
                # Try alternative registries
                local alt_registries=("k8s.gcr.io" "gcr.io/k8s-minikube")
                for alt_reg in "${alt_registries[@]}"; do
                    local alt_image="${alt_reg}/${image}"
                    log_info "Trying alternative registry: $alt_image"
                    if docker pull "$alt_image" 2>/dev/null; then
                        # Tag the image for the expected repository
                        docker tag "$alt_image" "$full_image" 2>/dev/null || true
                        break
                    fi
                done
            fi
        done
    fi
}

# Configure registry mirrors
configure_registry_mirrors() {
    log_info "Configuring container registry mirrors..."
    
    # Prompt for registry mirrors
    read -p "Docker Hub mirror URL (leave empty to skip): " dockerhub_mirror
    read -p "Additional registry mirrors (comma-separated, leave empty to skip): " additional_mirrors
    read -p "Kubernetes image registry (default: ${IMAGE_REPOSITORY}): " k8s_registry
    read -p "Custom image repository prefix (leave empty to use default): " custom_image_repository
    
    # Combine mirrors
    local mirrors=""
    [[ -n "$dockerhub_mirror" ]] && mirrors="$dockerhub_mirror"
    [[ -n "$additional_mirrors" ]] && mirrors="${mirrors:+$mirrors,}$additional_mirrors"
    
    # Set default for Kubernetes registry if empty
    [[ -z "$k8s_registry" ]] && k8s_registry="$IMAGE_REPOSITORY"
    
    # Save to config file
    local registry_config="$CONFIG_DIR/registry.conf"
    echo "# Registry configuration - $(date)" > "$registry_config"
    echo "REGISTRY_MIRRORS=\"$mirrors\"" >> "$registry_config"
    echo "INSECURE_REGISTRIES=\"$INSECURE_REGISTRIES\"" >> "$registry_config"
    echo "K8S_REGISTRY=\"$k8s_registry\"" >> "$registry_config"
    echo "IMAGE_REPOSITORY=\"${custom_image_repository:-$IMAGE_REPOSITORY}\"" >> "$registry_config"
    
    log_success "Registry settings saved to $registry_config"
    
    # Update current settings
    REGISTRY_MIRRORS="$mirrors"
    K8S_REGISTRY="$k8s_registry"
    IMAGE_REPOSITORY="${custom_image_repository:-$IMAGE_REPOSITORY}"
}

# Configure Docker daemon for insecure registries
configure_docker_daemon() {
    log_info "Configuring Docker daemon for enterprise registries..."
    
    local docker_daemon_config="/etc/docker/daemon.json"
    local temp_config="/tmp/daemon.json"
    
    # Create backup if file exists
    if [[ -f "$docker_daemon_config" ]]; then
        sudo cp "$docker_daemon_config" "${docker_daemon_config}.backup.$(date +%s)"
        log_info "Backed up existing Docker daemon configuration"
    fi
    
    # Create new daemon configuration
    cat > "$temp_config" << EOF
{
  "insecure-registries": [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "europe-docker.pkg.dev",
    "*.pkg.dev",
    "gcr.io",
    "k8s.gcr.io",
    "registry.k8s.io"
  ],
  "registry-mirrors": [
EOF

    # Add registry mirrors if configured
    if [[ -n "$REGISTRY_MIRRORS" ]]; then
        IFS=',' read -ra MIRRORS <<< "$REGISTRY_MIRRORS"
        local first=true
        for mirror in "${mirrors[@]}"; do
            if [[ "$first" == true ]]; then
                echo "    \"$mirror\"" >> "$temp_config"
                first=false
            else
                echo "    ,\"$mirror\"" >> "$temp_config"
            fi
        done
    fi
    
    cat >> "$temp_config" << EOF
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

    # Install the new configuration
    sudo cp "$temp_config" "$docker_daemon_config"
    rm -f "$temp_config"
    
    # Restart Docker daemon
    log_info "Restarting Docker daemon to apply new configuration..."
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    
    # Wait for Docker to start
    local retry_count=0
    while ! docker info >/dev/null 2>&1 && [[ $retry_count -lt 30 ]]; do
        log_info "Waiting for Docker daemon to start... ($((retry_count + 1))/30)"
        sleep 2
        ((retry_count++))
    done
    
    if docker info >/dev/null 2>&1; then
        log_success "Docker daemon restarted successfully"
    else
        log_error "Docker daemon failed to start after configuration change"
        exit 1
    fi
}

# Start minikube with enterprise settings and better error handling
start_minikube() {
    log_info "Starting enterprise Kubernetes cluster..."
    
    # Load registry settings if available
    local registry_config="$CONFIG_DIR/registry.conf"
    if [[ -f "$registry_config" ]]; then
        source "$registry_config"
    fi
    
    # Check if already running
    if command_exists minikube && minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_warning "Kubernetes cluster is already running"
        show_cluster_info
        return 0
    fi
    
    # Configure Docker daemon for insecure registries
    configure_docker_daemon
    
    # Pre-pull images to avoid download issues during cluster start
    pre_pull_images
    
    # Prepare start command with enterprise settings
    local start_cmd="minikube start"
    start_cmd+=" --driver=$MINIKUBE_DRIVER"
    start_cmd+=" --memory=$MINIKUBE_MEMORY"
    start_cmd+=" --cpus=$MINIKUBE_CPUS"
    start_cmd+=" --disk-size=$MINIKUBE_DISK_SIZE"
    start_cmd+=" --profile=$PROFILE_NAME"
    start_cmd+=" --insecure-registry=\"$INSECURE_REGISTRIES\""
    start_cmd+=" --embed-certs=true"
    start_cmd+=" --force-systemd=true"
    start_cmd+=" --extra-config=kubeadm.ignore-preflight-errors=NumCPU"
    start_cmd+=" --extra-config=kubelet.resolv-conf=/run/systemd/resolve/resolv.conf"
    
    # Add registry mirrors if configured
    if [[ -n "$REGISTRY_MIRRORS" ]]; then
        IFS=',' read -ra MIRRORS <<< "$REGISTRY_MIRRORS"
        for mirror in "${MIRRORS[@]}"; do
            [[ -n "$mirror" ]] && start_cmd+=" --registry-mirror=$mirror"
        done
    fi
    
    # Add custom image repository if configured
    if [[ -n "$IMAGE_REPOSITORY" ]]; then
        start_cmd+=" --image-repository=\"$IMAGE_REPOSITORY\""
        log_info "Using custom image repository: $IMAGE_REPOSITORY"
    fi
    
    # Additional Docker-specific settings for enterprise environments
    if [[ "$MINIKUBE_DRIVER" == "docker" ]]; then
        start_cmd+=" --docker-opt=default-address-pool=base=192.168.64.0/16,size=24"
        start_cmd+=" --docker-env=HTTP_PROXY=${HTTP_PROXY:-}"
        start_cmd+=" --docker-env=HTTPS_PROXY=${HTTPS_PROXY:-}"
        start_cmd+=" --docker-env=NO_PROXY=${NO_PROXY:-localhost,127.0.0.1,10.96.0.0/12,192.168.0.0/16,172.17.0.0/16}"
    fi
    
    # Start the cluster with retry logic
    log_info "Starting Kubernetes cluster with enterprise settings..."
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_info "Cluster start attempt $((retry_count + 1))/$max_retries"
        
        if eval "$start_cmd"; then
            log_success "Cluster started successfully!"
            break
        else
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "Cluster start failed, cleaning up and retrying..."
                minikube delete -p "$PROFILE_NAME" 2>/dev/null || true
                sleep 10
            else
                log_error "Failed to start cluster after $max_retries attempts"
                log_error "Please check the logs and try manual troubleshooting"
                log_info "You can run 'minikube logs -p $PROFILE_NAME' for more details"
                exit 1
            fi
        fi
    done
    
    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    local ready_retry=0
    while [[ $ready_retry -lt 60 ]]; do
        if kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then
            log_success "Cluster is ready!"
            break
        fi
        sleep 5
        ((ready_retry++))
        log_info "Waiting for cluster... ($ready_retry/60)"
    done
    
    # Enable useful addons with error handling
    log_info "Enabling enterprise addons..."
    local addons=("dashboard" "metrics-server" "ingress" "registry")
    
    for addon in "${addons[@]}"; do
        log_info "Enabling addon: $addon"
        if minikube addons enable "$addon" -p "$PROFILE_NAME"; then
            log_success "Enabled $addon addon"
        else
            log_warning "Failed to enable $addon addon - continuing anyway"
        fi
    done
    
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

# Install Docker on Ubuntu/Debian with better enterprise support
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
    
    # Install required packages
    log_info "Installing required packages..."
    sudo apt-get $APT_FLAGS install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common
    
    # Install Docker directly from apt repositories (more reliable in enterprise environments)
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
    
    if ! command_exists curl; then
        missing_deps+=("curl")
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
                curl)
                    sudo apt-get $APT_FLAGS install -y curl
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

# Install or update minikube with enterprise mirror support and wget fallback
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
    local download_success=false
    
    # Try multiple download methods
    local download_urls=(
        "https://github.com/kubernetes/minikube/releases/latest/download/${minikube_binary}"
        "https://storage.googleapis.com/minikube/releases/latest/${minikube_binary}"
    )
    
    # Add enterprise mirror if configured
    if [[ -n "$ENTERPRISE_MIRROR" ]]; then
        download_urls=("${ENTERPRISE_MIRROR}/minikube/releases/latest/download/${minikube_binary}" "${download_urls[@]}")
    fi
    
    for url in "${download_urls[@]}"; do
        log_info "Trying to download Minikube from: $url"
        
        # Try wget first
        if wget $WGET_FLAGS -O "${minikube_binary}" "$url" 2>/dev/null; then
            download_success=true
            log_success "Downloaded using wget"
            break
        fi
        
        # Try curl as fallback
        if curl $CURL_FLAGS -L -o "${minikube_binary}" "$url" 2>/dev/null; then
            download_success=true
            log_success "Downloaded using curl"
            break
        fi
        
        log_warning "Failed to download from $url"
    done
    
    if [[ "$download_success" != true ]]; then
        # Check for local minikube binary
        log_warning "All download attempts failed. Checking for local minikube binary..."
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
    
    # Verify the downloaded binary
    if [[ ! -f "${minikube_binary}" ]] || [[ ! -s "${minikube_binary}" ]]; then
        log_error "Downloaded minikube binary is missing or empty"
        exit 1
    fi
    
    # Install the binary
    log_info "Installing minikube to /usr/local/bin/minikube..."
    chmod +x "${minikube_binary}"
    sudo install "${minikube_binary}" /usr/local/bin/minikube
    
    # Clean up the downloaded binary
    rm -f "${minikube_binary}"
    
    # Verify installation
    if minikube version >/dev/null 2>&1; then
        log_success "Minikube installed successfully"
        minikube version
    else
        log_error "Minikube installation verification failed"
        exit 1
    fi
}

# Install or update kubectl with wget fallback
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
    local kubectl_version="$KUBECTL_VERSION"
    if [[ -z "$kubectl_version" ]]; then
        log_info "Getting latest kubectl version..."
        # Try multiple methods to get version
        for version_url in "https://dl.k8s.io/release/stable.txt" "https://storage.googleapis.com/kubernetes-release/release/stable.txt"; do
            if kubectl_version=$(wget $WGET_FLAGS -qO- "$version_url" 2>/dev/null); then
                break
            fi
            if kubectl_version=$(curl $CURL_FLAGS -s "$version_url" 2>/dev/null); then
                break
            fi
        done
        
        if [[ -z "$kubectl_version" ]]; then
            log_warning "Could not fetch latest version, using fallback version"
            kubectl_version="v1.31.1"
        fi
    fi
    
    # Download and install kubectl
    local kubectl_urls=(
        "https://dl.k8s.io/release/${kubectl_version}/bin/${os}/${arch}/kubectl"
        "https://storage.googleapis.com/kubernetes-release/release/${kubectl_version}/bin/${os}/${arch}/kubectl"
    )
    
    local install_dir="/usr/local/bin"
    local temp_kubectl="/tmp/kubectl"
    local download_success=false
    
    for url in "${kubectl_urls[@]}"; do
        log_info "Trying to download kubectl from: $url"
        
        # Try wget first
        if wget $WGET_FLAGS -O "$temp_kubectl" "$url" 2>/dev/null; then
            download_success=true
            log_success "Downloaded using wget"
            break
        fi
        
        # Try curl as fallback
        if curl $CURL_FLAGS -L -o "$temp_kubectl" "$url" 2>/dev/null; then
            download_success=true
            log_success "Downloaded using curl"
            break
        fi
        
        log_warning "Failed to download from $url"
    done
    
    if [[ "$download_success" != true ]]; then
        log_error "Failed to download kubectl from all sources"
        exit 1
    fi
    
    # Verify and install
    if [[ ! -f "$temp_kubectl" ]] || [[ ! -s "$temp_kubectl" ]]; then
        log_error "Downloaded kubectl binary is missing or empty"
        exit 1
    fi
    
    chmod +x "$temp_kubectl"
    sudo mv "$temp_kubectl" "$install_dir/kubectl"
    
    # Verify installation
    if kubectl version --client >/dev/null 2>&1; then
        log_success "kubectl installed successfully"
        kubectl version --client
    else
        log_error "kubectl installation verification failed"
        exit 1
    fi
}

# Fresh installation with improved error handling
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
    
    if ! minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
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
        
        if minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
            echo "Cluster IP: $(minikube ip -p "$PROFILE_NAME" 2>/dev/null || echo 'Not available')"
            echo "Dashboard URL: $(minikube dashboard --url -p "$PROFILE_NAME" 2>/dev/null || echo 'Not available')"
            echo
            echo "Useful commands:"
            echo "  kubectl get nodes"
            echo "  kubectl get pods --all-namespaces"
            echo "  minikube dashboard -p $PROFILE_NAME"
            echo "  minikube logs -p $PROFILE_NAME"
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
    --memory MEMORY         Set memory allocation in MB [default: 4096]
    --cpus CPUS            Set number of CPUs [default: 2]
    --disk-size SIZE       Set disk size [default: 50g]
    --profile NAME         Set profile name [default: enterprise-k8s]
    --kubectl-version VER  Set specific kubectl version [default: v1.31.1]
    --image-repository REPO Set custom image repository for Kubernetes components

EXAMPLES:
    $0 fresh-install                           # Fresh installation with Docker, Minikube, kubectl
    $0 fresh-install --memory 8192 --cpus 4   # Fresh install with more resources
    $0 install-docker                          # Install Docker only
    $0 start --driver virtualbox              # Start with VirtualBox driver
    $0 status                                  # Show cluster status
    $0 delete --profile my-cluster            # Delete specific profile
    $0 configure-registry                      # Configure registry mirrors and Kubernetes image repository
    $0 start --image-repository europe-docker.pkg.dev/mgmt-bak-bld-1d47/staging/ap/edh/a107595/images/platform-tools/registry.k8s.io # Use custom registry

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

# Troubleshooting function for common issues
troubleshoot() {
    log_info "Running troubleshooting diagnostics..."
    
    echo "=== System Information ==="
    uname -a
    echo
    
    echo "=== Docker Status ==="
    if command_exists docker; then
        docker version 2>/dev/null || echo "Docker not accessible"
        docker info 2>/dev/null | head -20 || echo "Docker daemon not running"
    else
        echo "Docker not installed"
    fi
    echo
    
    echo "=== Minikube Status ==="
    if command_exists minikube; then
        minikube version
        minikube status -p "$PROFILE_NAME" 2>/dev/null || echo "No cluster running"
    else
        echo "Minikube not installed"
    fi
    echo
    
    echo "=== kubectl Status ==="
    if command_exists kubectl; then
        kubectl version --client 2>/dev/null || echo "kubectl not working"
        kubectl cluster-info 2>/dev/null || echo "No cluster connection"
    else
        echo "kubectl not installed"
    fi
    echo
    
    echo "=== Network Connectivity ==="
    echo "Testing connectivity to key endpoints..."
    local endpoints=(
        "github.com"
        "dl.k8s.io"
        "registry.k8s.io"
        "gcr.io"
        "europe-docker.pkg.dev"
    )
    
    for endpoint in "${endpoints[@]}"; do
        if wget --spider --timeout=5 "https://$endpoint" 2>/dev/null; then
            echo "✓ $endpoint - reachable"
        else
            echo "✗ $endpoint - unreachable"
        fi
    done
    echo
    
    echo "=== Proxy Configuration ==="
    echo "HTTP_PROXY: ${HTTP_PROXY:-not set}"
    echo "HTTPS_PROXY: ${HTTPS_PROXY:-not set}"
    echo "NO_PROXY: ${NO_PROXY:-not set}"
    echo
    
    echo "=== Registry Configuration ==="
    local registry_config="$CONFIG_DIR/registry.conf"
    if [[ -f "$registry_config" ]]; then
        echo "Registry configuration found:"
        cat "$registry_config"
    else
        echo "No registry configuration found"
    fi
    echo
    
    echo "=== Log File Location ==="
    echo "Main log: $LOG_FILE"
    if [[ -f "$LOG_FILE" ]]; then
        echo "Last 10 log entries:"
        tail -10 "$LOG_FILE"
    fi
    echo
    
    echo "=== Recommended Actions ==="
    echo "1. If Docker is not accessible, run: sudo usermod -aG docker \$USER && newgrp docker"
    echo "2. If network issues, configure proxy settings or registry mirrors"
    echo "3. If image pull fails, try: $0 configure-registry"
    echo "4. For detailed cluster logs, run: minikube logs -p $PROFILE_NAME"
    echo "5. To completely reset, run: $0 delete && $0 fresh-install"
}

# Clean up function for failed installations
cleanup_failed_install() {
    log_warning "Cleaning up failed installation..."
    
    # Stop and delete any partial cluster
    if command_exists minikube; then
        minikube stop -p "$PROFILE_NAME" 2>/dev/null || true
        minikube delete -p "$PROFILE_NAME" 2>/dev/null || true
    fi
    
    # Clean up any temporary files
    rm -f minikube-* kubectl-* 2>/dev/null || true
    
    log_info "Cleanup completed"
}

# Main function with enterprise commands and better error handling
main() {
    # Set up error handling
    trap cleanup_failed_install ERR
    
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
        troubleshoot)
            troubleshoot
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