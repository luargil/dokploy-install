#!/bin/bash

# Function to detect if running in Proxmox LXC container
is_proxmox_lxc() {
    if [ -n "$container" ] && [ "$container" = "lxc" ]; then
        return 0
    fi
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        return 0
    fi
    return 1
}

install_dokploy() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    if [ "$(uname)" = "Darwin" ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    if [ -f /.dockerenv ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    if ss -tulnp | grep ':80 ' >/dev/null; then
        echo "Error: something is already running on port 80" >&2
        exit 1
    fi
    if ss -tulnp | grep ':443 ' >/dev/null; then
        echo "Error: something is already running on port 443" >&2
        exit 1
    fi

    command_exists() { command -v "$@" > /dev/null 2>&1; }

    if command_exists docker; then
      echo "Docker already installed"
    else
      curl -sSL https://get.docker.com | sh
    fi

    endpoint_mode=""
    if is_proxmox_lxc; then
        echo "⚠️ WARNING: Detected Proxmox LXC container environment!"
        echo "Adding --endpoint-mode dnsrr for LXC compatibility."
        endpoint_mode="--endpoint-mode dnsrr"
        sleep 5
    fi

    docker swarm leave --force 2>/dev/null

    get_ip() {
        local ip=""
        ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        if [ -z "$ip" ]; then
            ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
            [ -z "$ip" ] && ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
            [ -z "$ip" ] && ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi
        if [ -z "$ip" ]; then
            echo "Error: Could not determine server IP address automatically." >&2
            exit 1
        fi
        echo "$ip"
    }

    get_private_ip() {
        ip addr show | grep -E "inet (192\.168\.|10\.|172\.)" | head -n1 | awk '{print $2}' | cut -d/ -f1
    }

    advertise_addr="${ADVERTISE_ADDR:-$(get_private_ip)}"
    if [ -z "$advertise_addr" ]; then
        echo "ERROR: No private IP found. Set ADVERTISE_ADDR manually."
        exit 1
    fi
    echo "Using advertise address: $advertise_addr"

    docker swarm init --advertise-addr $advertise_addr || true
    docker network create --driver overlay --attachable dokploy-network || true

    mkdir -p /etc/dokploy/traefik/dynamic
    chmod -R 777 /etc/dokploy

    # Crear el docker-compose.yml
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
      placement:
        constraints: [node.role == manager]
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 10
        window: 120s

  redis:
    image: redis:7
    volumes:
      - redis-data-volume:/data
    networks:
      - dokploy-network
    deploy:
      placement:
        constraints: [node.role == manager]
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 10
        window: 120s

  dokploy:
    image: dokploy/dokploy:latest
    environment:
      - ADVERTISE_ADDR=$advertise_addr
    ports:
      - "3000:3000"
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

  traefik:
    image: traefik:v3.5.0
    volumes:
      - /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml
      - /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    networks:
      - dokploy-network
    deploy:
      placement:
        constraints: [node.role == manager]
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 10
        window: 120s

volumes:
  dokploy-postgres-database:
  redis-data-volume:
  dokploy-docker-config:

networks:
  dokploy-network:
    external: true
EOF

    # Desplegar con stack
    docker stack deploy -c /etc/dokploy/compose.yml dokploy

    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m"

    public_ip="${ADVERTISE_ADDR:-$(get_ip)}"
    if echo "$public_ip" | grep -q ':'; then formatted_addr="[$public_ip]"; else formatted_addr="$public_ip"; fi

    echo ""
    printf "${GREEN}✅ Dokploy installed successfully${NC}\n"
    printf "${BLUE}Wait ~15s for services to be ready${NC}\n"
    printf "${YELLOW}Access: http://${formatted_addr}:3000${NC}\n\n"
}

update_dokploy() {
    echo "Updating Dokploy..."
    docker pull dokploy/dokploy:latest
    docker service update --image dokploy/dokploy:latest dokploy_dokploy
    echo "Dokploy updated."
}

if [ "$1" = "update" ]; then
    update_dokploy
else
    install_dokploy
fi
