#!/bin/bash

# Simple Minikube Image Management Script
# Does exactly what you want: pull images, tag them, load into minikube, start cluster

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PROFILE_NAME="enterprise-k8s"
MINIKUBE_DRIVER="docker"
MINIKUBE_MEMORY="4096"
MINIKUBE_CPUS="2"

# Image configurations
KUBE_VERSION="v1.33.1"
PAUSE_VERSION="3.10"
ETCD_VERSION="3.5.21-0"
COREDNS_VERSION="v1.12.0"
STORAGE_PROVISIONER_VERSION="v5_6e38f40d628d"

# Custom image URLs (set these to your custom registries if needed)
CUSTOM_PAUSE_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/registry.k8s.io/pause:3.10"
CUSTOM_APISERVER_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/registry.k8s.io/kube-apiserver:v1.33.1"
CUSTOM_CONTROLLER_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/registry.k8s.io/kube-controller-manager:v1.33.1"
CUSTOM_SCHEDULER_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/registry.k8s.io/kube-scheduler:v1.33.1"
CUSTOM_PROXY_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/registry.k8s.io/kube-proxy:v1.33.1"
CUSTOM_ETCD_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/registry.k8s.io/etcd:3.5.21-0"
CUSTOM_COREDNS_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/registry.k8s.io/coredns/coredns:v1.12.0"
CUSTOM_STORAGE_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/gcr.io/k8s-minikube/storage-provisioner:v5_6e38f40d628d"
CUSTOM_KICBASE_IMAGE="europe-docker.pkg.dev/mgmt-bak-bld-1dd7/staging/ap/edh/al07595/images/platform-tools/gcr.io/k8s-minikube/kicbase:v0.0.47"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to extract tag from image URL (handles complex URLs with multiple colons)
extract_tag() {
    local image_url="$1"
    
    # Debug: show what we're parsing
    log_info "  Parsing URL: $image_url"
    
    # For your specific URL format: europe-docker.pkg.dev/.../registry.k8s.io/component:tag
    # The tag is after the last colon, but we need to be careful about registry URLs
    
    # Look for pattern: /component:tag at the very end
    if [[ "$image_url" =~ /([^/]+):([^/:]+)$ ]]; then
        local component="${BASH_REMATCH[1]}"
        local tag="${BASH_REMATCH[2]}"
        log_info "  Found component: $component, tag: $tag"
        echo "$tag"
        return 0
    fi
    
    # Fallback: split by colon and take the last part if it doesn't contain slashes
    local last_colon_part="${image_url##*:}"
    if [[ "$last_colon_part" != *"/"* ]]; then
        log_info "  Extracted tag (fallback): $last_colon_part"
        echo "$last_colon_part"
        return 0
    fi
    
    # If we get here, something's wrong with the URL format
    log_warning "  Could not extract tag from: $image_url"
    log_warning "  Using 'latest' as fallback"
    echo "latest"
}

# Function to extract repository path from image URL (everything before the last colon that's a tag)
extract_repo() {
    local image_url="$1"
    local tag=$(extract_tag "$image_url")
    
    # If tag is "latest" and not explicitly in URL, return the full URL
    if [[ "$tag" == "latest" && "$image_url" != *":latest" ]]; then
        echo "$image_url"
    else
        echo "${image_url%:$tag}"
    fi
}

# Function to pull and tag images
pull_and_tag_images() {
    log_info "=== STEP 1: PULLING AND TAGGING IMAGES ==="
    
    # Extract actual tags from custom images or use defaults
    local pause_tag="${PAUSE_VERSION}"
    local kube_tag="${KUBE_VERSION}"
    local etcd_tag="${ETCD_VERSION}"
    local coredns_tag="${COREDNS_VERSION}"
    local storage_tag="${STORAGE_PROVISIONER_VERSION}"
    local kicbase_tag="v0.0.47"
    
    log_info "=== TAG EXTRACTION DEBUG ==="
    if [[ -n "$CUSTOM_PAUSE_IMAGE" ]]; then
        log_info "CUSTOM_PAUSE_IMAGE: $CUSTOM_PAUSE_IMAGE"
        pause_tag=$(extract_tag "$CUSTOM_PAUSE_IMAGE")
    fi
    if [[ -n "$CUSTOM_APISERVER_IMAGE" ]]; then
        log_info "CUSTOM_APISERVER_IMAGE: $CUSTOM_APISERVER_IMAGE"
        kube_tag=$(extract_tag "$CUSTOM_APISERVER_IMAGE")
    fi
    if [[ -n "$CUSTOM_ETCD_IMAGE" ]]; then
        log_info "CUSTOM_ETCD_IMAGE: $CUSTOM_ETCD_IMAGE"
        etcd_tag=$(extract_tag "$CUSTOM_ETCD_IMAGE")
    fi
    if [[ -n "$CUSTOM_COREDNS_IMAGE" ]]; then
        log_info "CUSTOM_COREDNS_IMAGE: $CUSTOM_COREDNS_IMAGE"
        coredns_tag=$(extract_tag "$CUSTOM_COREDNS_IMAGE")
    fi
    if [[ -n "$CUSTOM_STORAGE_IMAGE" ]]; then
        log_info "CUSTOM_STORAGE_IMAGE: $CUSTOM_STORAGE_IMAGE"
        storage_tag=$(extract_tag "$CUSTOM_STORAGE_IMAGE")
    fi
    if [[ -n "$CUSTOM_KICBASE_IMAGE" ]]; then
        log_info "CUSTOM_KICBASE_IMAGE: $CUSTOM_KICBASE_IMAGE"
        kicbase_tag=$(extract_tag "$CUSTOM_KICBASE_IMAGE")
    fi
    log_info "=== END DEBUG ==="
    echo
    
    log_info "Extracted tags:"
    log_info "  pause: $pause_tag"
    log_info "  kube components: $kube_tag"
    log_info "  etcd: $etcd_tag"
    log_info "  coredns: $coredns_tag"
    log_info "  storage: $storage_tag"
    log_info "  kicbase: $kicbase_tag"
    echo
    
    # Define image mappings using extracted tags
    declare -A images=(
        ["pause"]="${CUSTOM_PAUSE_IMAGE:-registry.k8s.io/pause:$pause_tag}:registry.k8s.io/pause:$pause_tag"
        ["apiserver"]="${CUSTOM_APISERVER_IMAGE:-registry.k8s.io/kube-apiserver:$kube_tag}:registry.k8s.io/kube-apiserver:$kube_tag"
        ["controller"]="${CUSTOM_CONTROLLER_IMAGE:-registry.k8s.io/kube-controller-manager:$kube_tag}:registry.k8s.io/kube-controller-manager:$kube_tag"
        ["scheduler"]="${CUSTOM_SCHEDULER_IMAGE:-registry.k8s.io/kube-scheduler:$kube_tag}:registry.k8s.io/kube-scheduler:$kube_tag"
        ["proxy"]="${CUSTOM_PROXY_IMAGE:-registry.k8s.io/kube-proxy:$kube_tag}:registry.k8s.io/kube-proxy:$kube_tag"
        ["etcd"]="${CUSTOM_ETCD_IMAGE:-registry.k8s.io/etcd:$etcd_tag}:registry.k8s.io/etcd:$etcd_tag"
        ["coredns"]="${CUSTOM_COREDNS_IMAGE:-registry.k8s.io/coredns/coredns:$coredns_tag}:registry.k8s.io/coredns/coredns:$coredns_tag"
        ["storage"]="${CUSTOM_STORAGE_IMAGE:-gcr.io/k8s-minikube/storage-provisioner:$storage_tag}:gcr.io/k8s-minikube/storage-provisioner:$storage_tag"
        ["kicbase"]="${CUSTOM_KICBASE_IMAGE:-gcr.io/k8s-minikube/kicbase:$kicbase_tag}:gcr.io/k8s-minikube/kicbase:$kicbase_tag"
    )
    
    for component in "${!images[@]}"; do
        IFS=':' read -r source_image minikube_tag <<< "${images[$component]}"
        
        log_info "Processing $component..."
        log_info "  Source: $source_image"
        log_info "  Target: $minikube_tag"
        
        # Pull the source image
        if docker pull "$source_image"; then
            log_success "  Pulled: $source_image"
            
            # Tag it for minikube if different
            if [[ "$source_image" != "$minikube_tag" ]]; then
                if docker tag "$source_image" "$minikube_tag"; then
                    log_success "  Tagged as: $minikube_tag"
                else
                    log_error "  Failed to tag $source_image as $minikube_tag"
                fi
            else
                log_info "  Already has correct tag"
            fi
        else
            log_error "  Failed to pull: $source_image"
            return 1
        fi
        echo
    done
    
    log_success "All images pulled and tagged successfully!"
}

# Function to start minikube cluster (basic, no fancy flags)
start_cluster() {
    log_info "=== STEP 2: STARTING MINIKUBE CLUSTER ==="
    
    # Check if already running
    if minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_success "Cluster is already running!"
        return 0
    fi
    
    # Start with minimal flags
    log_info "Starting minikube cluster..."
    
    # Build command args
    local start_args=(
        "--driver=$MINIKUBE_DRIVER"
        "--memory=$MINIKUBE_MEMORY"
        "--cpus=$MINIKUBE_CPUS"
        "--profile=$PROFILE_NAME"
    )
    
    # Add custom kicbase if specified
    if [[ -n "$CUSTOM_KICBASE_IMAGE" ]]; then
        start_args+=("--base-image=$CUSTOM_KICBASE_IMAGE")
        log_info "Using custom kicbase: $CUSTOM_KICBASE_IMAGE"
    fi
    
    log_info "Command: minikube start ${start_args[*]}"
    
    if minikube start "${start_args[@]}"; then
        log_success "Cluster started successfully!"
    else
        log_error "Failed to start cluster"
        return 1
    fi
}

# Function to load images into minikube
load_images_into_minikube() {
    log_info "=== STEP 3: LOADING IMAGES INTO MINIKUBE ==="
    
    # Check if cluster is running
    if ! minikube status -p "$PROFILE_NAME" 2>/dev/null | grep -q "Running"; then
        log_error "Cluster is not running!"
        return 1
    fi
    
    # Extract actual tags from custom images or use defaults
    local pause_tag="${PAUSE_VERSION}"
    local kube_tag="${KUBE_VERSION}"
    local etcd_tag="${ETCD_VERSION}"
    local coredns_tag="${COREDNS_VERSION}"
    local storage_tag="${STORAGE_PROVISIONER_VERSION}"
    local kicbase_tag="v0.0.47"
    
    if [[ -n "$CUSTOM_PAUSE_IMAGE" ]]; then
        pause_tag=$(extract_tag "$CUSTOM_PAUSE_IMAGE")
    fi
    if [[ -n "$CUSTOM_APISERVER_IMAGE" ]]; then
        kube_tag=$(extract_tag "$CUSTOM_APISERVER_IMAGE")
    fi
    if [[ -n "$CUSTOM_ETCD_IMAGE" ]]; then
        etcd_tag=$(extract_tag "$CUSTOM_ETCD_IMAGE")
    fi
    if [[ -n "$CUSTOM_COREDNS_IMAGE" ]]; then
        coredns_tag=$(extract_tag "$CUSTOM_COREDNS_IMAGE")
    fi
    if [[ -n "$CUSTOM_STORAGE_IMAGE" ]]; then
        storage_tag=$(extract_tag "$CUSTOM_STORAGE_IMAGE")
    fi
    if [[ -n "$CUSTOM_KICBASE_IMAGE" ]]; then
        kicbase_tag=$(extract_tag "$CUSTOM_KICBASE_IMAGE")
    fi
    
    # List of images to load using extracted tags
    local images_to_load=(
        "registry.k8s.io/pause:$pause_tag"
        "registry.k8s.io/kube-apiserver:$kube_tag"
        "registry.k8s.io/kube-controller-manager:$kube_tag"
        "registry.k8s.io/kube-scheduler:$kube_tag"
        "registry.k8s.io/kube-proxy:$kube_tag"
        "registry.k8s.io/etcd:$etcd_tag"
        "registry.k8s.io/coredns/coredns:$coredns_tag"
        "gcr.io/k8s-minikube/storage-provisioner:$storage_tag"
    )
    
    # Add kicbase if we have a custom one
    if [[ -n "$CUSTOM_KICBASE_IMAGE" ]]; then
        images_to_load+=("gcr.io/k8s-minikube/kicbase:$kicbase_tag")
    fi
    
    for image in "${images_to_load[@]}"; do
        log_info "Loading $image into minikube..."
        if minikube image load "$image" -p "$PROFILE_NAME"; then
            log_success "  Loaded: $image"
        else
            log_warning "  Failed to load: $image"
        fi
    done
    
    log_success "Image loading completed!"
}

# Function to verify images in minikube
verify_images() {
    log_info "=== STEP 4: VERIFYING IMAGES IN MINIKUBE ==="
    
    log_info "Images available in minikube:"
    minikube ssh -p "$PROFILE_NAME" -- "docker images | grep -E '(registry\.k8s\.io|gcr\.io)'" || true
}

# Function to show cluster info
show_status() {
    log_info "=== CLUSTER STATUS ==="
    
    if minikube status -p "$PROFILE_NAME" 2>/dev/null; then
        echo
        log_info "Cluster IP: $(minikube ip -p "$PROFILE_NAME" 2>/dev/null || echo 'Not available')"
        log_info "Dashboard: minikube dashboard -p $PROFILE_NAME"
        echo
        log_info "Quick commands:"
        echo "  kubectl get nodes"
        echo "  kubectl get pods -A"
    else
        log_warning "No cluster found"
    fi
}

# Main execution functions
do_full_setup() {
    log_info "Starting complete setup..."
    pull_and_tag_images
    start_cluster
    load_images_into_minikube
    verify_images
    show_status
    log_success "Complete setup finished!"
}

do_pull_only() {
    log_info "Pulling and tagging images only..."
    pull_and_tag_images
}

do_start_only() {
    log_info "Starting cluster only..."
    start_cluster
    show_status
}

do_load_only() {
    log_info "Loading images into existing cluster..."
    load_images_into_minikube
    verify_images
}

do_clean() {
    log_info "Cleaning up cluster..."
    minikube delete -p "$PROFILE_NAME" || true
    log_success "Cleanup completed!"
}

# Help function
show_help() {
    cat << EOF
Simple Minikube Image Management Script

USAGE:
    $0 [COMMAND]

COMMANDS:
    setup       Pull images, start cluster, load images (complete setup)
    pull        Pull and tag images only
    start       Start minikube cluster only
    load        Load already-pulled images into running cluster
    verify      Show images in minikube
    status      Show cluster status
    clean       Delete cluster
    help        Show this help

CUSTOM IMAGES:
    Edit the script and set these variables to use custom registries:
    - CUSTOM_PAUSE_IMAGE="your-registry.com/pause:3.9"
    - CUSTOM_APISERVER_IMAGE="your-registry.com/kube-apiserver:v1.31.1"
    - etc.

EXAMPLES:
    $0 setup      # Complete setup from scratch
    $0 pull       # Just pull and tag images
    $0 start      # Just start cluster
    $0 load       # Load images into running cluster
    $0 clean      # Clean up everything

EOF
}

# Main script logic
main() {
    case "${1:-}" in
        setup)
            do_full_setup
            ;;
        pull)
            do_pull_only
            ;;
        start)
            do_start_only
            ;;
        load)
            do_load_only
            ;;
        verify)
            verify_images
            ;;
        status)
            show_status
            ;;
        clean)
            do_clean
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"