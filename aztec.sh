#!/usr/bin/env bash
set -euo pipefail

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "本脚本必须以 root 权限运行。"
  exit 1
fi

# 定义常量
MIN_DOCKER_VERSION="20.10"
MIN_COMPOSE_VERSION="1.29.2"
AZTEC_CLI_URL="https://install.aztec.network"
AZTEC_DIR="/root/aztec"
DATA_DIR="/root/.aztec/alpha-testnet/data0"
AZTEC_IMAGE="aztecprotocol/aztec:2.1.2"
GOVERNANCE_PROPOSER_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"
SNAPSHOT_URL_1="https://snapshots.aztec.graphops.xyz/files/"

# 函数：打印信息
print_info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_success() {
  echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

print_error() {
  echo -e "\033[1;31m[ERROR]\033[0m $1"
}

# 函数：检查命令是否存在
check_command() {
  command -v "$1" &> /dev/null
}

# 函数：比较版本号
version_ge() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# 函数：安装依赖
install_package() {
  local pkg=$1
  print_info "安装 $pkg..."
  apt-get install -y "$pkg"
}

# 更新 apt 源
update_apt() {
  if [ -z "${APT_UPDATED:-}" ]; then
    print_info "更新 apt 源..."
    apt-get update
    APT_UPDATED=1
  fi
}

# 检查并安装 Docker
install_docker() {
  if check_command docker; then
    local version
    version=$(docker --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_DOCKER_VERSION"; then
      print_info "Docker 已安装，版本 $version。"
      return
    else
      print_info "Docker 版本过低，将重新安装..."
    fi
  else
    print_info "安装 Docker..."
  fi
  update_apt
  install_package "apt-transport-https ca-certificates curl gnupg-agent software-properties-common"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  update_apt
  install_package "docker-ce docker-ce-cli containerd.io"
}

# 检查并安装 Docker Compose
install_docker_compose() {
  if check_command docker-compose || docker compose version &> /dev/null; then
    local version
    version=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || docker compose version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_COMPOSE_VERSION"; then
      print_info "Docker Compose 已安装，版本 $version。"
      return
    else
      print_info "Docker Compose 版本过低，将重新安装..."
    fi
  else
    print_info "安装 Docker Compose..."
  fi
  update_apt
  install_package docker-compose-plugin
}

# 检查并安装 Node.js
install_nodejs() {
  if check_command node; then
    local version
    version=$(node --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    print_info "Node.js 已安装，版本 $version。"
    return
  fi
  print_info "安装 Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  update_apt
  install_package nodejs
}

# 安装 Aztec CLI + Foundry
install_aztec_cli_and_foundry() {
  print_info "安装 Aztec CLI..."
  if ! curl -sL "$AZTEC_CLI_URL" | bash; then
    print_error "Aztec CLI 安装失败。"
    exit 1
  fi
  export PATH="$HOME/.aztec/bin:$PATH"

  print_info "安装 Foundry (cast)...
  curl -L https://foundry.paradigm.xyz | bash
  source /root/.bashrc
  foundryup

  if ! check_command cast; then
    print_error "Foundry 安装失败。"
    exit 1
  fi
}

# 验证 URL 格式
validate_url() {
  local url=$1
  local name=$2
  if [[ ! "$url" =~ ^https?:// ]]; then
    print_error "$name 格式无效。"
    exit 1
  fi
}

# 验证以太坊地址格式
validate_address() {
  local address=$1
  local name=$2
  if [[ ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "$name 格式无效。"
    exit 1
  fi
}

# 验证私钥格式
validate_private_key() {
  local key=$1
  local name=$2
  if [[ ! "$key" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    print_error "$name 格式无效。"
    exit 1
  fi
}

# 生成新的 Validator 密钥对（ETH + BLS）
generate_validator_keys() {
  print_info "生成新的 Validator 密钥对（ETH + BLS）..."

  rm -rf "$HOME/.aztec/keystore"
  mkdir -p "$HOME/.aztec/keystore"

  aztec validator-keys new --fee-recipient "$COINBASE" > /dev/null 2>&1 || {
    print_error "密钥生成失败！请检查 aztec CLI 是否正常。"
    return 1
  }

  KEY_FILE="$HOME/.aztec/keystore/key1.json"
  if [ ! -f "$KEY_FILE" ]; then
    print_error "密钥文件未生成！"
    return 1
  fi

  ETH_PRIVATE_KEY=$(jq -r '.eth' "$KEY_FILE")
  BLS_PRIVATE_KEY=$(jq -r '.bls' "$KEY_FILE")
  ETH_ATTESTER_ADDRESS=$(cast wallet address --private-key "$ETH_PRIVATE_KEY")

  print_success "新密钥生成成功！"
  echo "   Attester 地址: $ETH_ATTESTER_ADDRESS"
  echo "   ETH 私钥: $ETH_PRIVATE_KEY"
  echo "   BLS 私钥: $BLS_PRIVATE_KEY"
}

# 执行 L1 Validator 注册
register_l1_validator() {
  print_info "开始 L1 Validator 注册..."

  # Step 1: Approve 200k STAKE
  print_info "Step 1: Approve 200k STAKE..."
  cast send 0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A \
    "approve(address,uint256)" \
    0xebd99ff0ff6677205509ae73f93d0ca52ac85d67 \
    200000ether \
    --private-key "$OLD_SEQUENCER_PRIVATE_KEY" \
    --rpc-url "$ETH_RPC" && \
  print_success "Approve 成功！" || {
    print_error "Approve 失败！请检查私钥是否有 200k STAKE"
    return 1
  }

  # Step 2: 注册 Validator
  print_info "Step 2: 注册 L1 Validator..."
  aztec add-l1-validator \
    --l1-rpc-urls "$ETH_RPC" \
    --network testnet \
    --private-key "$OLD_SEQUENCER_PRIVATE_KEY" \
    --attester "$ETH_ATTESTER_ADDRESS" \
    --withdrawer "$COINBASE" \
    --bls-secret-key "$BLS_PRIVATE_KEY" \
    --rollup 0xebd99ff0ff6677205509ae73f93d0ca52ac85d67 && \
  print_success "注册成功！" || {
    print_error "注册失败！请检查参数或网络"
    return 1
  }

  print_success "L1 注册完成！"
  echo
  print_info "请访问 https://dashtec.xyz 查询排队状态："
  echo "   Attester 地址: $ETH_ATTESTER_ADDRESS"
  echo
  print_info "建议给新地址转 0.1+ Sepolia ETH 用于 gas："
  echo "   cast send $ETH_ATTESTER_ADDRESS --value 0.1ether --private-key YOUR_FAUCET_KEY --rpc-url $ETH_RPC"
}

# 安装并启动节点
install_and_start_node() {
  print_info "开始安装 Aztec 2.1.2 节点..."

  # 清理旧数据
  rm -rf "$AZTEC_DIR" "$DATA_DIR" /tmp/aztec-world-state-*
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  # 安装依赖
  install_docker
  install_docker_compose
  install_nodejs
  install_aztec_cli_and_foundry

  # 创建目录
  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  chmod -R 755 "$AZTEC_DIR" "$DATA_DIR"

  # 配置防火墙
  ufw allow 40400/tcp >/dev/null 2>&1 || true
  ufw allow 40400/udp >/dev/null 2>&1 || true
  ufw allow 8080/tcp >/dev/null 2>&1 || true

  # 获取用户输入
  clear
  print_info "请输入以下信息（2.1.2 注册所需）："
  read -p "L1 执行 RPC (Alchemy/Infura): " ETH_RPC
  read -p "L1 共识 Beacon RPC: " CONS_RPC
  read -p "旧 Sequencer 私钥 (有 200k STAKE): " OLD_SEQUENCER_PRIVATE_KEY
  read -p "COINBASE 地址 (奖励接收): " COINBASE

  validate_url "$ETH_RPC" "执行 RPC"
  validate_url "$CONS_RPC" "共识 RPC"
  validate_private_key "$OLD_SEQUENCER_PRIVATE_KEY" "旧私钥"
  validate_address "$COINBASE" "COINBASE"

  # 生成新密钥 + 注册
  generate_validator_keys
  register_l1_validator

  # 获取公网 IP
  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
  print_info "公网 IP: $PUBLIC_IP"

  # 生成 .env
  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_RPC_URL=$ETH_RPC
CONSENSUS_BEACON_URL=$CONS_RPC
P2P_IP=$PUBLIC_IP
VALIDATOR_PRIVATE_KEYS=$OLD_SEQUENCER_PRIVATE_KEY
COINBASE=$COINBASE
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=$GOVERNANCE_PROPOSER_PAYLOAD
EOF

  # 生成 docker-compose.yml（社区最新版）
  cat > "$AZTEC_DIR/docker-compose.yml" <<EOF
services:
  aztec-node:
    container_name: aztec-sequencer
    image: $AZTEC_IMAGE
    restart: unless-stopped
    network_mode: host
    environment:
      ETHEREUM_HOSTS: \${ETHEREUM_RPC_URL}
      L1_CONSENSUS_HOST_URLS: \${CONSENSUS_BEACON_URL}
      DATA_DIRECTORY: /data
      VALIDATOR_PRIVATE_KEYS: \${VALIDATOR_PRIVATE_KEYS}
      COINBASE: \${COINBASE}
      P2P_IP: \${P2P_IP}
      GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS: \${GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS}
      LOG_LEVEL: info
      LOG_FORMAT: json
      LOG_FILTER: warn,error
      LMDB_MAX_READERS: 32
    mem_limit: 4G
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
        compress: "true"
    entrypoint: >
      sh -c 'node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start 
      --network testnet --node --archiver --sequencer'
    volumes:
      - $DATA_DIR:/data
EOF

  # 启动节点
  cd "$AZTEC_DIR"
  print_info "启动节点..."
  docker compose up -d

  print_success "Aztec 2.1.2 节点部署完成！"
  echo
  print_info "查看日志: docker logs -f aztec-sequencer"
  print_info "查排队: https://dashtec.xyz → 输入 $ETH_ATTESTER_ADDRESS"
  print_info "配置目录: $AZTEC_DIR"
}

# 查看节点日志
view_logs() {
  docker logs -f --tail 100 aztec-sequencer 2>/dev/null || echo "节点未运行"
}

# 查看节点状态
check_node_status() {
  print_info "节点状态检查..."
  docker ps -a --filter "name=aztec-sequencer"
  echo
  print_info "最新日志："
  docker logs --tail 10 aztec-sequencer 2>/dev/null || echo "无日志"
}

# 主菜单
main_menu() {
  while true; do
    clear
    echo "=================================="
    echo "   Aztec 2.1.2 节点管理脚本"
    echo "=================================="
    echo "1. 安装并启动节点（自动注册）"
    echo "2. 查看节点日志"
    echo "3. 查看节点状态"
    echo "4. 退出"
    echo "=================================="
    read -p "请选择 (1-4): " choice

    case $choice in
      1) install_and_start_node; read -n 1 ;;
      2) view_logs ;;
      3) check_node_status; read -n 1 ;;
      4) exit 0 ;;
      *) echo "无效选项"; read -n 1 ;;
    esac
  done
}

# 执行主菜单
main_menu
