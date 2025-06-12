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
    
    # Define image mappings: component:custom_url:default_component:version
    local image_mappings=(
        "pause:${PAUSE_IMAGE}:pause:${PAUSE_VERSION}"
        "kube-apiserver:${KUBE_APISERVER_IMAGE}:kube-apiserver:${KUBE_VERSION}"
        "kube-controller-manager:${KUBE_CONTROLLER_MANAGER_IMAGE}:kube-controller-manager:${KUBE_VERSION}"
        "kube-scheduler:${KUBE_SCHEDULER_IMAGE}:kube-scheduler:${KUBE_VERSION}"
        "kube-proxy:${KUBE_PROXY_IMAGE}:kube-proxy:${KUBE_VERSION}"
        "etcd:${ETCD_IMAGE}:etcd:${ETCD_VERSION}"
        "coredns:${COREDNS_IMAGE}:coredns:${COREDNS_VERSION}"
        "storage-provisioner:${STORAGE_PROVISIONER_IMAGE}:storage-provisioner:${STORAGE_PROVISIONER_VERSION}"
    )
    
    # Also pre-pull kicbase if specified
    if [[ -n "$KICBASE_IMAGE" ]]; then
        log_info "Pre-pulling kicbase: $KICBASE_IMAGE"
        if docker pull "$KICBASE_IMAGE" 2>/dev/null; then
            log_success "Successfully pre-pulled kicbase: $KICBASE_IMAGE"
        else
            log_warning "Failed to pull kicbase image: $KICBASE_IMAGE"
            log_info "Minikube will attempt to download it during cluster start"
        fi
    fi
    
    local pull_failures=0
    local pull_successes=0
    local tag_successes=0
    
    for mapping in "${image_mappings[@]}"; do
        IFS=':' read -r component custom_url default_component version <<< "$mapping"
        
        # Determine source image URL
        local source_image
        if [[ -n "$custom_url" ]]; then
            source_image="$custom_url"
        else
            source_image="${DEFAULT_REGISTRY}/${default_component}:${version}"
        fi
        
        # Get expected minikube tag
        local minikube_tag
        minikube_tag=$(get_minikube_image_tags "$component" "$version")
        
        log_info "Processing $component: $source_image"
        
        # Pull the image
        if docker pull "$source_image" 2>/dev/null; then
            log_success "Successfully pulled $source_image"
            ((pull_successes++))
            
            # Tag for minikube if different from source
            if [[ "$source_image" != "$minikube_tag" ]]; then
                if docker tag "$source_image" "$minikube_tag" 2>/dev/null; then
                    log_success "Tagged as $minikube_tag"
                    ((tag_successes++))
                else
                    log_warning "Failed to tag $source_image as $minikube_tag"
                fi
            else
                log_info "Image already has correct tag for minikube"
                ((tag_successes++))
            fi
        else
            log_warning "Failed to pull $source_image, trying fallback registries"
            
            # Try alternative registries for standard images
            local fallback_success=false
            
            for alt_reg in "k8s.gcr.io" "gcr.io/k8s-minikube"; do
                local alt_image="${alt_reg}/${default_component}:${version}"
                log_info "Trying fallback: $alt_image"
                if docker pull "$alt_image" 2>/dev/null; then
                    if docker tag "$alt_image" "$minikube_tag" 2>/dev/null; then
                        log_success "Tagged fallback $alt_image as $minikube_tag"
                        fallback_success=true
                        ((pull_successes++))
                        ((tag_successes++))
                        break
                    else
                        log_warning "Failed to tag $alt_image as $minikube_tag"
                    fi
                fi
            done
            
            if [[ "$fallback_success" != true ]]; then
                log_warning "All attempts failed for $component"
                ((pull_failures++))
            fi
        fi
    done
    
    log_info "Image processing summary:"
    log_info "  Pulls: $pull_successes successful, $pull_failures failed"
    log_info "  Tags: $tag_successes successful"
    
    if [[ $pull_failures -gt 0 ]]; then
        log_warning "Some images failed to pre-pull, but continuing with cluster start"
        log_info "Minikube will attempt to download missing images during startup"
    fi
    
    # Save image manifest for minikube
    save_image_manifest
    
    return 0
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

# Configure minikube to use local images
configure_minikube_local_images() {
    log_info "Configuring minikube to prefer local images..."
    
    # Set minikube to use local docker daemon and prefer local images
    minikube config set driver "$MINIKUBE_DRIVER" -p "$PROFILE_NAME" 2>/dev/null || true
    minikube config set image-mirror-country "" -p "$PROFILE_NAME" 2>/dev/null || true
    minikube config set image-repository "" -p "$PROFILE_NAME" 2>/dev/null || true
    
    # Configure to skip pulling if images exist locally
    export MINIKUBE_PULL_POLICY="IfNotPresent"
    
    log_success "Minikube configured to prefer local images"
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
    
    # Check if Docker is accessible and try to pre-pull images
    if docker info >/dev/null 2>&1; then
        log_info "Docker is accessible, processing images..."
        configure_minikube_local_images
        pre_pull_and_tag_images
    else
        log_warning "Docker not accessible, skipping image pre-pull"
        log_info "Images will be downloaded during cluster start"
    fi
    
    log_info "Proceeding with cluster start..."
    
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
        "--pull-policy=IfNotPresent"
    )
    
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
        
        set +e  # Temporarily disable exit on error
        minikube start "${start_args[@]}"
        local start_exit_code=$?
        set -e  # Re-enable exit on error
        
        if [[ $start_exit_code -eq 0 ]]; then
            log_success "Cluster started successfully!"
            break
        else
            log_error "Minikube start failed with exit code: $start_exit_code"
            ((retry_count++))
            
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "Cleaning up failed cluster and retrying..."
                minikube delete -p "$PROFILE_NAME" 2>/dev/null || true
                sleep 10
            else
                log_error "Failed to start cluster after $max_retries attempts"
                log_error "Final exit code: $start_exit_code"
                log_info "Try running manually with: minikube start --profile $PROFILE_NAME --driver $MINIKUBE_DRIVER"
                log_info "Or check logs with: minikube logs -p $PROFILE_NAME"
                return 1
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
    
    # Configure post-startup components
    configure_post_startup_components
    
    show_cluster_info
}

# Configure components that need post-startup configuration
configure_post_startup_components() {
    log_info "Configuring post-startup components..."
    
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
    clean-images    Remove local Kubernetes images
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
    $0 start --pause "my-registry.com/pause:3.10" \\
             --apiserver "my-registry.com/kube-apiserver:v1.31.1"
    $0 clean-images                                      # Remove cached images
    $0 troubleshoot                                      # Run full diagnostics
    
CONFIGURATION FILES:
    ~/.local-cluster-cli/images.conf        # Custom image URLs
    ~/.local-cluster-cli/cluster.log        # Installation and runtime logs
    ~/.local-cluster-cli/image-manifest.txt # Local image cache manifest

INDIVIDUAL IMAGE OVERRIDE EXAMPLES:
    # Use custom images from your private registry
    $0 start \\
        --kicbase "my-registry.com/kicbase:v0.0.44" \\
        --pause "my-registry.com/pause:3.10" \\
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
        clean-images)
            clean_images
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