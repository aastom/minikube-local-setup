#!/bin/bash

# Ubuntu Docker Setup for WSL (No Windows Docker Desktop)
# This script installs Docker directly on Ubuntu WSL without using Windows Docker Desktop

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions (define these first)
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running in WSL
is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]] || [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]] || grep -qi microsoft /proc/version 2>/dev/null
}

# Check if running as root
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        log_info "Run as your regular user (the script will use sudo when needed)"
        exit 1
    fi
}

# Update system packages
update_system() {
    log_info "Updating system packages..."
    sudo apt-get update -qq
    sudo apt-get upgrade -y
    log_success "System updated successfully"
}

# Install required dependencies
install_dependencies() {
    log_info "Installing required dependencies..."
    
    local packages=(
        apt-transport-https
        ca-certificates
        curl
        gnupg
        lsb-release
        software-properties-common
        uidmap
        dbus-user-session
        fuse-overlayfs
        slirp4netns
    )
    
    sudo apt-get install -y "${packages[@]}"
    log_success "Dependencies installed successfully"
}

# Add Docker's official GPG key and repository
add_docker_repo() {
    log_info "Adding Docker repository..."
    
    # Remove any existing Docker packages
    log_info "Removing any existing Docker packages..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package index
    sudo apt-get update -qq
    
    log_success "Docker repository added successfully"
}

# Install Docker Engine
install_docker() {
    log_info "Installing Docker Engine..."
    
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    log_success "Docker Engine installed successfully"
}

# Configure Docker for WSL
configure_docker_wsl() {
    log_info "Configuring Docker for WSL..."
    
    # Add user to docker group
    sudo usermod -aG docker "$USER"
    
    # Create docker directory for user
    sudo mkdir -p /home/"$USER"/.docker
    sudo chown "$USER":"$USER" /home/"$USER"/.docker -R
    
    # Configure Docker daemon for WSL
    sudo mkdir -p /etc/docker
    
    cat << 'EOF' | sudo tee /etc/docker/daemon.json > /dev/null
{
    "hosts": ["unix:///var/run/docker.sock"],
    "iptables": false,
    "bridge": "none",
    "ip-forward": false,
    "ip-masq": false,
    "userland-proxy": false,
    "experimental": false,
    "metrics-addr": "127.0.0.1:9323",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
EOF
    
    log_success "Docker configured for WSL"
}

# Create Docker service management script
create_docker_service_script() {
    log_info "Creating Docker service management script..."
    
    # Create a script to manage Docker service
    cat << 'EOF' > /tmp/docker-service.sh
#!/bin/bash

# Docker service management for WSL
SERVICE_NAME="docker"
DOCKER_DIR="/var/run"
DOCKER_SOCK="$DOCKER_DIR/docker.sock"

start_docker() {
    echo "Starting Docker service..."
    
    # Check if Docker is already running
    if docker info >/dev/null 2>&1; then
        echo "Docker is already running"
        return 0
    fi
    
    # Start Docker daemon
    sudo dockerd >/dev/null 2>&1 &
    
    # Wait for Docker to start
    local count=0
    while ! docker info >/dev/null 2>&1; do
        sleep 1
        count=$((count + 1))
        if [ $count -gt 30 ]; then
            echo "Error: Docker failed to start within 30 seconds"
            return 1
        fi
    done
    
    echo "Docker started successfully"
}

stop_docker() {
    echo "Stopping Docker service..."
    
    # Find and kill dockerd process
    local docker_pid=$(pgrep dockerd)
    if [ -n "$docker_pid" ]; then
        sudo kill "$docker_pid"
        echo "Docker stopped successfully"
    else
        echo "Docker is not running"
    fi
}

restart_docker() {
    stop_docker
    sleep 2
    start_docker
}

status_docker() {
    if docker info >/dev/null 2>&1; then
        echo "Docker is running"
        docker --version
        return 0
    else
        echo "Docker is not running"
        return 1
    fi
}

case "$1" in
    start)
        start_docker
        ;;
    stop)
        stop_docker
        ;;
    restart)
        restart_docker
        ;;
    status)
        status_docker
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
    
    # Install the service script
    sudo mv /tmp/docker-service.sh /usr/local/bin/docker-service
    sudo chmod +x /usr/local/bin/docker-service
    
    log_success "Docker service script created at /usr/local/bin/docker-service"
}

# Create auto-start script for .bashrc
create_autostart_script() {
    log_info "Setting up Docker auto-start..."
    
    # Create auto-start function
    cat << 'EOF' >> ~/.bashrc

# Docker auto-start function for WSL
start_docker_if_needed() {
    if ! docker info >/dev/null 2>&1; then
        echo "Starting Docker..."
        /usr/local/bin/docker-service start
    fi
}

# Auto-start Docker when opening new terminal (optional)
# Uncomment the next line if you want Docker to start automatically
# start_docker_if_needed
EOF
    
    log_success "Auto-start script added to ~/.bashrc"
}

# Test Docker installation
test_docker() {
    log_info "Testing Docker installation..."
    
    # Start Docker service
    /usr/local/bin/docker-service start
    
    # Test Docker
    if docker --version; then
        log_success "Docker version check passed"
    else
        log_error "Docker version check failed"
        return 1
    fi
    
    # Test Docker run
    if docker run --rm hello-world; then
        log_success "Docker run test passed"
    else
        log_error "Docker run test failed"
        return 1
    fi
    
    log_success "Docker installation test completed successfully!"
}

# Install Docker Compose (standalone)
install_docker_compose() {
    log_info "Installing Docker Compose..."
    
    # Get latest version
    local compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    
    # Download and install
    sudo curl -L "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    
    # Create symlink
    sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    log_success "Docker Compose ${compose_version} installed successfully"
}

# Show usage instructions
show_usage() {
    echo
    echo "========================================"
    log_success "Docker installation completed!"
    echo "========================================"
    echo
    log_info "Docker Service Management:"
    echo "  /usr/local/bin/docker-service start    # Start Docker"
    echo "  /usr/local/bin/docker-service stop     # Stop Docker"
    echo "  /usr/local/bin/docker-service restart  # Restart Docker"
    echo "  /usr/local/bin/docker-service status   # Check Docker status"
    echo
    log_info "Quick Commands:"
    echo "  docker-service start    # Start Docker"
    echo "  docker --version        # Check Docker version"
    echo "  docker run hello-world  # Test Docker"
    echo
    log_warning "Important Notes:"
    echo "  1. You need to start a new terminal session or run 'newgrp docker' for group changes to take effect"
    echo "  2. Docker doesn't auto-start like systemd services in WSL"
    echo "  3. Use 'docker-service start' to start Docker when needed"
    echo "  4. Uncomment the auto-start line in ~/.bashrc if you want Docker to start automatically"
    echo
    log_info "To start Docker now, run:"
    echo "  newgrp docker"
    echo "  docker-service start"
    echo
}

# Main installation function
main() {
    log_info "Starting Docker installation for Ubuntu WSL..."
    echo
    
    # Pre-flight checks
    check_not_root
    
    if ! is_wsl; then
        log_warning "This script is optimized for WSL, but continuing anyway..."
    fi
    
    # Installation steps
    update_system
    install_dependencies
    add_docker_repo
    install_docker
    configure_docker_wsl
    create_docker_service_script
    create_autostart_script
    install_docker_compose
    
    # Test installation (in new group context)
    log_info "Testing Docker installation..."
    log_info "Note: Group changes require a new shell session"
    
    show_usage
}

# Command line options
case "${1:-}" in
    install)
        main
        ;;
    start)
        /usr/local/bin/docker-service start
        ;;
    stop)
        /usr/local/bin/docker-service stop
        ;;
    restart)
        /usr/local/bin/docker-service restart
        ;;
    status)
        /usr/local/bin/docker-service status
        ;;
    test)
        test_docker
        ;;
    help|--help|-h)
        echo "Ubuntu Docker Setup for WSL"
        echo
        echo "Usage: $0 [COMMAND]"
        echo
        echo "Commands:"
        echo "  install   Install Docker on Ubuntu WSL"
        echo "  start     Start Docker service"
        echo "  stop      Stop Docker service"
        echo "  restart   Restart Docker service"
        echo "  status    Check Docker service status"
        echo "  test      Test Docker installation"
        echo "  help      Show this help"
        echo
        ;;
    "")
        main
        ;;
    *)
        log_error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac