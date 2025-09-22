#!/bin/bash

# Function to detect if running in Proxmox LXC container
is_proxmox_lxc() {
    # Check for LXC in environment
    if [ -n "$container" ] && [ "$container" = "lxc" ]; then
        return 0  # LXC container
    fi
    
    # Check for LXC in /proc/1/environ
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        return 0  # LXC container
    fi
    
    return 1  # Not LXC
}

install_dokploy() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    # check if is Mac OS
    if [ "$(uname)" = "Darwin" ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    # check if is running inside a container
    if [ -f /.dockerenv ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    # check if something is running on port 80
    if ss -tulnp | grep ':80 ' >/dev/null; then
        echo "Error: something is already running on port 80" >&2
        exit 1
    fi

    # check if something is running on port 443
    if ss -tulnp | grep ':443 ' >/dev/null; then
        echo "Error: something is already running on port 443" >&2
        exit 1
    fi

    command_exists() {
        command -v "$@" > /dev/null 2>&1
    }

    if command_exists docker; then
        echo "Docker already installed"
    else
        curl -sSL https://get.docker.com | sh
    fi

    # Check if running in Proxmox LXC container and set endpoint mode
    endpoint_mode=""
    endpoint_mode_compose=""
    if is_proxmox_lxc; then
        echo "⚠️ WARNING: Detected Proxmox LXC container environment!"
        echo "Adding --endpoint-mode dnsrr to Docker services for LXC compatibility."
        echo "This may affect service discovery but is required for LXC containers."
        echo ""
        endpoint_mode="--endpoint-mode dnsrr"
        endpoint_mode_compose="endpoint_mode: dnsrr"
        echo "Waiting for 5 seconds before continuing..."
        sleep 5
    fi

    docker swarm leave --force 2>/dev/null

    get_ip() {
        local ip=""
        
        # Try IPv4 first
        # First attempt: ifconfig.io
        ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        
        # Second attempt: icanhazip.com
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        fi
        
        # Third attempt: ipecho.net
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi

        # If no IPv4, try IPv6
        if [ -z "$ip" ]; then
            # Try IPv6 with ifconfig.io
            ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
            
            # Try IPv6 with icanhazip.com
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
            fi
            
            # Try IPv6 with ipecho.net
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
            fi
        fi

        if [ -z "$ip" ]; then
            echo "Error: Could not determine server IP address automatically (neither IPv4 nor IPv6)." >&2
            echo "Please set the ADVERTISE_ADDR environment variable manually." >&2
            echo "Example: export ADVERTISE_ADDR=<your-server-ip>" >&2
            exit 1
        fi

        echo "$ip"
    }

    get_private_ip() {
        ip addr show | grep -E "inet (192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)" | head -n1 | awk '{print $2}' | cut -d/ -f1
    }

    advertise_addr="${ADVERTISE_ADDR:-$(get_private_ip)}"

    if [ -z "$advertise_addr" ]; then
        echo "ERROR: We couldn't find a private IP address."
        echo "Please set the ADVERTISE_ADDR environment variable manually."
        echo "Example: export ADVERTISE_ADDR=192.168.1.100"
        exit 1
    fi
    echo "Using advertise address: $advertise_addr"

    docker swarm init --advertise-addr $advertise_addr
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to initialize Docker Swarm" >&2
        exit 1
    fi

    echo "Swarm initialized"

    # Remove and recreate network to ensure clean state
    docker network rm dokploy-network 2>/dev/null
    docker network create --driver overlay --attachable dokploy-network

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create dokploy-network" >&2
        exit 1
    fi

    echo "Network created"

    mkdir -p /etc/dokploy/traefik/dynamic
    chmod -R 777 /etc/dokploy

    # Create volumes before deploying stack to ensure consistent naming
    echo "Creating volumes with original names..."
    docker volume create dokploy-postgres-database 2>/dev/null || echo "Volume dokploy-postgres-database already exists"
    docker volume create redis-data-volume 2>/dev/null || echo "Volume redis-data-volume already exists"
    docker volume create dokploy-docker-config 2>/dev/null || echo "Volume dokploy-docker-config already exists"

    # Create Docker Compose file with external volumes to maintain original names
    cat <<EOF > /etc/dokploy/compose.yml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: dokploy
      POSTGRES_PASSWORD: amukds4wi9001583845717ad2
      POSTGRES_DB: dokploy
    volumes:
      - dokploy-postgres-database:/var/lib/postgresql/data
    networks:
      - dokploy-network
    deploy:
      replicas: 1
      placement:
        constraints: [node.role == manager]
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 10
        window: 120s
      update_config:
        parallelism: 1
        order: stop-first

  redis:
    image: redis:7
    volumes:
      - redis-data-volume:/data
    networks:
      - dokploy-network
    deploy:
      replicas: 1
      placement:
        constraints: [node.role == manager]
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 10
        window: 120s
      update_config:
        parallelism: 1
        order: stop-first

  dokploy:
    image: dokploy/dokploy:latest
    environment:
      - ADVERTISE_ADDR=$advertise_addr
    ports:
      - target: 3000
        published: 3000
        mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/dokploy:/etc/dokploy
      - dokploy-docker-config:/root/.docker
    networks:
      - dokploy-network
    deploy:
      replicas: 1
      placement:
        constraints: [node.role == manager]
      restart_policy:
        condition: any
        delay: 10s
        max_attempts: 5
        window: 60s
      update_config:
        parallelism: 1
        order: stop-first
      $endpoint_mode_compose

volumes:
  dokploy-postgres-database:
    external: true
    name: dokploy-postgres-database
  redis-data-volume:
    external: true
    name: redis-data-volume
  dokploy-docker-config:
    external: true
    name: dokploy-docker-config

networks:
  dokploy-network:
    external: true
EOF

    echo "Docker Compose file created with external volumes"

    # Deploy the stack
    docker stack deploy -c /etc/dokploy/compose.yml dokploy

    if [ $? -ne 0 ]; then
        echo "Error: Failed to deploy Docker stack" >&2
        exit 1
    fi

    echo "Docker stack deployed"

    # Wait a moment for services to start
    sleep 4

    # Deploy Traefik separately as a regular container with restart policy
    # Remove existing traefik container if it exists
    docker rm -f dokploy-traefik 2>/dev/null

    docker run -d \
        --name dokploy-traefik \
        --restart unless-stopped \
        -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
        -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -p 80:80/tcp \
        -p 443:443/tcp \
        -p 443:443/udp \
        traefik:v3.5.0

    if [ $? -ne 0 ]; then
        echo "Error: Failed to start Traefik container" >&2
        exit 1
    fi

    # Connect Traefik to the dokploy network
    docker network connect dokploy-network dokploy-traefik

    if [ $? -ne 0 ]; then
        echo "Warning: Failed to connect Traefik to dokploy-network, but continuing..." >&2
    fi

    echo "Traefik container started and connected to network"

    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m" # No Color

    format_ip_for_url() {
        local ip="$1"
        if echo "$ip" | grep -q ':'; then
            # IPv6
            echo "[${ip}]"
        else
            # IPv4
            echo "${ip}"
        fi
    }

    public_ip="${ADVERTISE_ADDR:-$(get_ip)}"
    formatted_addr=$(format_ip_for_url "$public_ip")
    echo ""
    printf "${GREEN}✅ Dokploy installed successfully with Docker Stack and auto-restart policies!${NC}\n"
    printf "${BLUE}Wait 15 seconds for all services to be ready${NC}\n"
    printf "${YELLOW}Please go to http://${formatted_addr}:3000${NC}\n\n"
    echo "Services will automatically restart if Docker daemon restarts or server reboots."
    echo "Volumes use original names for compatibility with existing installations."
}

update_dokploy() {
    echo "Updating Dokploy..."
    
    # Pull the latest image
    docker pull dokploy/dokploy:latest

    # Update the service in the stack (note: stack name prefix)
    docker service update --image dokploy/dokploy:latest dokploy_dokploy

    echo "Dokploy has been updated to the latest version."
}

# Main script execution
if [ "$1" = "update" ]; then
    update_dokploy
else
    install_dokploy
fi
