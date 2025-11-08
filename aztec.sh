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
DATA_DIR="/root/.aztec/testnet/data"
AZTEC_IMAGE="aztecprotocol/aztec:2.1.2"
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
NETWORK="testnet"
GOVERNANCE_PROPOSER_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"
DASHTEC_URL="https://dashtec.xyz"

# ==================== 打印函数 ====================
print_info()    { echo -e "\033[1;34m[INFO]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1" >&2; }
print_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1" >&2; }

# ==================== 工具函数 ====================
check_command() { command -v "$1" >/dev/null 2>&1; }
version_ge() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

install_package() {
  local pkg=$1
  print_info "安装 $pkg..."
  apt-get install -y "$pkg" >/dev/null 2>&1 || { print_error "安装 $pkg 失败"; exit 1; }
}

update_apt() {
  [ -z "${APT_UPDATED:-}" ] && {
    print_info "更新 apt 源..."
    apt-get update >/dev/null 2>&1
    APT_UPDATED=1
  }
}

# ==================== 依赖安装 ====================
install_docker() {
  if check_command docker; then
    local v=$(docker --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    version_ge "$v" "$MIN_DOCKER_VERSION" && { print_info "Docker 已安装，版本 $v"; return; }
  fi
  print_info "安装 Docker..."
  update_apt
  install_package "apt-transport-https ca-certificates curl gnupg-agent software-properties-common"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - >/dev/null 2>&1
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y >/dev/null 2>&1
  update_apt
  install_package "docker-ce docker-ce-cli containerd.io"
}

install_docker_compose() {
  if check_command docker-compose || docker compose version >/dev/null 2>&1; then
    local v=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    version_ge "$v" "$MIN_COMPOSE_VERSION" && { print_info "Docker Compose 已安装，版本 $v"; return; }
  fi
  print_info "安装 Docker Compose..."
  update_apt
  install_package docker-compose-plugin
}

install_nodejs() {
  if check_command node; then
    local v=$(node --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    print_info "Node.js 已安装，版本 $v"
    return
  fi
  print_info "安装 Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash - >/dev/null 2>&1
  update_apt
  install_package nodejs
}

# ==================== Foundry 安装（终极修复） ====================
install_foundry() {
  export PATH="$HOME/.foundry/bin:$PATH"
  if check_command cast; then
    local v=$(cast --version 2>/dev/null | head -n1 || echo "unknown")
    print_info "Foundry 已安装: $v"
    return
  fi

  print_warning "Foundry 未检测到，开始自动安装..."

  update_apt
  install_package "build-essential pkg-config libssl-dev jq curl"

  local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local arch=$(uname -m)
  local tmp="/tmp/foundry-install"
  mkdir -p "$tmp" ~/.foundry/bin
  cd "$tmp"

  # 策略 1: 预编译 nightly
  local url="https://github.com/foundry-rs/foundry/releases/download/nightly/foundry_nightly_${os}_${arch}.tar.gz"
  print_info "下载预编译 Foundry nightly..."
  if curl -L --connect-timeout 10 --retry 3 -o foundry.tar.gz "$url" --silent --show-error; then
    [ "$(wc -c < foundry.tar.gz)" -gt 10000000 ] && {
      tar -xzf foundry.tar.gz -C ~/.foundry/bin/ >/dev/null 2>&1 && {
        if cast --version >/dev/null 2>&1; then
          print_success "预编译 Foundry 安装成功: $(cast --version | head -n1)"
          cd / && rm -rf "$tmp"
          return
        fi
      }
    }
  fi

  # 策略 2: foundryup
  print_warning "预编译失败，执行 foundryup..."
  cd /
  rm -rf "$tmp"
  curl -L https://foundry.paradigm.xyz | bash >/dev/null 2>&1
  export PATH="$HOME/.foundry/bin:$PATH"
  ~/.foundry/bin/foundryup >/dev/null 2>&1 || true

  if cast --version >/dev/null 2>&1; then
    print_success "Foundry 安装成功 (foundryup): $(cast --version | head -n1)"
  else
    print_error "Foundry 安装失败，请手动运行：foundryup"
    exit 1
  fi
}

# ==================== Aztec CLI ====================
install_aztec_cli() {
  print_info "安装 Aztec CLI..."
  curl -sL "$AZTEC_CLI_URL" | bash >/dev/null 2>&1 || { print_error "Aztec CLI 安装失败"; exit 1; }
  export PATH="$HOME/.aztec/bin:$PATH"
  aztec-up latest >/dev/null 2>&1 || { print_error "aztec-up latest 失败"; exit 1; }
}

# ==================== 核心功能 ====================
authorize_stake() {
  local pk=$1 rpc=$2
  print_info "授权 200k STAKE..."
  cast send $STAKE_TOKEN "approve(address,uint256)" $ROLLUP_CONTRACT 200000ether \
    --private-key "$pk" --rpc-url "$rpc" >/dev/null 2>&1 || {
    print_error "STAKE 授权失败！请检查：私钥、余额、RPC"
    exit 1
  }
  print_success "STAKE 授权成功！"
}

# 关键修复：BLS 密钥生成（静默返回，使用 printf 避免污染 stdout）
generate_bls_keys() {
  print_info "生成新的 BLS 密钥对..."
  rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
  aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1 || {
    print_error "BLS 密钥生成失败"
    exit 1
  }
  local file="$HOME/.aztec/keystore/key1.json"
  [ ! -f "$file" ] && { print_error "密钥文件未生成"; exit 1; }
  [ ! -f "$(command -v jq)" ] && install_package jq
  local eth=$(jq -r '.eth' "$file")
  local bls=$(jq -r '.bls' "$file")
  local addr=$(cast wallet address --private-key "$eth" 2>/dev/null)
  [[ "$addr" =~ ^0x[a-fA-F0-9]{40}$ ]] || { print_error "地址生成失败"; exit 1; }
  print_success "新验证者地址: $addr" >&2
  printf "%s %s %s" "$eth" "$bls" "$addr"
}

register_validator() {
  local old_pk=$1 attester=$2 bls=$3 rpc=$4 withdraw=$5
  print_info "注册验证者到 L1..."
  aztec add-l1-validator \
    --l1-rpc-urls "$rpc" \
    --network testnet \
    --private-key "$old_pk" \
    --attester "$attester" \
    --withdrawer "$withdraw" \
    --bls-secret-key "$bls" \
    --rollup $ROLLUP_CONTRACT >/dev/null 2>&1 || {
    print_error "验证者注册失败！请检查网络、RPC、参数"
    exit 1
  }
  print_success "验证者注册成功！"
}

# 验证输入
validate_url() { [[ "$1" =~ ^https?:// ]] || { print_error "$2 格式无效"; exit 1; }; }
validate_address() { [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || { print_error "$2 格式无效"; exit 1; }; }
validate_private_key() { [[ "$1" =~ ^0x[a-fA-F0-9]{64}$ ]] || { print_error "$2 格式无效"; exit 1; }; }

# ==================== 节点安装主流程 ====================
install_and_start_node() {
  print_info "清理旧数据..."
  rm -rf "$AZTEC_DIR" "$DATA_DIR" /tmp/aztec-world-state-*
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  install_docker
  install_docker_compose
  install_nodejs
  install_foundry
  install_aztec_cli

  clear
  print_info "Aztec 2.1.2 测试网节点安装 (社区终极版)"
  echo "=========================================="
  print_warning "重要提示："
  print_info "1. 旧地址需有 200k STAKE"
  print_info "2. 新地址需 0.1-0.3 Sepolia ETH"
  print_info "3. 注册后在 dashtec.xyz 查看排队"
  echo "=========================================="

  read -p "L1 执行 RPC URL (Sepolia): " ETH_RPC
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC
  read -p "旧验证者私钥 (有 200k STAKE): " OLD_VALIDATOR_PRIVATE_KEY
  read -p "提款地址 (推荐旧地址): " WITHDRAW_ADDRESS

  validate_url "$ETH_RPC" "L1 执行 RPC"
  validate_url "$CONS_RPC" "L1 共识 RPC"
  validate_private_key "$OLD_VALIDATOR_PRIVATE_KEY" "旧私钥"
  validate_address "$WITHDRAW_ADDRESS" "提款地址"

  OLD_ADDRESS=$(cast wallet address --private-key "$OLD_VALIDATOR_PRIVATE_KEY")
  print_info "旧地址: $OLD_ADDRESS"

  authorize_stake "$OLD_VALIDATOR_PRIVATE_KEY" "$ETH_RPC"

  # 修复：静默读取密钥（printf 确保纯数据输出）
  read eth_private_key bls_private_key attester_address <<< $(generate_bls_keys)
  print_warning "请给 $attester_address 转 0.2 Sepolia ETH 作为 gas 费！"

  register_validator "$OLD_VALIDATOR_PRIVATE_KEY" "$attester_address" "$bls_private_key" "$ETH_RPC" "$WITHDRAW_ADDRESS"

  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  chmod -R 755 "$AZTEC_DIR" "$DATA_DIR"
  ufw allow 40400/tcp >/dev/null 2>&1 || true
  ufw allow 40400/udp >/dev/null 2>&1 || true
  ufw allow 8080/tcp >/dev/null 2>&1 || true

  PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me || echo "127.0.0.1")
  print_info "公网 IP: $PUBLIC_IP"

  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS=$ETH_RPC
L1_CONSENSUS_HOST_URLS=$CONS_RPC
P2P_IP=$PUBLIC_IP
VALIDATOR_PRIVATE_KEYS=$eth_private_key
COINBASE=$attester_address
DATA_DIRECTORY=/data
LOG_LEVEL=info
LOG_FORMAT=json
LOG_FILTER=warn,error
LMDB_MAX_READERS=32
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=$GOVERNANCE_PROPOSER_PAYLOAD
EOF

  cat > "$AZTEC_DIR/docker-compose.yml" <<EOF
services:
  aztec-node:
    container_name: aztec-sequencer
    image: $AZTEC_IMAGE
    restart: unless-stopped
    network_mode: host
    environment:
      ETHEREUM_HOSTS: \${ETHEREUM_HOSTS}
      L1_CONSENSUS_HOST_URLS: \${L1_CONSENSUS_HOST_URLS}
      DATA_DIRECTORY: \${DATA_DIRECTORY}
      VALIDATOR_PRIVATE_KEYS: \${VALIDATOR_PRIVATE_KEYS}
      COINBASE: \${COINBASE}
      P2P_IP: \${P2P_IP}
      GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS: \${GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS}
      LOG_LEVEL: \${LOG_LEVEL}
      LOG_FORMAT: \${LOG_FORMAT}
      LOG_FILTER: \${LOG_FILTER}
      LMDB_MAX_READERS: \${LMDB_MAX_READERS}
    mem_limit: 4G
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
        compress: "true"
    entrypoint: >
      sh -c 'node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network testnet --node --archiver --sequencer'
    ports:
      - 40400:40400/tcp 
      - 40400:40400/udp 
      - 8080:8080 
      - 8880:8880 
    volumes:
      - $DATA_DIR:/data
EOF

  cd "$AZTEC_DIR"
  docker compose up -d 2>/dev/null || docker-compose up -d

  print_success "Aztec 节点部署完成！"
  echo
  print_info "新验证者: $attester_address"
  print_info "排队查询: $DASHTEC_URL/validator/$attester_address"
  print_info "转 gas 命令:"
  echo "   cast send $attester_address --value 0.2ether --private-key $OLD_VALIDATOR_PRIVATE_KEY --rpc-url $ETH_RPC"
  print_info "查看日志: docker logs -f aztec-sequencer"
  print_warning "排队约 40 分钟/epoch，请耐心等待"
}

# ==================== 菜单功能 ====================
check_node_status() {
  print_info "=== 节点状态 ==="
  docker ps -a --filter "name=aztec-sequencer" | grep -q aztec-sequencer || { echo "未运行" >&2; return; }
  local s=$(docker inspect aztec-sequencer --format='{{.State.Status}}')
  echo "状态: $s" >&2
  read -n 1 -s -r -p "按任意键继续..." >&2
}

view_logs() { docker logs -f --tail 100 aztec-sequencer 2>/dev/null || print_error "未运行"; }

check_queue() {
  [ -f "$AZTEC_DIR/.env" ] && grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2 | xargs -I{} echo "地址: {} | 查询: $DASHTEC_URL/validator/{}" >&2
  read -n 1 >&2
}

show_info() {
  [ -f "$AZTEC_DIR/.env" ] && {
    local key=$(grep VALIDATOR_PRIVATE_KEYS "$AZTEC_DIR/.env" | cut -d= -f2)
    local addr=$(cast wallet address --private-key "$key" 2>/dev/null || echo "未知")
    local coin=$(grep COINBASE "$AZTEC_DIR/.env" | cut -d= -f2)
    echo "验证者: $addr" >&2
    echo "收益: $coin" >&2
  }
  read -n 1 >&2
}

update_node() {
  docker stop aztec-sequencer; docker rm aztec-sequencer
  aztec-up latest
  docker pull $AZTEC_IMAGE
  cd "$AZTEC_DIR"; docker compose up -d || docker-compose up -d
  print_success "更新完成"
  read -n 1 >&2
}

delete_data() {
  read -p "确认删除？(y/n): " c; [[ $c != y ]] && return
  docker stop aztec-sequencer; docker rm aztec-sequencer
  rm -rf "$AZTEC_DIR" "$DATA_DIR"
  print_success "已删除"
  read -n 1 >&2
}

# ==================== 主菜单 ====================
main_menu() {
  while true; do
    clear
    echo -e "\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m      Aztec 2.1.2 测试网节点管理脚本\033[0m"
    echo -e "\033[1;36m           (社区终极修复版 v2.0)\033[0m"
    echo -e "\033[1;36m========================================\033[0m"
    echo "1. 安装并启动节点 (自动注册)"
    echo "2. 查看节点日志"
    echo "3. 查看节点状态"
    echo "4. 检查排队状态"
    echo "5. 显示验证者信息"
    echo "6. 停止和更新节点"
    echo "7. 删除节点数据"
    echo "8. 退出"
    echo -e "\033[1;36m========================================\033[0m"
    read -p "请选择 (1-8): " c
    case $c in
      1) install_and_start_node; read -n 1 >&2 ;;
      2) view_logs ;;
      3) check_node_status ;;
      4) check_queue ;;
      5) show_info ;;
      6) update_node ;;
      7) delete_data ;;
      8) exit 0 ;;
      *) print_error "无效选项"; read -n 1 >&2 ;;
    esac
  done
}

main_menu
