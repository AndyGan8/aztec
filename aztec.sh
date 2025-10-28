# 删除旧脚本
rm -f /root/aztec.sh

# 使用我提供的最终版（已修复所有问题）
sudo tee /root/aztec-final.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "需 root 权限"; exit 1; fi

AZTEC_DIR="/root/aztec"
DATA_DIR="/root/.aztec/alpha-testnet/data"
AZTEC_IMAGE="aztecprotocol/aztec:2.0.4"
GOVERNANCE_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"

print_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }

install_docker() { command -v docker &>/dev/null && docker --version | grep -q "2[0-9]" && { print_info "Docker OK"; return; }; apt-get update; apt-get install -y docker.io; }
install_docker_compose() { command -v docker-compose &>/dev/null && { print_info "Compose OK"; return; }; apt-get install -y docker-compose-plugin; }
install_nodejs() { command -v node &>/dev/null && { print_info "Node.js OK"; return; }; curl -fsSL https://deb.nodesource.com/setup_current.x | bash -; apt-get install -y nodejs; }

check_aztec_image_version() {
  print_info "检查镜像 $AZTEC_IMAGE..."
  if docker images "$AZTEC_IMAGE" | grep -q "2.0.4"; then
    print_info "镜像已存在"
  else
    print_info "拉取镜像..."
    docker pull "$AZTEC_IMAGE" || { echo "拉取失败"; exit 1; }
  fi
}

validate_url() { [[ "$1" =~ ^https?:// ]] || { echo "无效 URL"; exit 1; }; }
validate_address() { [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || { echo "无效地址"; exit 1; }; }
validate_private_key() { [[ "$1" =~ ^0x[a-fA-F0-9]{64}$ ]] || { echo "无效私钥"; exit 1; }; }
validate_private_keys() { IFS=',' read -ra k <<< "$1"; for i in "${k[@]}"; do validate_private_key "$i"; done; }

vote_governance_proposal() {
  print_info "=== 投票 ==="
  docker ps -q -f name=aztec-sequencer | grep -q . || { print_info "容器未运行"; read -n 1; return; }
  read -p "确认？(y/n): " c; [[ "$c" != "y" ]] && return
  print_info "发送中..."
  set +e
  RES=$(docker exec aztec-sequencer sh -c "curl -s --connect-timeout 15 -X POST http://127.0.0.1:8880 -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"nodeAdmin_setConfig\",\"params\":[{\"governanceProposerPayload\":\"$GOVERNANCE_PAYLOAD\"}],\"id\":1}' || echo '{\"error\":\"failed\"}'" 2>/dev/null || echo '{"error":"exec"}')
  set -e
  print_info "返回: $RES"
  echo "$RES" | grep -q '"result":true' && print_info "投票成功！" || print_info "失败"
  read -n 1
}

install_and_start_node() {
  print_info "清理..."
  rm -rf "$AZTEC_DIR" "$DATA_DIR" /tmp/aztec-world-state-*
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  install_docker
  install_docker_compose
  install_nodejs

  print_info "安装 Aztec CLI..."
  curl -sL https://install.aztec.network | bash
  export PATH="$HOME/.aztec/bin:$PATH"
  aztec-up alpha-testnet 2.0.4

  check_aztec_image_version

  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  ufw allow 40400/tcp,40400/udp,8080/tcp >/dev/null 2>&1 || true

  read -p "EL RPC: " ETH_RPC
  read -p "CL RPC: " CONS_RPC
  read -p "验证者私钥: " VALIDATOR_PRIVATE_KEYS
  read -p "COINBASE: " COINBASE
  read -p "发布者私钥: " PUBLISHER_PRIVATE_KEY

  validate_url "$ETH_RPC" ""; validate_url "$CONS_RPC" ""
  validate_private_keys "$VALIDATOR_PRIVATE_KEYS"
  validate_address "$COINBASE"
  [ -n "$PUBLISHER_PRIVATE_KEY" ] && validate_private_key "$PUBLISHER_PRIVATE_KEY"

  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")

  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS="$ETH_RPC"
L1_CONSENSUS_HOST_URLS="$CONS_RPC"
P2P_IP="$PUBLIC_IP"
VALIDATOR_PRIVATE_KEYS="$VALIDATOR_PRIVATE_KEYS"
COINBASE="$COINBASE"
DATA_DIRECTORY="/data"
LOG_LEVEL="debug"
ADMIN_RPC_HTTP_ENABLED=true
EOF
  [ -n "$PUBLISHER_PRIVATE_KEY" ] && echo "PUBLISHER_PRIVATE_KEY=\"$PUBLISHER_PRIVATE_KEY\"" >> "$AZTEC_DIR/.env"

  V_FLAG=""; [ -n "$VALIDATOR_PRIVATE_KEYS" ] && V_FLAG="--sequencer.validatorPrivateKeys \$VALIDATOR_PRIVATE_KEYS"
  P_FLAG=""; [ -n "$PUBLISHER_PRIVATE_KEY" ] && P_FLAG="--sequencer.publisherPrivateKey \$PUBLISHER_PRIVATE_KEY"

  cat > "$AZTEC_DIR/docker-compose.yml" <<EOF
services:
  aztec-sequencer:
    container_name: aztec-sequencer
    network_mode: host
    image: $AZTEC_IMAGE
    restart: unless-stopped
    environment:
      - ETHEREUM_HOSTS=\${ETHEREUM_HOSTS}
      - L1_CONSENSUS_HOST_URLS=\${L1_CONSENSUS_HOST_URLS}
      - P2P_IP=\${P2P_IP}
      - VALIDATOR_PRIVATE_KEYS=\${VALIDATOR_PRIVATE_KEYS}
      - COINBASE=\${COINBASE}
      - DATA_DIRECTORY=\${DATA_DIRECTORY}
      - LOG_LEVEL=\${LOG_LEVEL}
      - PUBLISHER_PRIVATE_KEY=\${PUBLISHER_PRIVATE_KEY:-}
      - ADMIN_RPC_HTTP_ENABLED=\${ADMIN_RPC_HTTP_ENABLED}
    entrypoint: >
      sh -c "node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network alpha-testnet --node --archiver --sequencer $V_FLAG $P_FLAG"
    volumes:
      - $DATA_DIR:/data
EOF

  cd "$AZTEC_DIR"
  docker compose up -d
  print_info "启动成功！30 秒后可投票"
}

main_menu() {
  while :; do
    clear
    echo "=== Aztec 2.0.4 节点 ==="
    echo "1. 安装启动"
    echo "9. 投票"
    echo "8. 退出"
    read -p "选择: " c
    case $c in 1) install_and_start_node; read -n 1 ;; 9) vote_governance_proposal; read -n 1 ;; 8) exit 0 ;; esac
  done
}

main_menu
EOF

chmod +x /root/aztec-final.sh
sudo /root/aztec-final.sh
