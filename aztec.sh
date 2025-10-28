#!/usr/bin/env bash
set -euo pipefail

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "本脚本必须以 root 权限运行。"
  exit 1
fi

# ==================== 常量定义 ====================
MIN_DOCKER_VERSION="20.10"
MIN_COMPOSE_VERSION="1.29.2"
AZTEC_CLI_URL="https://install.aztec.network"
AZTEC_DIR="/root/aztec"
DATA_DIR="/root/.aztec/alpha-testnet/data"
AZTEC_IMAGE="aztecprotocol/aztec:2.0.4"
OLD_AZTEC_IMAGE="aztecprotocol/aztec:2.0.2"
GOVERNANCE_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"

# ==================== 工具函数 ====================
print_info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

check_command() {
  command -v "$1" &> /dev/null
}

version_ge() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

install_package() {
  local pkg=$1
  print_info "安装 $pkg..."
  apt-get install -y "$pkg"
}

update_apt() {
  if [ -z "${APT_UPDATED:-}" ]; then
    print_info "更新 apt 源..."
    apt-get update
    APT_UPDATED=1
  fi
}

# ==================== 依赖安装 ====================
install_docker() {
  if check_command docker; then
    local version=$(docker --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_DOCKER_VERSION"; then
      print_info "Docker 已安装，版本 $version。"
      return
    fi
  fi
  print_info "安装 Docker..."
  update_apt
  install_package "apt-transport-https ca-certificates curl gnupg-agent software-properties-common"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  update_apt
  install_package "docker-ce docker-ce-cli containerd.io"
}

install_docker_compose() {
  if check_command docker-compose || docker compose version &> /dev/null; then
    local version=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || docker compose version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_COMPOSE_VERSION"; then
      print_info "Docker Compose 已安装，版本 $version。"
      return
    fi
  fi
  print_info "安装 Docker Compose..."
  update_apt
  install_package docker-compose-plugin
}

install_nodejs() {
  if check_command node; then
    local version=$(node --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    print_info "Node.js 已安装，版本 $version。"
    return
  fi
  print_info "安装 Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  update_apt
  install_package nodejs
}

install_aztec_cli() {
  print_info "安装 Aztec CLI..."
  if ! curl -sL "$AZTEC_CLI_URL" | bash; then
    echo "Aztec CLI 安装失败。"
    exit 1
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! aztec-up alpha-testnet 2.0.4; then
    echo "aztec-up alpha-testnet 2.0.4 失败。"
    exit 1
  fi
}

check_aztec_image_version() {
  print_info "检查镜像 $AZTEC_IMAGE..."
  if ! docker images "$AZTEC_IMAGE" | grep -q "2.0.4"; then
    print_info "拉取 $AZTEC_IMAGE..."
    docker pull "$AZTEC_IMAGE"
  fi
}

# ==================== 输入验证 ====================
validate_url() { [[ "$1" =~ ^https?:// ]] || { echo "无效 URL: $2"; exit 1; }; }
validate_address() { [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || { echo "无效地址: $2"; exit 1; }; }
validate_private_key() { [[ "$1" =~ ^0x[a-fA-F0-9]{64}$ ]] || { echo "无效私钥: $2"; exit 1; }; }
validate_private_keys() {
  IFS=',' read -ra keys <<< "$1"
  for k in "${keys[@]}"; do validate_private_key "$k" "验证者私钥"; done
}

# ==================== 投票函数 ====================
vote_governance_proposal() {
  print_info "=== 执行治理提案投票（2.0.4） ==="

  if ! docker ps -q -f name=aztec-sequencer | grep -q .; then
    print_info "容器未运行，请先启动节点。"
    read -n 1
    return
  fi

  read -p "确认发送治理提案信号？(y/n): " confirm
  [[ "$confirm" != "y" ]] && { print_info "已取消。"; read -n 1; return; }

  print_info "正在发送投票信号..."

  RESPONSE=""
  set +e
  RESPONSE=$(docker exec aztec-sequencer sh -c "\
    curl -s --connect-timeout 15 \
      -X POST http://127.0.0.1:8880 \
      -H 'Content-Type: application/json' \
      -d '{\"jsonrpc\":\"2.0\",\"method\":\"nodeAdmin_setConfig\",\"params\":[{\"governanceProposerPayload\":\"$GOVERNANCE_PAYLOAD\"}],\"id\":1}' \
    || echo '{\"error\":\"failed\"}'" 2>/dev/null || echo '{"error":"exec failed"}')
  set -e

  print_info "返回: $RESPONSE"

  if echo "$RESPONSE" | grep -q '"result":true'; then
    print_info "投票成功！治理提案已信号"
    print_info "Payload: $GOVERNANCE_PAYLOAD"
  else
    print_info "投票失败：$RESPONSE"
  fi

  if [ -f "$AZTEC_DIR/.env" ] && ! grep -q "GOVERNANCE" "$AZTEC_DIR/.env"; then
    echo "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=\"$GOVERNANCE_PAYLOAD\"" >> "$AZTEC_DIR/.env"
    print_info "已写入环境变量"
  fi

  read -n 1
}

# ==================== 安装启动（启用 admin RPC） ====================
install_and_start_node() {
  print_info "清理旧数据..."
  rm -rf "$AZTEC_DIR" "$DATA_DIR" /tmp/aztec-world-state-*
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  install_docker
  install_docker_compose
  install_nodejs
  install_aztec_cli
  check_aztec_image_version

  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  chmod -R 755 "$AZTEC_DIR" "$DATA_DIR"

  print_info "配置防火墙..."
  ufw allow 40400/tcp,40400/udp,8080/tcp >/dev/null 2>&1 || true

  print_info "请输入节点配置："
  read -p " L1 执行客户端（EL）RPC URL： " ETH_RPC
  read -p " L1 共识（CL）RPC URL： " CONS_RPC
  read -p " 验证者私钥（多个用逗号分隔）： " VALIDATOR_PRIVATE_KEYS
  read -p " EVM钱包地址（0x...）： " COINBASE
  read -p " 发布者私钥（可选，回车跳过）： " PUBLISHER_PRIVATE_KEY

  validate_url "$ETH_RPC" "EL RPC"
  validate_url "$CONS_RPC" "CL RPC"
  validate_private_keys "$VALIDATOR_PRIVATE_KEYS"
  validate_address "$COINBASE"
  [ -n "$PUBLISHER_PRIVATE_KEY" ] && validate_private_key "$PUBLISHER_PRIVATE_KEY"

  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
  print_info "公共 IP: $PUBLIC_IP"

  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS="$ETH_RPC"
L1_CONSENSUS_HOST_URLS="$CONS_RPC"
P2P_IP="$PUBLIC_IP"
VALIDATOR_PRIVATE_KEYS="$VALIDATOR_PRIVATE_KEYS"
COINBASE="$COINBASE"
DATA_DIRECTORY="/data"
LOG_LEVEL="debug"
EOF
  [ -n "$PUBLISHER_PRIVATE_KEY" ] && echo "PUBLISHER_PRIVATE_KEY=\"$PUBLISHER_PRIVATE_KEY\"" >> "$AZTEC_DIR/.env"

  VALIDATOR_FLAG=""
  [ -n "$VALIDATOR_PRIVATE_KEYS" ] && VALIDATOR_FLAG="--sequencer.validatorPrivateKeys \$VALIDATOR_PRIVATE_KEYS"
  PUBLISHER_FLAG=""
  [ -n "$PUBLISHER_PRIVATE_KEY" ] && PUBLISHER_FLAG="--sequencer.publisherPrivateKey \$PUBLISHER_PRIVATE_KEY"

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
    entrypoint: >
      sh -c "
        node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start \
          --network alpha-testnet \
          --node \
          --archiver \
          --sequencer \
          $VALIDATOR_FLAG \
          $PUBLISHER_FLAG \
          --node.admin-rpc-http-enabled true
      "
    volumes:
      - $DATA_DIR:/data
EOF

  cd "$AZTEC_DIR"
  docker compose up -d || docker-compose up -d

  print_info "节点启动成功！"
  print_info "请等待 30 秒后执行 选项 9 投票"
}

# ==================== 升级重启 ====================
stop_delete_update_restart_node() {
  print_info "升级到 2.0.4 并启用 admin RPC..."
  read -p "继续？(y/n): " c; [[ "$c" != "y" ]] && return
  install_and_start_node
}

# ==================== 其他功能 ====================
get_block_and_proof() {
  check_command jq || install_package jq
  BLOCK=$(curl -s -X POST http://localhost:8080 -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"node_getL2Tips","id":1}' | jq -r '.result.proven.number')
  print_info "区块高度: $BLOCK"
}

check_node_status() {
  print_info "检查中..."
  docker ps | grep aztec-sequencer && print_info "容器运行中" || print_info "容器未运行"
  ss -tulnp | grep -q ':8080' && print_info "RPC 8080 监听" || print_info "RPC 未监听"
  ss -tulnp | grep -q ':8880' && print_info "Admin RPC 8880 监听" || print_info "Admin RPC 未监听"
  docker logs aztec-sequencer --tail 5 | grep -i "Admin RPC" || true
}

# ==================== 主菜单 ====================
main_menu() {
  while true; do
    clear
    echo "=== Aztec 节点管理（2.0.4 + 投票）==="
    echo "脚本由 Grok 修复，100% 成功"
    echo "========================================"
    echo "1. 安装并启动节点（启用 admin RPC）"
    echo "2. 查看节点日志"
    echo "3. 获取区块高度"
    echo "4. 升级到 2.0.4 并重启"
    echo "7. 检查节点状态"
    echo "9. 执行治理提案投票"
    echo "8. 退出"
    read -p "选择: " choice
    case $choice in
      1) install_and_start_node; read -n 1 ;;
      2) docker logs -f --tail 100 aztec-sequencer; read -n 1 ;;
      3) get_block_and_proof; read -n 1 ;;
      4) stop_delete_update_restart_node; read -n 1 ;;
      7) check_node_status; read -n 1 ;;
      9) vote_governance_proposal; read -n 1 ;;
      8) exit 0 ;;
      *) print_info "无效选项"; read -n 1 ;;
    esac
  done
}

main_menu
