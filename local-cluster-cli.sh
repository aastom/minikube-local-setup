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

# Handle interruption signals for clean shutdown
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && $exit_code -ne 130 && $exit_code -ne 143 ]]; then
        log_warning "Script interrupted or failed (exit code: $exit_code)"
        log_info "Check logs at: $LOG_FILE"
        
        # If minikube start was in progress, suggest cleanup
        if pgrep -f "minikube start.*$PROFILE_NAME" >/dev/null 2>&1; then
            log_warning "Minikube start process detected, you may want to run:"
            log_info "  $0 delete  # to clean up partial installation"
        fi
    fi
}

# Set up signal handlers
trap cleanup_on_exit EXIT
trap 'echo; log_warning "Received interrupt signal, shutting down gracefully..."; exit 0' INT TERM

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

# Check minikube version and capabilities
check_minikube_version() {
    if ! command_exists minikube; then
        return 1
    fi
    
    local version_output
    version_output=$(minikube version --short 2>/dev/null || minikube version 2>/dev/null || echo "unknown")
    
    log_info "Detected minikube version: $version_output"
    
    # Extract version number for feature checks
    local version_number
    version_number=$(echo "$version_output" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/v//')
    
    if [[ -n "$version_number" ]]; then
        log_info "Minikube version: $version_number"
        
        # Check if version supports --pull-policy flag (introduced in v1.25.0)
        local major minor patch
        IFS='.' read -r major minor patch <<< "$version_number"
        
        if [[ $major -gt 1 ]] || [[ $major -eq 1 && $minor -gt 25 ]] || [[ $major -eq 1 && $minor -eq 25 && $patch -ge 0 ]]; then
            export MINIKUBE_SUPPORTS_PULL_POLICY=true
            log_info "This minikube version supports --pull-policy flag"
        else
            export MINIKUBE_SUPPORTS_PULL_POLICY=false
            log_info "This minikube version does not support --pull-policy flag"
        fi
    else
        export MINIKUBE_SUPPORTS_PULL_POLICY=false
        log_warning "Could not determine minikube version, assuming older version"
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

# Get minikube expected image tags
get_minikube_image_tags() {
    local component=$1
    local version=$2
    
    case $component in
        "pause")
            echo "registry.k8s.io/pause:${version}"
            ;;
        "kube-apiserver"|"kube-controller-manager"|"kube-scheduler"|"kube-proxy")
            echo "registry.k8s.io/${component}:${version}"
            ;;
        "etcd")
            echo "registry.k8s.io/etcd:${version}"
            ;;
        "coredns")
            echo "registry.k8s.io/coredns/coredns:${version}"
            ;;
        "storage-provisioner")
            echo "gcr.io/k8s-minikube/storage-provisioner:${version}"
            ;;
        *)
            echo "registry.k8s.io/${component}:${version}"
            ;;
    esac
}

# Pre-pull and tag images for minikube
pre_pull_and_tag_images() {
    log_info "Pre-pulling and tagging required Kubernetes images..."
    
    # Define image specifications: component_name|custom_image_var|default_component|default_version
    declare -A image_specs=(
        ["pause"]="PAUSE_IMAGE|pause|${PAUSE_VERSION}"
        ["kube-apiserver"]="KUBE_APISERVER_IMAGE|kube-apiserver|${KUBE_VERSION}"
        ["kube-controller-manager"]="KUBE_CONTROLLER_MANAGER_IMAGE|kube-controller-manager|${KUBE_VERSION}"
        ["kube-scheduler"]="KUBE_SCHEDULER_IMAGE|kube-scheduler|${KUBE_VERSION}"
        ["kube-proxy"]="KUBE_PROXY_IMAGE|kube-proxy|${KUBE_VERSION}"
        ["etcd"]="ETCD_IMAGE|etcd|${ETCD_VERSION}"
        ["coredns"]="COREDNS_IMAGE|coredns|${COREDNS_VERSION}"
        ["storage-provisioner"]="STORAGE_PROVISIONER_IMAGE|storage-provisioner|${STORAGE_PROVISIONER_VERSION}"
    )
    
    # Also pre-pull kicbase if specified (exact URL as provided)
    if [[ -n "$KICBASE_IMAGE" ]]; then
        log_info "Pre-pulling kicbase: $KICBASE_IMAGE"
        if timeout 300 docker pull "$KICBASE_IMAGE" 2>/dev/null; then
            log_success "Successfully pre-pulled kicbase: $KICBASE_IMAGE"
        else
            log_warning "Failed to pull kicbase image: $KICBASE_IMAGE (timeout or error)"
            log_info "Minikube will attempt to download it during cluster start"
        fi
    fi
    
    local pull_failures=0
    local pull_successes=0
    local tag_successes=0
    local total_images=${#image_specs[@]}
    local current_image=0
    
    for component in "${!image_specs[@]}"; do
        ((current_image++))
        log_info "Processing image $current_image/$total_images: $component"
        
        IFS='|' read -r custom_var default_component default_version <<< "${image_specs[$component]}"
        
        # Get the custom image URL using indirect variable reference
        local custom_image_url="${!custom_var}"
        
        # Determine source image URL - use exact custom URL if provided
        local source_image
        if [[ -n "$custom_image_url" ]]; then
            source_image="$custom_image_url"
            log_info "  Using custom image: $source_image"
        else
            source_image="${DEFAULT_REGISTRY}/${default_component}:${default_version}"
            log_info "  Using default image: $source_image"
        fi
        
        # Get expected minikube tag (what minikube expects to find locally)
        local minikube_tag
        minikube_tag=$(get_minikube_image_tags "$component" "$default_version")
        
        # Pull the exact image URL as specified with timeout
        log_info "  Pulling: $source_image"
        if timeout 300 docker pull "$source_image" 2>/dev/null; then
            log_success "  Successfully pulled: $source_image"
            ((pull_successes++))
            
            # Tag for minikube if different from source
            if [[ "$source_image" != "$minikube_tag" ]]; then
                log_info "  Tagging as: $minikube_tag"
                if docker tag "$source_image" "$minikube_tag" 2>/dev/null; then
                    log_success "  Tagged successfully"
                    ((tag_successes++))
                else
                    log_warning "  Failed to tag $source_image as $minikube_tag"
                fi
            else
                log_info "  Image already has correct tag for minikube"
                ((tag_successes++))
            fi
        else
            log_warning "  Failed to pull: $source_image (timeout or error)"
            
            # Only try fallback registries if using default images (not custom URLs)
            if [[ -z "$custom_image_url" ]]; then
                log_info "  Trying fallback registries for default image..."
                local fallback_success=false
                
                local fallback_registries=("k8s.gcr.io" "gcr.io/k8s-minikube")
                for alt_reg in "${fallback_registries[@]}"; do
                    local alt_image="${alt_reg}/${default_component}:${default_version}"
                    log_info "  Trying fallback: $alt_image"
                    if timeout 180 docker pull "$alt_image" 2>/dev/null; then
                        log_success "  Fallback pull successful: $alt_image"
                        if docker tag "$alt_image" "$minikube_tag" 2>/dev/null; then
                            log_success "  Tagged fallback as: $minikube_tag"
                            fallback_success=true
                            ((pull_successes++))
                            ((tag_successes++))
                            break
                        else
                            log_warning "  Failed to tag $alt_image as $minikube_tag"
                        fi
                    else
                        log_info "  Fallback failed: $alt_image"
                    fi
                done
                
                if [[ "$fallback_success" != true ]]; then
                    log_warning "  All fallback attempts failed for $component"
                    ((pull_failures++))
                fi
            else
                log_warning "  Custom image URL failed, no fallback attempted"
                log_info "  Please verify the custom image URL: $custom_image_url"
                ((pull_failures++))
            fi
        fi
        
        # Progress indicator
        log_info "  Progress: $current_image/$total_images images processed"
        echo
    done
    
    echo "========================================"
    log_info "Image processing completed!"
    log_info "  Total images processed: $total_images"
    log_info "  Successful pulls: $pull_successes"
    log_info "  Failed pulls: $pull_failures"
    log_info "  Successful tags: $tag_successes"
    echo "========================================"
    
    if [[ $pull_failures -gt 0 ]]; then
        log_warning "Some images failed to pre-pull, but continuing with cluster start"
        log_info "Minikube will attempt to download missing images during startup"
    else
        log_success "All images successfully pulled and tagged!"
    fi
    
    # Save image manifest for minikube
    save_image_manifest
    
    return 0
}

# Load images into minikube's Docker daemon
load_images_into_minikube() {
    log_info "Loading images into minikube's Docker daemon..."
    
    if ! command_exists minikube; then
        log_error "Minikube is not installed"
        return 1
    fi
    
    # Check if cluster is running
    if ! minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_error "Minikube cluster is not running"
        return 1
    fi
    
    # Define images that should be loaded into minikube
    local images_to_load=(
        "registry.k8s.io/pause:${PAUSE_VERSION}"
        "registry.k8s.io/kube-apiserver:${KUBE_VERSION}"
        "registry.k8s.io/kube-controller-manager:${KUBE_VERSION}"
        "registry.k8s.io/kube-scheduler:${KUBE_VERSION}"
        "registry.k8s.io/kube-proxy:${KUBE_VERSION}"
        "registry.k8s.io/etcd:${ETCD_VERSION}"
        "registry.k8s.io/coredns/coredns:${COREDNS_VERSION}"
        "gcr.io/k8s-minikube/storage-provisioner:${STORAGE_PROVISIONER_VERSION}"
    )
    
    # Also load kicbase if we pulled a custom one
    if [[ -n "$KICBASE_IMAGE" ]]; then
        images_to_load+=("$KICBASE_IMAGE")
    fi
    
    local loaded_count=0
    local failed_count=0
    local total_images=${#images_to_load[@]}
    
    for image in "${images_to_load[@]}"; do
        log_info "Loading image into minikube: $image"
        
        # Check if image exists locally first
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            log_warning "Image not found locally, skipping: $image"
            ((failed_count++))
            continue
        fi
        
        # Load image into minikube
        if minikube image load "$image" -p "$PROFILE_NAME" 2>/dev/null; then
            log_success "Successfully loaded: $image"
            ((loaded_count++))
        else
            log_warning "Failed to load: $image"
            ((failed_count++))
        fi
    done
    
    echo "========================================"
    log_info "Image loading summary:"
    log_info "  Total images: $total_images"
    log_info "  Successfully loaded: $loaded_count"
    log_info "  Failed/Skipped: $failed_count"
    echo "========================================"
    
    if [[ $loaded_count -gt 0 ]]; then
        log_success "Images loaded into minikube successfully!"
        
        # Verify images are available in minikube
        log_info "Verifying images in minikube..."
        minikube ssh -p "$PROFILE_NAME" -- "docker images --format 'table {{.Repository}}:{{.Tag}}' | grep -E '(registry\.k8s\.io|gcr\.io)'" 2>/dev/null || true
    fi
    
    return 0
}

# Alternative method: Use minikube's Docker daemon directly
use_minikube_docker_daemon() {
    log_info "Configuring to use minikube's Docker daemon..."
    
    if ! command_exists minikube; then
        log_error "Minikube is not installed"
        return 1
    fi
    
    # Check if cluster is running
    if ! minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_error "Minikube cluster is not running"
        return 1
    fi
    
    # Get minikube docker-env
    log_info "Switching to minikube's Docker daemon..."
    
    # Export minikube docker environment
    eval $(minikube docker-env -p "$PROFILE_NAME")
    
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        log_success "Successfully switched to minikube's Docker daemon"
        log_info "Docker host: ${DOCKER_HOST}"
        
        # Now pull/tag images directly in minikube's Docker daemon
        log_info "Pulling images directly into minikube's Docker daemon..."
        pre_pull_and_tag_images
        
        return 0
    else
        log_error "Failed to switch to minikube's Docker daemon"
        return 1
    fi
}

# Configure minikube to use local images
configure_minikube_local_images() {
    log_info "Configuring minikube to prefer local images..."
    
    # Set minikube to use local docker daemon and prefer local images
    minikube config set driver "$MINIKUBE_DRIVER" -p "$PROFILE_NAME" 2>/dev/null || true
    minikube config set image-mirror-country "" -p "$PROFILE_NAME" 2>/dev/null || true
    minikube config set image-repository "" -p "$PROFILE_NAME" 2>/dev/null || true
    
    # Configure environment to skip pulling if images exist locally
    # This works with older minikube versions
    export MINIKUBE_PULL_POLICY="IfNotPresent"
    export MINIKUBE_IMAGE_PULL_POLICY="IfNotPresent"
    
    # For Docker driver, ensure we're using the same Docker daemon
    if [[ "$MINIKUBE_DRIVER" == "docker" ]]; then
        log_info "Configuring Docker driver for local image access..."
        # The docker driver shares the host docker daemon, so local images should be available
    fi
    
    log_success "Minikube configured to prefer local images"
}

# Start minikube cluster
start_minikube() {
    log_info "Starting Kubernetes cluster..."
    
    # Load custom image configuration
    load_image_config
    
    # Check if already running
    if command_exists minikube && minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_success "Cluster is already running!"
        show_cluster_info
        return 0
    fi
    
    # Quick connectivity check
    log_info "Checking connectivity..."
    if ! wget --spider --timeout=10 "https://github.com" 2>/dev/null; then
        log_warning "Internet connectivity issues detected"
        log_info "Some operations may fail or take longer"
    fi
    
    # Check if Docker is accessible and try to pre-pull images
    if docker info >/dev/null 2>&1; then
        log_info "Docker is accessible, processing images..."
        configure_minikube_local_images
        
        # For Docker driver, we'll load images after cluster starts
        if [[ "$MINIKUBE_DRIVER" == "docker" ]]; then
            log_info "Docker driver detected - images will be loaded after cluster starts"
            
            # Only pre-pull if we have custom images or this is a fresh install
            if [[ -n "$KICBASE_IMAGE$PAUSE_IMAGE$KUBE_APISERVER_IMAGE$KUBE_CONTROLLER_MANAGER_IMAGE$KUBE_SCHEDULER_IMAGE$KUBE_PROXY_IMAGE$ETCD_IMAGE$COREDNS_IMAGE$STORAGE_PROVISIONER_IMAGE" ]] || [[ ! -f "$CONFIG_DIR/image-manifest.txt" ]]; then
                log_info "Pre-pulling images to host Docker daemon..."
                pre_pull_and_tag_images
            else
                log_info "Using existing image cache, skipping pre-pull"
            fi
        else
            # For other drivers, pre-pull and tag as before
            if [[ -n "$KICBASE_IMAGE$PAUSE_IMAGE$KUBE_APISERVER_IMAGE$KUBE_CONTROLLER_MANAGER_IMAGE$KUBE_SCHEDULER_IMAGE$KUBE_PROXY_IMAGE$ETCD_IMAGE$COREDNS_IMAGE$STORAGE_PROVISIONER_IMAGE" ]] || [[ ! -f "$CONFIG_DIR/image-manifest.txt" ]]; then
                pre_pull_and_tag_images
            else
                log_info "Using existing image cache, skipping pre-pull"
                log_info "Use 'clean-images' command to force re-download"
            fi
        fi
    else
        log_warning "Docker not accessible, skipping image pre-pull"
        log_info "Images will be downloaded during cluster start"
    fi
    
    log_info "Proceeding with cluster start..."
    
    # Check minikube version and capabilities
    check_minikube_version
    
    # Build minikube start command
    local start_args=(
        "--driver=$MINIKUBE_DRIVER"
        "--memory=$MINIKUBE_MEMORY"
        "--cpus=$MINIKUBE_CPUS"
        "--disk-size=$MINIKUBE_DISK_SIZE"
        "--profile=$PROFILE_NAME"
        "--insecure-registry=$INSECURE_REGISTRIES"
        "--embed-certs=true"
        "--delete-on-failure"
    )
    
    # Add pull policy flag only if supported
    if [[ "${MINIKUBE_SUPPORTS_PULL_POLICY:-false}" == "true" ]]; then
        start_args+=("--pull-policy=IfNotPresent")
        log_info "Added --pull-policy=IfNotPresent flag"
    else
        log_info "Using environment variables for pull policy (older minikube version)"
    fi
    
    # Add custom kicbase image if specified
    if [[ -n "$KICBASE_IMAGE" ]]; then
        start_args+=("--base-image=$KICBASE_IMAGE")
        log_info "Using custom kicbase image: $KICBASE_IMAGE"
    fi
    
    # Add individual image overrides with validation
    local image_overrides_count=0
    
    if [[ -n "$PAUSE_IMAGE" ]]; then
        start_args+=("--extra-config=kubelet.pod-infra-container-image=$PAUSE_IMAGE")
        log_info "Using custom pause image: $PAUSE_IMAGE"
        ((image_overrides_count++))
    fi
    
    if [[ -n "$KUBE_APISERVER_IMAGE" ]]; then
        start_args+=("--extra-config=apiserver.image=$KUBE_APISERVER_IMAGE")
        log_info "Using custom apiserver image: $KUBE_APISERVER_IMAGE"
        ((image_overrides_count++))
    fi
    
    if [[ -n "$KUBE_CONTROLLER_MANAGER_IMAGE" ]]; then
        start_args+=("--extra-config=controller-manager.image=$KUBE_CONTROLLER_MANAGER_IMAGE")
        log_info "Using custom controller-manager image: $KUBE_CONTROLLER_MANAGER_IMAGE"
        ((image_overrides_count++))
    fi
    
    if [[ -n "$KUBE_SCHEDULER_IMAGE" ]]; then
        start_args+=("--extra-config=scheduler.image=$KUBE_SCHEDULER_IMAGE")
        log_info "Using custom scheduler image: $KUBE_SCHEDULER_IMAGE"
        ((image_overrides_count++))
    fi
    
    if [[ -n "$ETCD_IMAGE" ]]; then
        start_args+=("--extra-config=etcd.image=$ETCD_IMAGE")
        log_info "Using custom etcd image: $ETCD_IMAGE"
        ((image_overrides_count++))
    fi
    
    log_info "=== STARTING MINIKUBE CLUSTER ==="
    log_info "Profile: $PROFILE_NAME"
    log_info "Driver: $MINIKUBE_DRIVER"
    log_info "Memory: ${MINIKUBE_MEMORY}MB"
    log_info "CPUs: $MINIKUBE_CPUS"
    log_info "Image overrides: $image_overrides_count"
    
    # Start cluster with retry logic
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_info "=== CLUSTER START ATTEMPT $((retry_count + 1))/$max_retries ==="
        
        # Set timeout for minikube start
        local start_timeout=900  # 15 minutes
        
        set +e  # Temporarily disable exit on error
        log_info "Starting minikube with timeout of ${start_timeout} seconds..."
        
        # Use timeout command to prevent hanging
        timeout $start_timeout minikube start "${start_args[@]}"
        local start_exit_code=$?
        set -e  # Re-enable exit on error
        
        if [[ $start_exit_code -eq 0 ]]; then
            log_success "Cluster started successfully!"
            break
        elif [[ $start_exit_code -eq 124 ]]; then
            log_error "Minikube start timed out after ${start_timeout} seconds"
            ((retry_count++))
        else
            log_error "Minikube start failed with exit code: $start_exit_code"
            ((retry_count++))
        fi
        
        if [[ $retry_count -lt $max_retries ]]; then
            log_warning "Cleaning up failed cluster and retrying in 10 seconds..."
            
            # Force cleanup with timeout
            timeout 60 minikube delete -p "$PROFILE_NAME" 2>/dev/null || {
                log_warning "Cleanup timed out, forcing docker cleanup..."
                docker ps -a --filter "name=$PROFILE_NAME" --format "{{.ID}}" | xargs -r docker rm -f 2>/dev/null || true
            }
            
            sleep 10
        else
            log_error "Failed to start cluster after $max_retries attempts"
            log_error "Final exit code: $start_exit_code"
            
            echo "========================================"
            log_error "TROUBLESHOOTING INFORMATION:"
            echo "========================================"
            log_info "1. Check minikube logs: minikube logs -p $PROFILE_NAME"
            log_info "2. Try manual start: minikube start --profile $PROFILE_NAME --driver $MINIKUBE_DRIVER --v=3"
            log_info "3. Check Docker status: docker info"
            log_info "4. Run diagnostics: $0 troubleshoot"
            log_info "5. Clean and retry: $0 delete && $0 start"
            echo "========================================"
            
            return 1
        fi
    done
    
    # Wait for cluster to be ready
    echo "========================================"
    log_info "Waiting for cluster to be ready..."
    echo "========================================"
    
    local ready_retry=0
    local max_ready_retries=60
    local ready_success=false
    
    while [[ $ready_retry -lt $max_ready_retries ]]; do
        log_info "Checking cluster readiness... (attempt $((ready_retry + 1))/$max_ready_retries)"
        
        if timeout 30 kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then
            log_success "Cluster is ready!"
            ready_success=true
            break
        else
            log_info "Cluster not ready yet, waiting 5 seconds..."
            sleep 5
            ((ready_retry++))
        fi
    done
    
    if [[ "$ready_success" != true ]]; then
        log_warning "Cluster readiness check timed out, but continuing..."
        log_info "You can check cluster status later with: kubectl get nodes"
    fi
    
    # Configure post-startup components
    echo "========================================"
    log_info "Configuring cluster components..."
    echo "========================================"
    configure_post_startup_components
    
    echo "========================================"
    log_success "Cluster setup completed!"
    echo "========================================"
    show_cluster_info
}

# Save image manifest to prevent remote pulls
save_image_manifest() {
    local manifest_file="$CONFIG_DIR/image-manifest.txt"
    log_info "Saving local image manifest to $manifest_file"
    
    # List all locally available Kubernetes images
    docker images --format "table {{.Repository}}:{{.Tag}}" | grep -E "(registry\.k8s\.io|gcr\.io|k8s\.gcr\.io)" > "$manifest_file" 2>/dev/null || true
    
    if [[ -s "$manifest_file" ]]; then
        log_success "Image manifest saved with $(wc -l < "$manifest_file") images"
        log_info "Local images will be preferred during cluster start"
    else
        log_warning "No Kubernetes images found locally"
    fi
}

# Configure components that need post-startup configuration
configure_post_startup_components() {
    log_info "Configuring post-startup components..."
    
    # Load images into minikube's Docker daemon if using Docker driver
    if [[ "$MINIKUBE_DRIVER" == "docker" ]]; then
        echo "========================================"
        log_info "Loading images into minikube's Docker daemon..."
        echo "========================================"
        load_images_into_minikube
    fi
    
    # Enable essential addons
    log_info "Enabling addons..."
    for addon in dashboard metrics-server ingress; do
        if minikube addons enable "$addon" -p "$PROFILE_NAME" 2>/dev/null; then
            log_success "Enabled $addon addon"
        else
            log_warning "Failed to enable $addon addon"
        fi
    done
    
    # Configure storage-provisioner with custom image if specified
    if [[ -n "$STORAGE_PROVISIONER_IMAGE" ]]; then
        log_info "Configuring custom storage-provisioner image..."
        
        if minikube addons enable storage-provisioner -p "$PROFILE_NAME" 2>/dev/null; then
            log_success "Enabled storage-provisioner addon"
            sleep 5
            
            if kubectl patch deployment storage-provisioner -n kube-system -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"storage-provisioner\",\"image\":\"$STORAGE_PROVISIONER_IMAGE\"}]}}}}" 2>/dev/null; then
                log_success "Updated storage-provisioner to use custom image: $STORAGE_PROVISIONER_IMAGE"
            else
                log_warning "Failed to update storage-provisioner image, using default"
            fi
        else
            log_warning "Failed to enable storage-provisioner addon"
        fi
    else
        if minikube addons enable storage-provisioner -p "$PROFILE_NAME" 2>/dev/null; then
            log_success "Enabled storage-provisioner addon"
        fi
    fi
    
    # Configure CoreDNS with custom image if specified
    if [[ -n "$COREDNS_IMAGE" ]]; then
        log_info "Configuring custom CoreDNS image..."
        sleep 5
        
        if kubectl patch deployment coredns -n kube-system -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"coredns\",\"image\":\"$COREDNS_IMAGE\"}]}}}}" 2>/dev/null; then
            log_success "Updated CoreDNS to use custom image: $COREDNS_IMAGE"
        else
            log_warning "Failed to update CoreDNS image, using default"
        fi
    fi
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
        
        # Clean up saved manifests
        rm -f "$CONFIG_DIR/image-manifest.txt"
        log_info "Cleaned up local image manifests"
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
            echo
            echo "Local images status:"
            local manifest_file="$CONFIG_DIR/image-manifest.txt"
            if [[ -f "$manifest_file" ]]; then
                echo "  $(wc -l < "$manifest_file") Kubernetes images cached locally"
            else
                echo "  No local image cache found"
            fi
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
            echo "  Local K8s images: $(docker images --format "table {{.Repository}}:{{.Tag}}" | grep -E "(registry\.k8s\.io|gcr\.io|k8s\.gcr\.io)" | wc -l)"
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
            echo "  ✓ $tool installed ($(${tool} version --short 2>/dev/null || ${tool} version --client --short 2>/dev/null || echo 'version unknown'))"
        else
            echo "  ✗ $tool not installed"
        fi
    done
    echo
    
    echo "Configuration:"
    echo "  Config dir: $CONFIG_DIR"
    echo "  Log file: $LOG_FILE"
    echo "  Image config: $(if [[ -f "$CONFIG_DIR/images.conf" ]]; then echo "Present"; else echo "Not found"; fi)"
    echo "  Image manifest: $(if [[ -f "$CONFIG_DIR/image-manifest.txt" ]]; then echo "Present ($(wc -l < "$CONFIG_DIR/image-manifest.txt") images)"; else echo "Not found"; fi)"
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
    
    echo "Cluster Status:"
    if command_exists minikube; then
        if minikube status -p "$PROFILE_NAME" >/dev/null 2>&1; then
            echo "  Profile '$PROFILE_NAME' exists"
            minikube status -p "$PROFILE_NAME" | sed 's/^/    /'
        else
            echo "  No cluster found with profile '$PROFILE_NAME'"
        fi
    else
        echo "  Minikube not available"
    fi
    echo
    
    echo "Recommended Actions:"
    echo "1. Ensure Docker Desktop is running on Windows"
    echo "2. Run: $0 setup-docker (to configure Windows Docker wrapper)"
    echo "3. Run: $0 fresh-install (for complete setup)"
    echo "4. Run: $0 configure-images (to set custom image URLs)"
    echo
}

# Clean up local images
clean_images() {
    log_info "Cleaning up local Kubernetes images..."
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker not accessible"
        exit 1
    fi
    
    read -p "Remove all local Kubernetes images? This will force re-download on next start (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Remove Kubernetes images
        local removed_count=0
        for image in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "(registry\.k8s\.io|gcr\.io|k8s\.gcr\.io)"); do
            if docker rmi "$image" 2>/dev/null; then
                log_info "Removed: $image"
                ((removed_count++))
            fi
        done
        
        # Clean up manifests
        rm -f "$CONFIG_DIR/image-manifest.txt"
        
        log_success "Removed $removed_count Kubernetes images and cleaned up manifests"
    else
        log_info "Cleanup cancelled"
    fi
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
    
    # Create lock file to prevent multiple instances
    local lock_file="$CONFIG_DIR/.fresh_install.lock"
    if [[ -f "$lock_file" ]]; then
        local lock_pid=$(cat "$lock_file" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another fresh-install process is already running (PID: $lock_pid)"
            log_info "If this is incorrect, remove: $lock_file"
            exit 1
        else
            log_info "Removing stale lock file"
            rm -f "$lock_file"
        fi
    fi
    
    # Create lock file with current PID
    echo $ > "$lock_file"
    
    # Ensure lock file is removed on exit
    trap 'rm -f "$lock_file"; cleanup_on_exit' EXIT
    
    echo "========================================"
    log_info "PHASE 1: Setting up Docker"
    echo "========================================"
    
    # Setup Windows Docker
    if ! setup_windows_docker; then
        log_error "Failed to setup Windows Docker"
        exit 1
    fi
    
    echo "========================================"
    log_info "PHASE 2: Installing dependencies"
    echo "========================================"
    
    # Install dependencies
    if ! install_dependencies; then
        log_error "Failed to install dependencies"
        exit 1
    fi
    
    echo "========================================"
    log_info "PHASE 3: Installing Kubernetes tools"
    echo "========================================"
    
    # Install tools
    if ! install_minikube; then
        log_error "Failed to install minikube"
        exit 1
    fi
    
    if ! install_kubectl; then
        log_error "Failed to install kubectl"
        exit 1
    fi
    
    echo "========================================"
    log_info "PHASE 4: Loading configuration"
    echo "========================================"
    
    # Load image configuration
    load_image_config
    
    echo "========================================"
    log_info "PHASE 5: Cleaning up existing cluster"
    echo "========================================"
    
    # Clean up any existing cluster
    if command_exists minikube && minikube status -p "$PROFILE_NAME" >/dev/null 2>&1; then
        log_warning "Removing existing cluster..."
        if ! minikube delete -p "$PROFILE_NAME"; then
            log_warning "Failed to delete existing cluster cleanly, forcing cleanup..."
            # Force cleanup
            docker ps -a --filter "name=$PROFILE_NAME" --format "{{.ID}}" | xargs -r docker rm -f 2>/dev/null || true
            docker network rm "$PROFILE_NAME" 2>/dev/null || true
        fi
        sleep 5
    fi
    
    echo "========================================"
    log_info "PHASE 6: Starting new cluster"
    echo "========================================"
    
    # Start new cluster
    if ! start_minikube; then
        log_error "Failed to start minikube cluster"
        exit 1
    fi
    
    # Remove lock file on successful completion
    rm -f "$lock_file"
    
    echo "========================================"
    log_success "Fresh installation completed successfully!"
    echo "========================================"
    
    # Show final status
    show_cluster_info
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
    clean-images    Remove local Kubernetes images
    load-images     Load locally pulled images into running minikube cluster
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
    $0 start --pause "my-registry.com/pause:3.9" \\
             --apiserver "my-registry.com/kube-apiserver:v1.31.1"
    $0 clean-images                                      # Remove cached images
    $0 troubleshoot                                      # Run full diagnostics
    
CONFIGURATION FILES:
    ~/.local-cluster-cli/images.conf        # Custom image URLs
    ~/.local-cluster-cli/cluster.log        # Installation and runtime logs
    ~/.local-cluster-cli/image-manifest.txt # Local image cache manifest

CUSTOM IMAGE BEHAVIOR:
    - Custom image URLs are pulled EXACTLY as specified (full URL with tag)
    - Images are then tagged with names that minikube expects locally
    - Fallback registries are ONLY used for default images, not custom URLs
    - If a custom image URL fails, no fallback is attempted

INDIVIDUAL IMAGE OVERRIDE EXAMPLES:
    # Use exact custom images from your private registry
    $0 start \\
        --kicbase "my-registry.com/minikube/kicbase:v0.0.44" \\
        --pause "my-registry.com/k8s/pause:3.9" \\
        --apiserver "my-registry.com/k8s/kube-apiserver:v1.31.1" \\
        --scheduler "my-registry.com/k8s/kube-scheduler:v1.31.1" \\
        --controller "my-registry.com/k8s/kube-controller-manager:v1.31.1" \\
        --proxy "my-registry.com/k8s/kube-proxy:v1.31.1" \\
        --etcd "my-registry.com/k8s/etcd:3.5.15-0" \\
        --coredns "my-registry.com/k8s/coredns:v1.11.1" \\
        --storage "my-registry.com/minikube/storage-provisioner:v5"
    
    # Mix custom and default images
    $0 start \\
        --pause "harbor.company.com/k8s/pause:3.9" \\
        --apiserver "quay.io/custom/kube-apiserver:v1.31.1"
        # Other components will use registry.k8s.io defaults

DEFAULT IMAGES (when no custom URLs specified):
    kicbase: gcr.io/k8s-minikube/kicbase:latest
    All others: registry.k8s.io/[component]:[version]

FEATURES:
    ✓ Automatic image pre-pulling and tagging for offline use
    ✓ Intelligent fallback to alternative registries
    ✓ Local image caching to prevent unnecessary downloads
    ✓ Support for custom private registries
    ✓ Comprehensive diagnostics and troubleshooting
    ✓ WSL + Windows Docker Desktop integration

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
    # Check if another instance is running
    local main_lock_file="$CONFIG_DIR/.script.lock"
    if [[ -f "$main_lock_file" ]]; then
        local lock_pid=$(cat "$main_lock_file" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another instance of this script is already running (PID: $lock_pid)"
            log_info "If this is incorrect, remove: $main_lock_file"
            exit 1
        else
            rm -f "$main_lock_file"
        fi
    fi
    
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    
    local command=$1
    shift
    
    # Validate command before processing
    case $command in
        fresh-install|setup-docker|configure-images|start|stop|delete|status|troubleshoot|clean-images|load-images|help|--help|-h)
            # Valid command, continue
            ;;
        *)
            log_error "Unknown command: $command"
            echo
            show_help
            exit 1
            ;;
    esac
    
    # Create main lock file for most operations (except help and status)
    if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" && "$command" != "status" && "$command" != "troubleshoot" ]]; then
        echo $ > "$main_lock_file"
        trap 'rm -f "$main_lock_file"; cleanup_on_exit' EXIT
    fi
    
    # Parse arguments after command validation
    parse_args "$@"
    
    # Execute command with error handling
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
        clean-images)
            clean_images
            ;;
        load-images)
            load_image_config
            load_images_into_minikube
            ;;
        help|--help|-h)
            show_help
            ;;
    esac
    
    # Remove lock file on successful completion
    rm -f "$main_lock_file" 2>/dev/null || true
}

# Run main function with all arguments
main "$@"