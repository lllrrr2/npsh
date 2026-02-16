#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'


show_help() {
  echo -e "${GREEN}NodePassDash Management Script Instructions${NC}"
  echo -e "================================"
  echo -e "${YELLOW}Available Parameters:${NC}"
  echo -e "  ${GREEN}install${NC}     - Install/configure NodePassDash"
  echo -e "  ${GREEN}update${NC}      - Check and update NodePassDash to the latest version"
  echo -e "  ${GREEN}resetpwd${NC}    - Reset administrator password"
  echo -e "  ${GREEN}uninstall${NC}   - Uninstall NodePassDash"
  echo -e "  ${GREEN}help${NC}        - Display this help information"
  echo -e ""
  echo -e "${YELLOW}Usage Examples:${NC}"
  echo -e "  ${GREEN}./dash.sh install${NC}   # Normal installation"
  echo -e "  ${GREEN}./dash.sh update${NC}    # Update to latest version"
  echo -e "  ${GREEN}./dash.sh resetpwd${NC}  # Reset administrator password"
  echo -e "  ${GREEN}./dash.sh uninstall${NC} # Uninstall NodePassDash"
  echo -e "  ${GREEN}./dash.sh help${NC}      # Display help information"
  exit 0
}

check_download_cmd() {
  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    echo -e "${GREEN}Neither curl nor wget is installed, installing curl...${NC}"
    if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
      apt update >/dev/null 2>&1
      apt install -y curl >/dev/null 2>&1
    elif [ "$OS" == "centos" ]; then
      yum install -y curl >/dev/null 2>&1
    fi
  fi

  if command -v wget &>/dev/null; then
    DOWNLOAD_CMD="wget -qO-"
  else
    DOWNLOAD_CMD="curl -fsSL"
  fi
}

statistics_of_run-times() {
  local STATS=$($DOWNLOAD_CMD "https://stat.cloudflare.now.cc/api/updateStats?script=dash.sh")
  [[ "$STATS" =~ \"todayCount\":([0-9]+),\"totalCount\":([0-9]+) ]] && TODAY="${BASH_REMATCH[1]}" && TOTAL="${BASH_REMATCH[2]}"
}

check_os() {
  if [ -f /etc/debian_version ]; then
    OS="debian"
  elif [ -f /etc/lsb-release ]; then
    OS="ubuntu"
  elif [ -f /etc/redhat-release ]; then
    OS="centos"
  else
    echo -e "${RED}Unsupported operating system${NC}"
    exit 1
  fi
}

validate_input() {
  local input=$1
  if [[ $input =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  elif [[ $input =~ ^[0-9a-fA-F:]+$ ]]; then
    return 0
  elif [[ $input =~ ^[a-zA-Z0-9.-]+$ ]]; then
    return 0
  else
    return 1
  fi
}

validate_port() {
  local port=$1

  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo -e "${RED}Error: Port number $port is invalid. Please provide a port number between 1 and 65535.${NC}"
    return 1
  fi

  if [ "$TLS_MODE" != "2" ]; then
    if [ "$port" == "80" ] || [ "$port" == "443" ] || [ "$port" == "2019" ]; then
      echo -e "${RED}Error: Port $port will be used by Caddy, please choose another port.${NC}"
      return 1
    fi
  fi

  return 0
}

reset_admin_password() {
  if ! $CONTAINER_CMD inspect nodepassdash &>/dev/null; then
    echo -e "${RED}Error: nodepassdash container is not running, cannot reset password.${NC}"
    exit 1
  fi

  echo -e "${GREEN}Resetting administrator password...${NC}"

  $CONTAINER_CMD exec -it nodepassdash /app/nodepassdash -resetpwd


  if $CONTAINER_CMD restart nodepassdash &>/dev/null; then
    exit 0
  else
    echo -e "${RED}Error: nodepassdash container failed to restart, cannot reset password.${NC}"
    exit 1
  fi
}

update_nodepassdash() {
  if ! $CONTAINER_CMD inspect nodepassdash &>/dev/null; then
    echo -e "${RED}Error: nodepassdash container is not running, cannot update.${NC}"
    exit 1
  fi


  local LOCAL_VERSION=$($CONTAINER_CMD exec -it nodepassdash /app/nodepassdash -v 2>/dev/null | awk '/NodePassDash/{gsub(/\r/,"",$NF); print $NF}')
  if [ -z "$LOCAL_VERSION" ]; then
    echo -e "${RED}Unable to get local version.${NC}"
    exit 1
  fi

  local REMOTE_VERSION=$(curl -s https://api.github.com/repos/NodePassProject/NodePassDash/releases/latest | awk -F '"' '/"tag_name"/{print $4}' | sed "s/[Vv]//")
  if [ -z "$REMOTE_VERSION" ]; then
    echo -e "${RED}Unable to get remote version.${NC}"
    exit 1
  fi

  echo -e "${GREEN}Local version: $LOCAL_VERSION${NC}"
  echo -e "${GREEN}Remote version: $REMOTE_VERSION${NC}"


  if [ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]; then
    echo -e "${GREEN}Already at the latest version, no update needed.${NC}"
    exit 0
  else
    echo -e "${YELLOW}New version $REMOTE_VERSION found (current version $LOCAL_VERSION)${NC}"
    read -p "$(echo -e ${YELLOW}Do you want to update to the latest version? [y/N]: ${NC})" choice
    case "$choice" in
    y | Y)
      echo -e "${GREEN}Preparing to update...${NC}"
      ;;
    *)
      echo -e "${GREEN}Update cancelled.${NC}"
      exit 0
      ;;
    esac
  fi

  if ! $CONTAINER_CMD inspect watchtower &>/dev/null; then
    echo -e "${GREEN}Temporarily running watchtower container for update...${NC}"
    $CONTAINER_CMD run --rm \
      -v /var/run/$CONTAINER_CMD.sock:/var/run/$CONTAINER_CMD.sock \
      -e DOCKER_API_VERSION=1.44 \
      containrrr/watchtower \
      --run-once \
      --cleanup \
      nodepassdash
  else
    echo -e "${GREEN}Using installed watchtower for update...${NC}"
    $CONTAINER_CMD start watchtower
  fi

  echo -e "${YELLOW}Updating, please wait...${NC}"
  sleep 10


  local NEW_VERSION=$($CONTAINER_CMD exec -it nodepassdash /app/nodepassdash -v 2>/dev/null | awk '/NodePassDash/{gsub(/\r/,"",$NF); print $NF}')
  if [ "$NEW_VERSION" == "$REMOTE_VERSION" ]; then
    echo -e "${GREEN}Update successful! Current version: $NEW_VERSION${NC}"
  else
    echo -e "${RED}Update failed, please check logs.${NC}"
    exit 1
  fi

  exit 0
}

uninstall_nodepassdash() {
  if $CONTAINER_CMD inspect nodepassdash &>/dev/null; then
    echo -e "${GREEN}Stopping and removing nodepassdash container...${NC}"
    $CONTAINER_CMD stop nodepassdash >/dev/null 2>&1
    $CONTAINER_CMD rm nodepassdash >/dev/null 2>&1
    rm -rf ~/nodepassdash
    $CONTAINER_CMD rmi ghcr.io/nodepassproject/nodepassdash:latest >/dev/null 2>&1
    echo -e "${GREEN}nodepassdash container has been successfully uninstalled.${NC}"
  else
    echo -e "${RED}nodepassdash container not found, cannot uninstall.${NC}"
  fi
  exit 0
}

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script with administrator privileges.${NC}"
  exit 1
fi

if command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
  echo -e "${GREEN}Podman detected, will use Podman as container management tool${NC}"
elif command -v docker &>/dev/null; then
  CONTAINER_CMD="docker"
  echo -e "${GREEN}Docker detected, will use Docker as container management tool${NC}"
else
  echo -e "${GREEN}No container management tool detected, will try to install Docker...${NC}"
  CONTAINER_CMD="docker"
fi


install_container_runtime() {
  echo -e "${GREEN}Installing Docker...${NC}"
  if [ "$OS" = "centos" ]; then
    CENTOS_VERSION=$(rpm -E '%{rhel}')
    if [ "$CENTOS_VERSION" -lt 8 ]; then
      echo -e "${RED}Error: Your CentOS version $CENTOS_VERSION is too old. Please use CentOS 8 or 9.${NC}"
      exit 1
    fi
  fi

  bash <($DOWNLOAD_CMD get.docker.com) >/dev/null 2>&1
  systemctl start docker >/dev/null 2>&1
  systemctl enable docker >/dev/null 2>&1
  echo -e "${GREEN}Docker installation complete, enabling IPv6...${NC}"


  DAEMON_JSON="/etc/docker/daemon.json"
  if [ -f $DAEMON_JSON ]; then
    echo -e "${GREEN}Existing daemon.json detected, backing up as daemon.json.bak...${NC}"
    cp $DAEMON_JSON $DAEMON_JSON.bak
    echo -e "${GREEN}Backup complete.${NC}"
  fi

  cat >$DAEMON_JSON <<EOF
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80",
  "experimental": true,
  "ip6tables": true
}
EOF
  echo -e "${GREEN}daemon.json has been created, content as follows:${NC}"
  cat $DAEMON_JSON

  systemctl restart docker >/dev/null 2>&1
  CONTAINER_CMD="docker"
  echo -e "${GREEN}Docker service has been restarted.${NC}"
}

install_nodepassdash() {
  if ! command -v $CONTAINER_CMD &>/dev/null && [[ "$1" != "uninstall" ]]; then
    install_container_runtime
  fi

  if [ "$CONTAINER_CMD" == "podman" ]; then
    PODMAN_CONFIG_DIR="$HOME/.config/containers"
    mkdir -p "$PODMAN_CONFIG_DIR"
    PODMAN_CONF="$PODMAN_CONFIG_DIR/containers.conf"

    if ! grep -q 'enable_ipv6' "$PODMAN_CONF" 2>/dev/null; then
      echo -e "${GREEN}Configuring Podman to support IPv6...${NC}"
      {
        echo "[network]"
        echo "enable_ipv6 = true"
      } >>"$PODMAN_CONF"
    else
      echo -e "${GREEN}Podman is already configured to support IPv6.${NC}"
    fi
  fi

  while true; do
    prompt=$(echo -e "${YELLOW}Please enter domain name or IPv4/IPv6 address (required): ${NC}")
    read -p "$prompt" INPUT
    if validate_input "$INPUT"; then
      echo -e "${GREEN}Your input is: $INPUT${NC}"
      break
    else
      echo -e "${RED}Invalid input, please enter a valid domain name or IPv4/IPv6 address.${NC}"
    fi
  done

  if ! [[ "$INPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! [[ "$INPUT" =~ ^[0-9a-fA-F:]+$ ]]; then
    echo -e "${YELLOW}Please choose TLS certificate mode (default 1):${NC}"
    echo -e "${GREEN} 1. Use Caddy to automatically apply for certificate (default)\n 2. Custom TLS certificate file path${NC}"
    prompt=$(echo -e "${YELLOW}Please choose: ${NC}")
    read -p "$prompt" TLS_MODE
    TLS_MODE=${TLS_MODE:-1}

    if [ "$TLS_MODE" = "2" ]; then
      while true; do
        prompt=$(echo -e "${YELLOW}Please enter your TLS certificate file path:${NC} ")
        read -p "$prompt" CERT_FILE
        if [ -f "$CERT_FILE" ]; then
          break
        else
          echo -e "${RED}Certificate file does not exist: $CERT_FILE${NC}"
        fi
      done

      while true; do
        prompt=$(echo -e "${YELLOW}Please enter your TLS private key file path:${NC} ")
        read -p "$prompt" KEY_FILE
        if [ -f "$KEY_FILE" ]; then
          break
        else
          echo -e "${RED}Private key file does not exist: $KEY_FILE${NC}"
        fi
      done

      echo -e "${GREEN}Using custom TLS certificate${NC}"
    fi

    if [ "$TLS_MODE" != "2" ]; then
      if ! command -v caddy &>/dev/null; then
        echo -e "${GREEN}Caddy not installed, installing...${NC}"
        if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
          apt update >/dev/null 2>&1
          apt install -y debian-keyring debian-archive-keyring >/dev/null 2>&1
          $DOWNLOAD_CMD 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
          $DOWNLOAD_CMD 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null 2>&1
          apt update >/dev/null 2>&1
          apt install -y caddy >/dev/null 2>&1
        elif [ "$OS" == "centos" ]; then
          dnf install 'dnf-command(copr)' >/dev/null 2>&1
          dnf -y copr enable @caddy/caddy >/dev/null 2>&1
          dnf install -y caddy >/dev/null 2>&1
        fi

        if ! command -v caddy &>/dev/null; then
          echo -e "${RED}Caddy installation failed, please check error messages.${NC}"
          exit 1
        else
          echo -e "${GREEN}Caddy installation complete${NC}"
        fi
      else
        echo -e "${GREEN}Caddy is already installed${NC}"
      fi

      cat >>/etc/caddy/Caddyfile <<EOF

$INPUT {
    reverse_proxy localhost:$PORT
}
EOF

      caddy reload --config /etc/caddy/Caddyfile &>/dev/null
      [ "$?" = 0 ] && echo -e "${GREEN}Caddy reverse proxy for $INPUT is now active${NC}"
    fi
  fi

  while true; do
    prompt=$(echo -e "${YELLOW}Please enter the port to use (default 3000): ${NC}")
    read -p "$prompt" PORT
    PORT=${PORT:-3000}


    if ! validate_port "$PORT" "$TLS_MODE"; then
      continue
    fi

    if command -v lsof &>/dev/null; then
      if lsof -i:$PORT &>/dev/null; then
        echo -e "${RED}Port $PORT is already in use, please choose another port.${NC}"
        continue
      fi
    elif command -v netstat &>/dev/null; then
      if netstat -tuln | grep ":$PORT" &>/dev/null; then
        echo -e "${RED}Port $PORT is already in use, please choose another port.${NC}"
        continue
      fi
    elif command -v ss &>/dev/null; then
      if ss -tuln | grep ":$PORT" &>/dev/null; then
        echo -e "${RED}Port $PORT is already in use, please choose another port.${NC}"
        continue
      fi
    else
      echo -e "${GREEN}lsof, netstat or ss not detected, installing iproute2...${NC}"
      if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
        apt update >/dev/null 2>&1
        apt install -y iproute2 >/dev/null 2>&1
      elif [ "$OS" == "centos" ]; then
        yum install -y iproute >/dev/null 2>&1
      fi
      echo -e "${GREEN}iproute2 installation complete, checking port...${NC}"
      if ss -tuln | grep ":$PORT" &>/dev/null; then
        echo -e "${RED}Port $PORT is already in use, please choose another port.${NC}"
        continue
      fi
    fi
    break
  done


  mkdir -p ~/nodepassdash/logs ~/nodepassdash/db

  if $CONTAINER_CMD inspect nodepassdash &>/dev/null; then
    echo -e "${RED}nodepassdash container already exists, exiting script.${NC}"
    exit 1
  fi

  echo -e "${GREEN}Downloading latest nodepassdash image...${NC}"
  $CONTAINER_CMD pull ghcr.io/nodepassproject/nodepassdash:latest

  echo -e "${GREEN}Running nodepassdash container...${NC}"

  CONTAINER_RUN_CMD="$CONTAINER_CMD run -d \
    --name nodepassdash \
    --network host \
    --restart always \
    -v ~/nodepassdash/logs:/app/logs \
    -v ~/nodepassdash/public:/app/public \
    -v ~/nodepassdash/db:/app/db \
    -e PORT=$PORT"

  if [ "$TLS_MODE" = "2" ]; then
    CONTAINER_RUN_CMD="$CONTAINER_RUN_CMD \
    -v $CERT_FILE:/app/certs/$(basename $CERT_FILE):ro \
    -v $KEY_FILE:/app/certs/$(basename $KEY_FILE):ro \
    -e TLS_CERT=/app/certs/$(basename $CERT_FILE) \
    -e TLS_KEY=/app/certs/$(basename $KEY_FILE)"
  fi

  CONTAINER_RUN_CMD="$CONTAINER_RUN_CMD \
    ghcr.io/nodepassproject/nodepassdash:latest"

  eval $CONTAINER_RUN_CMD


  echo -e "${GREEN}Getting dashboard and administrator account information...${NC}"

  LOG_CHECK_COMMAND="$CONTAINER_CMD logs nodepassdash 2>&1"

  TIMEOUT=60
  ELAPSED=0
  INTERVAL=2

  while [[ $ELAPSED -lt $TIMEOUT ]]; do
    eval "$LOG_CHECK_COMMAND" | grep -q "Administrator Account Information" && break
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo -e "${RED}Unable to get administrator account information after ${TIMEOUT} seconds, please check container logs:${NC}"
    eval "$LOG_CHECK_COMMAND"
  else
    echo -e "${GREEN}Administrator account information successfully retrieved.${NC}"
  fi

  if [[ "$INPUT" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
    echo -e "${GREEN}Dashboard address: http://[$INPUT]:$PORT${NC}"
  elif [[ "$INPUT" =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; then
    echo -e "${GREEN}Dashboard address: http://$INPUT:$PORT${NC}"
  else
    [ "$TLS_MODE" = "2" ] && echo -e "${GREEN}Dashboard address: https://$INPUT:$PORT${NC}" || echo -e "${GREEN}Dashboard address: https://$INPUT${NC}"
  fi

  eval "$LOG_CHECK_COMMAND" | grep -A 5 "Administrator Account Information"

  echo -e "${GREEN}Script runs today: $TODAY, Total runs: $TOTAL${NC}"
}

check_os

check_download_cmd


case "$1" in
"update")
  # If container management tool doesn't exist and is not installed, try to install
  if ! command -v $CONTAINER_CMD &>/dev/null; then
    install_container_runtime
  fi
  update_nodepassdash
  ;;
"uninstall")
  # If container management tool doesn't exist and is not installed, try to install
  if ! command -v $CONTAINER_CMD &>/dev/null; then
    install_container_runtime
  fi
  uninstall_nodepassdash
  ;;
"resetpwd")
  # If container management tool doesn't exist and is not installed, try to install
  if ! command -v $CONTAINER_CMD &>/dev/null; then
    install_container_runtime
  fi
  reset_admin_password
  ;;
"install")
  # If container management tool doesn't exist and is not installed, try to install
  if ! command -v $CONTAINER_CMD &>/dev/null; then
    install_container_runtime
  fi
  install_nodepassdash
  ;;
"help"|"")
  show_help
  ;;
*)
  echo -e "${RED}Error: Unknown parameter '$1'${NC}"
  show_help
  exit 1
  ;;
esac
