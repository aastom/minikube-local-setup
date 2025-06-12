#!/bin/bash

# Enterprise Kubernetes Local Cluster Management Tool for WSL with Windows Docker
# Usage: ./local-cluster-cli.sh [COMMAND] [OPTIONS]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
MINIKUBE_MEMORY="4096"
MINIKUBE_CPUS="2"
MINIKUBE_DISK_SIZE="50g"
MINIKUBE_DRIVER="docker"
KUBECTL_VERSION="v1.31.1"
PROFILE_NAME="enterprise-k8s"
INSECURE_REGISTRIES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,europe-docker.pkg.dev"
CONFIG_DIR="$HOME/.local-cluster-cli"
LOG_FILE="$CONFIG_DIR/cluster.log"

# Individual image URLs - can be overridden via command line or config file
KICBASE_IMAGE=""
PAUSE_IMAGE=""
KUBE_APISERVER_IMAGE=""
KUBE_CONTROLLER_MANAGER_IMAGE=""
KUBE_SCHEDULER_IMAGE=""
KUBE_PROXY_IMAGE=""
ETCD_IMAGE=""
COREDNS_IMAGE=""
STORAGE_PROVISIONER_IMAGE=""

# Default image versions and sources
PAUSE_VERSION="3.9"
KUBE_VERSION="v1.31.1"
ETCD_VERSION="3.5.15-0"
COREDNS_VERSION="v1.11.1"
STORAGE_PROVISIONER_VERSION="v5"
DEFAULT_REGISTRY="registry.k8s.io"

# Create config directory
mkdir -p "$CONFIG_DIR"

# Logging functions
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[$timestamp] $level $message" | tee -a "$LOG_FILE"
}

log_info() { log "${BLUE}INFO${NC}" "$1"; }
log_success() { log "${GREEN}SUCCESS${NC}" "$1"; }
log_warning() { log "${YELLOW}WARNING${NC}" "$1"; }
log_error() { log "${RED}ERROR${NC}" "$1"; }

# Check if running in WSL
is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]] || [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]] || grep -qi microsoft /proc/version 2>/dev/null
}

# Load custom image configuration
load_image_config() {
    local image_config="$CONFIG_DIR/images.conf"
    if [[ -f "$image_config" ]]; then
        log_info "Loading custom image configuration from $image_config"
        source "$image_config"
        
        # Log which custom images are being used
        [[ -n "$KICBASE_IMAGE" ]] && log_info "Custom kicbase: $KICBASE_IMAGE"
        [[ -n "$PAUSE_IMAGE" ]] && log_info "Custom pause: $PAUSE_IMAGE"
        [[ -n "$KUBE_APISERVER_IMAGE" ]] && log_info "Custom apiserver: $KUBE_APISERVER_IMAGE"
        [[ -n "$KUBE_CONTROLLER_MANAGER_IMAGE" ]] && log_info "Custom controller-manager: $KUBE_CONTROLLER_MANAGER_IMAGE"
        [[ -n "$KUBE_SCHEDULER_IMAGE" ]] && log_info "Custom scheduler: $KUBE_SCHEDULER_IMAGE"
        [[ -n "$KUBE_PROXY_IMAGE" ]] && log_info "Custom proxy: $KUBE_PROXY_IMAGE"
        [[ -n "$ETCD_IMAGE" ]] && log_info "Custom etcd: $ETCD_IMAGE"
        [[ -n "$COREDNS_IMAGE" ]] && log_info "Custom coredns: $COREDNS_IMAGE"
        [[ -n "$STORAGE_PROVISIONER_IMAGE" ]] && log_info "Custom storage-provisioner: $STORAGE_PROVISIONER_IMAGE"
    else
        log_info "No custom image configuration found, using defaults"
    fi
}

# Configure individual image URLs
configure_images() {
    log_info "Configuring individual image URLs..."
    echo "Enter full image URLs (including registry). Leave empty to use defaults from $DEFAULT_REGISTRY"
    echo
    
    read -p "kicbase image URL (for minikube VM): " KICBASE_IMAGE
    read -p "pause image URL: " PAUSE_IMAGE
    read -p "kube-apiserver image URL: " KUBE_APISERVER_IMAGE
    read -p "kube-controller-manager image URL: " KUBE_CONTROLLER_MANAGER_IMAGE
    read -p "kube-scheduler image URL: " KUBE_SCHEDULER_IMAGE
    read -p "kube-proxy image URL: " KUBE_PROXY_IMAGE
    read -p "etcd image URL: " ETCD_IMAGE
    read -p "coredns image URL: " COREDNS_IMAGE
    read -p "storage-provisioner image URL: " STORAGE_PROVISIONER_IMAGE
    
    # Save configuration
    local image_config="$CONFIG_DIR/images.conf"
    cat > "$image_config" << EOF
# Custom image configuration - $(date)
# Leave values empty to use defaults

# Minikube base image (for the VM itself)
KICBASE_IMAGE="$KICBASE_IMAGE"

# Kubernetes component images
PAUSE_IMAGE="$PAUSE_IMAGE"
KUBE_APISERVER_IMAGE="$KUBE_APISERVER_IMAGE"
KUBE_CONTROLLER_MANAGER_IMAGE="$KUBE_CONTROLLER_MANAGER_IMAGE"
KUBE_SCHEDULER_IMAGE="$KUBE_SCHEDULER_IMAGE"
KUBE_PROXY_IMAGE="$KUBE_PROXY_IMAGE"
ETCD_IMAGE="$ETCD_IMAGE"
COREDNS_IMAGE="$COREDNS_IMAGE"
STORAGE_PROVISIONER_IMAGE="$STORAGE_PROVISIONER_IMAGE"

# Default versions (used when custom URLs are not specified)
PAUSE_VERSION="$PAUSE_VERSION"
KUBE_VERSION="$KUBE_VERSION"
ETCD_VERSION="$ETCD_VERSION"
COREDNS_VERSION="$COREDNS_VERSION"
STORAGE_PROVISIONER_VERSION="$STORAGE_PROVISIONER_VERSION"
EOF
    
    log_success "Image configuration saved to $image_config"
    log_info "You can edit this file directly or run 'configure-images' again to modify"
}

# Get image URL with fallback logic
get_image_url() {
    local component=$1
    local custom_var="$2"
    local default_name="$3"
    local version="$4"
    
    # If custom URL is provided, use it
    if [[ -n "$custom_var" ]]; then
        echo "$custom_var"
        return 0
    fi
    
    # Otherwise use default registry
    echo "${DEFAULT_REGISTRY}/${default_name}:${version}"
}

# Find Windows Docker executable
find_windows_docker() {
    local docker_paths=(
        "/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"
        "/mnt/c/Program Files/Docker/Docker/resources/docker.exe"
        "/mnt/c/ProgramData/DockerDesktop/version-bin/docker.exe"
    )
    
    for path in "${docker_paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# Setup Windows Docker wrapper
setup_windows_docker() {
    log_info "Setting up Windows Docker.exe wrapper..."
    
    if ! is_wsl; then
        log_error "This script is designed for WSL environments only"
        exit 1
    fi
    
    local windows_docker_path
    if ! windows_docker_path=$(find_windows_docker); then
        log_error "Windows Docker.exe not found. Please install Docker Desktop on Windows."
        exit 1
    fi
    
    log_info "Found Windows Docker at: $windows_docker_path"
    
    # Create wrapper directory and script
    mkdir -p "$HOME/.local/bin"
    local docker_wrapper="$HOME/.local/bin/docker"
    
    cat > "$docker_wrapper" << EOF
#!/bin/bash
exec "$windows_docker_path" "\$@"
EOF
    
    chmod +x "$docker_wrapper"
    
    # Add to PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # Test Docker wrapper
    if "$docker_wrapper" version >/dev/null 2>&1; then
        log_success "Windows Docker wrapper configured successfully"
        "$docker_wrapper" version --format "Client: {{.Client.Version}}, Server: {{.Server.Version}}"
    else
        log_error "Docker wrapper test failed. Ensure Docker Desktop is running on Windows."
        exit 1
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install missing dependencies
install_dependencies() {
    log_info "Installing required dependencies..."
    
    local missing_deps=()
    for cmd in wget curl; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_info "Installing: ${missing_deps[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing_deps[@]}"
    fi
}

# Download and install binary
download_and_install() {
    local name=$1
    local urls=("${@:2}")
    local binary_name=""
    local temp_file="/tmp/${name}"
    
    # Determine binary name based on OS and architecture
    local os="linux"
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    
    if [[ "$name" == "minikube" ]]; then
        binary_name="minikube-${os}-${arch}"
        temp_file="/tmp/${binary_name}"
    else
        binary_name="$name"
    fi
    
    # Try downloading from each URL
    local download_success=false
    for url in "${urls[@]}"; do
        local full_url="${url}${binary_name}"
        log_info "Downloading $name from: $full_url"
        
        if wget --no-check-certificate --timeout=30 -O "$temp_file" "$full_url" 2>/dev/null || \
           curl --insecure --connect-timeout 30 -L -o "$temp_file" "$full_url" 2>/dev/null; then
            download_success=true
            break
        fi
    done
    
    if [[ "$download_success" != true ]] || [[ ! -s "$temp_file" ]]; then
        log_error "Failed to download $name"
        exit 1
    fi
    
    # Install binary
    chmod +x "$temp_file"
    sudo mv "$temp_file" "/usr/local/bin/$name"
    
    # Verify installation
    if "$name" version >/dev/null 2>&1 || "$name" version --client >/dev/null 2>&1; then
        log_success "$name installed successfully"
    else
        log_error "$name installation verification failed"
        exit 1
    fi
}

# Install minikube
install_minikube() {
    log_info "Installing Minikube..."
    
    local urls=(
        "https://github.com/kubernetes/minikube/releases/latest/download/"
        "https://storage.googleapis.com/minikube/releases/latest/"
    )
    
    download_and_install "minikube" "${urls[@]}"
    minikube version
}

# Install kubectl
install_kubectl() {
    log_info "Installing kubectl..."
    
    local version="$KUBECTL_VERSION"
    if [[ -z "$version" ]]; then
        version=$(wget --no-check-certificate -qO- "https://dl.k8s.io/release/stable.txt" 2>/dev/null || echo "v1.31.1")
    fi
    
    local os="linux"
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
    esac
    
    local urls=(
        "https://dl.k8s.io/release/${version}/bin/${os}/${arch}/"
        "https://storage.googleapis.com/kubernetes-release/release/${version}/bin/${os}/${arch}/"
    )
    
    download_and_install "kubectl" "${urls[@]}"
    kubectl version --client
}

# Pre-pull required images - simplified version
pre_pull_images() {
    log_info "Pre-pulling required Kubernetes images..."
    
    # Define basic images
    local images=(
        "registry.k8s.io/pause:3.9"
        "registry.k8s.io/kube-apiserver:v1.31.1"
        "registry.k8s.io/kube-controller-manager:v1.31.1"
        "registry.k8s.io/kube-scheduler:v1.31.1"
        "registry.k8s.io/kube-proxy:v1.31.1"
        "registry.k8s.io/etcd:3.5.15-0"
        "registry.k8s.io/coredns:v1.11.1"
        "gcr.io/k8s-minikube/storage-provisioner:v5"
    )
    
    local pull_failures=0
    local pull_successes=0
    
    for image in "${images[@]}"; do
        log_info "Pulling $image"
        if docker pull "$image" >/dev/null 2>&1; then
            log_success "Successfully pulled $image"
            ((pull_successes++))
        else
            log_warning "Failed to pull $image"
            ((pull_failures++))
        fi
    done
    
    log_info "Image pre-pull summary: $pull_successes successful, $pull_failures failed"
    return 0
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
    if minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_warning "Kubernetes cluster is already running"
        show_cluster_info
        return 0
    fi
    
    # Pre-pull images if Docker is accessible
    if command_exists docker && docker info >/dev/null 2>&1; then
        log_info "Docker is accessible, attempting to pre-pull images..."
        pre_pull_images || log_warning "Image pre-pulling encountered issues, but continuing"
    else
        log_warning "Docker not accessible, skipping image pre-pull"
    fi
    
    log_info "Proceeding with cluster start..."
    
    # Debug: Show minikube version
    log_info "Minikube version: $(minikube version --short 2>/dev/null || echo 'unknown')"
    
    # Create a simple start command without complex parameter handling
    log_info "Starting Kubernetes cluster with basic settings..."
    
    # Disable exit on error for minikube command
    set +e
    
    # Use a very basic minikube start command to avoid any parsing issues
    minikube start \
        --driver="$MINIKUBE_DRIVER" \
        --memory="$MINIKUBE_MEMORY" \
        --cpus="$MINIKUBE_CPUS" \
        --profile="$PROFILE_NAME"
    
    local start_status=$?
    
    # Re-enable exit on error
    set -e
    
    if [ $start_status -ne 0 ]; then
        log_error "Failed to start minikube cluster. Exit code: $start_status"
        return 1
    fi
    
    log_success "Basic cluster started successfully!"
    
    # Enable addons
    log_info "Enabling addons..."
    minikube addons enable dashboard -p "$PROFILE_NAME" || true
    minikube addons enable metrics-server -p "$PROFILE_NAME" || true
    
    log_success "Kubernetes cluster is ready!"
    show_cluster_info
}

# Stop minikube cluster
stop_minikube() {
    log_info "Stopping cluster..."
    
    if ! command_exists minikube; then
        log_error "Minikube is not installed"
        exit 1
    fi
    
    if minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        minikube stop -p "$PROFILE_NAME"
        log_success "Cluster stopped successfully!"
    else
        log_warning "Cluster is not running"
    fi
}

# Delete minikube cluster
delete_minikube() {
    log_info "Deleting cluster..."
    
    if ! command_exists minikube; then
        log_error "Minikube is not installed"
        exit 1
    fi
    
    read -p "Delete cluster '$PROFILE_NAME'? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        minikube delete -p "$PROFILE_NAME"
        log_success "Cluster deleted successfully!"
    else
        log_info "Deletion cancelled"
    fi
}

# Show cluster info - simplified
show_cluster_info() {
    log_info "Kubernetes cluster information:"
    minikube status -p "$PROFILE_NAME" || true
    
    log_info "Minikube IP:"
    minikube ip -p "$PROFILE_NAME" || true
    
    log_info "To use kubectl with this cluster, run:"
    echo "eval \$(minikube -p $PROFILE_NAME docker-env)"
    echo "kubectl get nodes"
}

# Run diagnostics
troubleshoot() {
    echo "=== Diagnostics ==="
    echo
    
    echo "WSL Environment: $(if is_wsl; then echo "Yes (${WSL_DISTRO_NAME:-Unknown})"; else echo "No"; fi)"
    echo
    
    echo "Docker Status:"
    if command_exists docker; then
        if docker info >/dev/null 2>&1; then
            echo "  ✓ Docker accessible"
            docker version --format "  Client: {{.Client.Version}}, Server: {{.Server.Version}}"
        else
            echo "  ✗ Docker not accessible"
        fi
    else
        echo "  ✗ Docker not installed"
    fi
    echo
    
    echo "Kubernetes Tools:"
    for tool in minikube kubectl; do
        if command_exists "$tool"; then
            echo "  ✓ $tool installed"
        else
            echo "  ✗ $tool not installed"
        fi
    done
    echo
    
    echo "Network Connectivity:"
    for endpoint in github.com registry.k8s.io europe-docker.pkg.dev; do
        if wget --spider --timeout=5 "https://$endpoint" 2>/dev/null; then
            echo "  ✓ $endpoint reachable"
        else
            echo "  ✗ $endpoint unreachable"
        fi
    done
    echo
    
    echo "Recommended Actions:"
    echo "1. Ensure Docker Desktop is running on Windows"
    echo "2. Run: $0 setup-docker (to configure Windows Docker wrapper)"
    echo "3. Run: $0 fresh-install (for complete setup)"
    echo
}

# Fresh installation
fresh_install() {
    log_info "Starting fresh installation..."
    
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run as root"
        exit 1
    fi
    
    if ! is_wsl; then
        log_error "This script is designed for WSL environments"
        exit 1
    fi
    
    # Setup Windows Docker
    setup_windows_docker
    
    # Install dependencies
    install_dependencies
    
    # Install tools
    install_minikube
    install_kubectl
    
    # Load image configuration
    load_image_config
    
    # Clean up any existing cluster
    if command_exists minikube && minikube status -p "$PROFILE_NAME" >/dev/null 2>&1; then
        log_warning "Removing existing cluster..."
        minikube delete -p "$PROFILE_NAME"
    fi
    
    # Start new cluster
    start_minikube
    
    log_success "Fresh installation completed!"
}

# Show help
show_help() {
    cat << EOF
Enterprise Kubernetes Local Cluster Management Tool for WSL

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    fresh-install    Complete installation and cluster setup
    setup-docker     Setup Windows Docker.exe wrapper for WSL
    configure-images Configure individual image URLs for Kubernetes components
    start           Start the Kubernetes cluster
    stop            Stop the Kubernetes cluster
    delete          Delete the Kubernetes cluster
    status          Show cluster status and information
    troubleshoot    Run diagnostics
    help            Show this help

OPTIONS:
    --memory MEMORY     Memory allocation in MB [default: 4096]
    --cpus CPUS        Number of CPUs [default: 2]
    --profile NAME     Cluster profile name [default: enterprise-k8s]
    --kicbase IMAGE    Custom kicbase image URL for minikube VM
    --pause IMAGE      Custom pause container image URL
    --apiserver IMAGE  Custom kube-apiserver image URL
    --scheduler IMAGE  Custom kube-scheduler image URL
    --controller IMAGE Custom kube-controller-manager image URL
    --proxy IMAGE      Custom kube-proxy image URL
    --etcd IMAGE       Custom etcd image URL
    --coredns IMAGE    Custom coredns image URL
    --storage IMAGE    Custom storage-provisioner image URL

EXAMPLES:
    $0 fresh-install                                     # Complete setup with defaults
    $0 configure-images                                  # Interactive image configuration
    $0 start --memory 8192 --cpus 4                     # Start with more resources
    $0 start --pause "my-registry.com/pause:3.9" --apiserver "my-registry.com/kube-apiserver:v1.31.1"
    $0 configure-images                                  # Interactive image configuration
    
CONFIGURATION FILES:
    ~/.local-cluster-cli/images.conf    # Custom image URLs
    ~/.local-cluster-cli/cluster.log    # Installation and runtime logs

INDIVIDUAL IMAGE OVERRIDE EXAMPLES:
    # Use custom images from your private registry
    $0 start \\
        --kicbase "my-registry.com/kicbase:v0.0.44" \\
        --pause "my-registry.com/pause:3.9" \\
        --apiserver "my-registry.com/kube-apiserver:v1.31.1" \\
        --scheduler "my-registry.com/kube-scheduler:v1.31.1" \\
        --controller "my-registry.com/kube-controller-manager:v1.31.1" \\
        --proxy "my-registry.com/kube-proxy:v1.31.1" \\
        --etcd "my-registry.com/etcd:3.5.15-0" \\
        --coredns "my-registry.com/coredns:v1.11.1" \\
        --storage "my-registry.com/storage-provisioner:v5"

DEFAULT IMAGES (when no custom URLs specified):
    kicbase: gcr.io/k8s-minikube/kicbase:latest
    All others: registry.k8s.io/[component]:[version]

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --memory)
                MINIKUBE_MEMORY="$2"
                shift 2
                ;;
            --cpus)
                MINIKUBE_CPUS="$2"
                shift 2
                ;;
            --profile)
                PROFILE_NAME="$2"
                shift 2
                ;;
            --kicbase)
                KICBASE_IMAGE="$2"
                shift 2
                ;;
            --pause)
                PAUSE_IMAGE="$2"
                shift 2
                ;;
            --apiserver)
                KUBE_APISERVER_IMAGE="$2"
                shift 2
                ;;
            --scheduler)
                KUBE_SCHEDULER_IMAGE="$2"
                shift 2
                ;;
            --controller)
                KUBE_CONTROLLER_MANAGER_IMAGE="$2"
                shift 2
                ;;
            --proxy)
                KUBE_PROXY_IMAGE="$2"
                shift 2
                ;;
            --etcd)
                ETCD_IMAGE="$2"
                shift 2
                ;;
            --coredns)
                COREDNS_IMAGE="$2"
                shift 2
                ;;
            --storage)
                STORAGE_PROVISIONER_IMAGE="$2"
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
    parse_args "$@"
    
    case $command in
        fresh-install)
            fresh_install
            ;;
        setup-docker)
            setup_windows_docker
            ;;
        configure-images)
            configure_images
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

# Run main function
main "$@"
