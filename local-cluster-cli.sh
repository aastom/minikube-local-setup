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
IMAGE_REPOSITORY="europe-docker.pkg.dev/mgmt-bak-bld-1d47/staging/ap/edh/a107595/images/platform-tools/registry.k8s.io"
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

# Default image versions
PAUSE_VERSION="3.9"
KUBE_VERSION="v1.31.1"
ETCD_VERSION="3.5.15-0"
COREDNS_VERSION="v1.11.1"

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

# Pre-pull required images
pre_pull_images() {
    log_info "Pre-pulling required Kubernetes images..."
    
    # Define images with their custom URLs or defaults
    local images=(
        "pause:$(get_image_url "pause" "$PAUSE_IMAGE" "pause" "$PAUSE_VERSION")"
        "kube-apiserver:$(get_image_url "apiserver" "$KUBE_APISERVER_IMAGE" "kube-apiserver" "$KUBE_VERSION")"
        "kube-controller-manager:$(get_image_url "controller-manager" "$KUBE_CONTROLLER_MANAGER_IMAGE" "kube-controller-manager" "$KUBE_VERSION")"
        "kube-scheduler:$(get_image_url "scheduler" "$KUBE_SCHEDULER_IMAGE" "kube-scheduler" "$KUBE_VERSION")"
        "kube-proxy:$(get_image_url "proxy" "$KUBE_PROXY_IMAGE" "kube-proxy" "$KUBE_VERSION")"
        "etcd:$(get_image_url "etcd" "$ETCD_IMAGE" "etcd" "$ETCD_VERSION")"
        "coredns:$(get_image_url "coredns" "$COREDNS_IMAGE" "coredns" "$COREDNS_VERSION")"
    )
    
    for image_spec in "${images[@]}"; do
        local component="${image_spec%%:*}"
        local image_url="${image_spec#*:}"
        
        log_info "Pulling $component: $image_url"
        
        if ! docker pull "$image_url" 2>/dev/null; then
            log_warning "Failed to pull $image_url, trying fallback registries"
            
            # Try alternative registries for standard images
            local base_image="${component}:${image_url##*:}"
            for alt_reg in "k8s.gcr.io" "gcr.io/k8s-minikube" "registry.k8s.io"; do
                local alt_image="${alt_reg}/${base_image}"
                log_info "Trying: $alt_image"
                if docker pull "$alt_image" 2>/dev/null; then
                    docker tag "$alt_image" "$image_url" 2>/dev/null || true
                    log_success "Tagged $alt_image as $image_url"
                    break
                fi
            done
        else
            log_success "Successfully pulled $image_url"
        fi
    done
}

# Start minikube cluster
start_minikube() {
    log_info "Starting Kubernetes cluster..."
    
    # Load custom image configuration
    load_image_config
    
    # Check if already running
    if command_exists minikube && minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_warning "Cluster is already running"
        show_cluster_info
        return 0
    fi
    
    # Pre-pull images
    if docker info >/dev/null 2>&1; then
        pre_pull_images
    else
        log_warning "Docker not accessible, skipping image pre-pull"
    fi
    
    # Build minikube start command
    local start_cmd="minikube start"
    start_cmd+=" --driver=$MINIKUBE_DRIVER"
    start_cmd+=" --memory=$MINIKUBE_MEMORY"
    start_cmd+=" --cpus=$MINIKUBE_CPUS"
    start_cmd+=" --disk-size=$MINIKUBE_DISK_SIZE"
    start_cmd+=" --profile=$PROFILE_NAME"
    start_cmd+=" --insecure-registry=\"$INSECURE_REGISTRIES\""
    start_cmd+=" --embed-certs=true"
    
    # Add custom kicbase image if specified
    if [[ -n "$KICBASE_IMAGE" ]]; then
        start_cmd+=" --base-image=\"$KICBASE_IMAGE\""
        log_info "Using custom kicbase image: $KICBASE_IMAGE"
    fi
    
    # Add image repository (will be overridden by individual images if specified)
    if [[ -n "$IMAGE_REPOSITORY" ]]; then
        start_cmd+=" --image-repository=\"$IMAGE_REPOSITORY\""
        log_info "Using base image repository: $IMAGE_REPOSITORY"
    fi
    
    # Add individual image overrides
    if [[ -n "$PAUSE_IMAGE" ]]; then
        start_cmd+=" --extra-config=kubelet.pod-infra-container-image=\"$PAUSE_IMAGE\""
        log_info "Using custom pause image: $PAUSE_IMAGE"
    fi
    
    # Add custom apiserver image
    if [[ -n "$KUBE_APISERVER_IMAGE" ]]; then
        start_cmd+=" --extra-config=apiserver.image=\"$KUBE_APISERVER_IMAGE\""
        log_info "Using custom apiserver image: $KUBE_APISERVER_IMAGE"
    fi
    
    # Add custom controller-manager image
    if [[ -n "$KUBE_CONTROLLER_MANAGER_IMAGE" ]]; then
        start_cmd+=" --extra-config=controller-manager.image=\"$KUBE_CONTROLLER_MANAGER_IMAGE\""
        log_info "Using custom controller-manager image: $KUBE_CONTROLLER_MANAGER_IMAGE"
    fi
    
    # Add custom scheduler image
    if [[ -n "$KUBE_SCHEDULER_IMAGE" ]]; then
        start_cmd+=" --extra-config=scheduler.image=\"$KUBE_SCHEDULER_IMAGE\""
        log_info "Using custom scheduler image: $KUBE_SCHEDULER_IMAGE"
    fi
    
    # Add custom etcd image
    if [[ -n "$ETCD_IMAGE" ]]; then
        start_cmd+=" --extra-config=etcd.image=\"$ETCD_IMAGE\""
        log_info "Using custom etcd image: $ETCD_IMAGE"
    fi
    
    # Start cluster with retry logic
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_info "Starting cluster (attempt $((retry_count + 1))/$max_retries)..."
        
        if eval "$start_cmd"; then
            log_success "Cluster started successfully!"
            break
        else
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "Start failed, cleaning up and retrying..."
                minikube delete -p "$PROFILE_NAME" 2>/dev/null || true
                sleep 10
            else
                log_error "Failed to start cluster after $max_retries attempts"
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
    done
    
    # Enable essential addons
    log_info "Enabling addons..."
    for addon in dashboard metrics-server ingress; do
        if minikube addons enable "$addon" -p "$PROFILE_NAME" 2>/dev/null; then
            log_success "Enabled $addon addon"
        else
            log_warning "Failed to enable $addon addon"
        fi
    done
    
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

# Show cluster information
show_cluster_info() {
    echo
    echo "=== Cluster Information ==="
    
    if command_exists minikube && minikube status -p "$PROFILE_NAME" >/dev/null 2>&1; then
        echo "Profile: $PROFILE_NAME"
        minikube status -p "$PROFILE_NAME"
        
        if minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
            echo
            echo "Cluster IP: $(minikube ip -p "$PROFILE_NAME" 2>/dev/null || echo 'Not available')"
            echo "Dashboard: minikube dashboard -p $PROFILE_NAME"
            echo
            echo "Quick commands:"
            echo "  kubectl get nodes"
            echo "  kubectl get pods -A"
            echo "  minikube logs -p $PROFILE_NAME"
        fi
    else
        echo "No cluster found"
    fi
    echo
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

EXAMPLES:
    $0 fresh-install                                     # Complete setup with defaults
    $0 configure-images                                  # Interactive image configuration
    $0 start --memory 8192 --cpus 4                     # Start with more resources
    $0 start --pause my-registry.com/pause:3.9          # Start with custom pause image
    $0 start --apiserver my-registry.com/kube-apiserver:v1.31.1 # Custom apiserver
    
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
        --coredns "my-registry.com/coredns:v1.11.1"

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