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
DATA_DIR="/root/.aztec/testnet/data"
AZTEC_IMAGE="aztecprotocol/aztec:2.1.2"
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
NETWORK="testnet"
GOVERNANCE_PROPOSER_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"
DASHTEC_URL="https://dashtec.xyz"

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

print_warning() {
  echo -e "\033[1;33m[WARNING]\033[0m $1"
}

# 函数：检查命令是否存在
check_command() {
  command -v "$1" >/dev/null 2>&1
}

# 函数：比较版本号
version_ge() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# 函数：安装依赖
install_package() {
  local pkg=$1
  print_info "安装 $pkg..."
  apt-get install -y "$pkg" >/dev/null 2>&1 || {
    print_error "安装 $pkg 失败"
    exit 1
  }
}

# 更新 apt 源
update_apt() {
  if [ -z "${APT_UPDATED:-}" ]; then
    print_info "更新 apt 源..."
    apt-get update >/dev/null 2>&1
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
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - >/dev/null 2>&1
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y >/dev/null 2>&1
  update_apt
  install_package "docker-ce docker-ce-cli containerd.io"
}

# 检查并安装 Docker Compose
install_docker_compose() {
  if check_command docker-compose || docker compose version >/dev/null 2>&1; then
    local version
    version=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
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
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash - >/dev/null 2>&1
  update_apt
  install_package nodejs
}

# 终极 Foundry 安装：检测 + 预编译 + 兜底
install_foundry() {
  # 确保 PATH 包含 foundry
  export PATH="$HOME/.foundry/bin:$PATH"

  if check_command cast; then
    local version=$(cast --version 2>/dev/null | head -n1 || echo "unknown")
    print_info "Foundry 已安装，跳过安装: $version"
    return
  fi

  print_warning "Foundry 未检测到，开始自动安装..."

  update_apt
  install_package "build-essential pkg-config libssl-dev jq curl"

  local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local arch=$(uname -m)
  local tmpdir="/tmp/foundry-install"
  mkdir -p "$tmpdir" ~/.foundry/bin
  cd "$tmpdir"

  # 策略 1: 预编译 nightly
  local url="https://github.com/foundry-rs/foundry/releases/download/nightly/foundry_nightly_${os}_${arch}.tar.gz"
  print_info "下载预编译 Foundry nightly..."

  if curl -L --connect-timeout 10 --retry 3 -o foundry.tar.gz "$url" --silent --show-error; then
    local size=$(wc -c < foundry.tar.gz)
    if [ "$size" -gt 10000000 ]; then
      if tar -xzf foundry.tar.gz -C ~/.foundry/bin/ >/dev/null 2>&1; then
        export PATH="$HOME/.foundry/bin:$PATH"
        if cast --version >/dev/null 2>&1; then
          print_success "预编译 Foundry 安装成功: $(cast --version | head -n1)"
          cd / && rm -rf "$tmpdir"
          return
        fi
      fi
    fi
  fi

  # 策略 2: foundryup 兜底
  print_warning "预编译失败，执行 foundryup..."
  cd /
  rm -rf "$tmpdir"

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

# 安装 Aztec CLI
install_aztec_cli() {
  print_info "安装 Aztec CLI..."
  if ! curl -sL "$AZTEC_CLI_URL" | bash; then
    print_error "Aztec CLI 安装失败。"
    exit 1
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! aztec-up latest; then
    print_error "aztec-up latest 执行失败。"
    exit 1
  fi
}

# 授权 STAKE 代币
authorize_stake() {
  local private_key=$1
  local rpc_url=$2
  print_info "授权 200k STAKE 给 Rollup 合约..."
  if ! cast send $STAKE_TOKEN "approve(address,uint256)" $ROLLUP_CONTRACT 200000ether \
    --private-key "$private_key" --rpc-url "$rpc_url"; then
    print_error "STAKE 授权失败！请检查："
    print_error "1. 私钥是否正确"
    print_error "2. 地址是否有 200k STAKE"
    print_error "3. RPC 是否可用"
    exit 1
  fi
  print_success "STAKE 授权成功！"
}

# 生成 BLS 密钥
generate_bls_keys() {
  print_info "生成新的 BLS 密钥对..."
  rm -rf "$HOME/.aztec/keystore"
  if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000; then
    print_error "BLS 密钥生成失败。"
    exit 1
  fi
  local key_file="$HOME/.aztec/keystore/key1.json"
  if [ ! -f "$key_file" ]; then
    print_error "未找到生成的密钥文件。"
    exit 1
  fi
  if ! check_command jq; then install_package jq; fi
  local eth_private_key=$(jq -r '.eth' "$key_file")
  local bls_private_key=$(jq -r '.bls' "$key_file")
  local attester_address=$(cast wallet address --private-key "$eth_private_key")
  echo "$eth_private_key" "$bls_private_key" "$attester_address"
}

# 注册验证者
register_validator() {
  local old_private_key=$1
  local attester_address=$2
  local bls_private_key=$3
  local rpc_url=$4
  local withdraw_address=$5
  print_info "注册验证者到 L1..."
  if ! aztec add-l1-validator \
    --l1-rpc-urls "$rpc_url" \
    --network testnet \
    --private-key "$old_private_key" \
    --attester "$attester_address" \
    --withdrawer "$withdraw_address" \
    --bls-secret-key "$bls_private_key" \
    --rollup $ROLLUP_CONTRACT; then
    print_error "验证者注册失败！请检查网络、RPC 和参数"
    exit 1
  fi
  print_success "验证者注册成功！"
}

# 验证输入
validate_url() { [[ "$1" =~ ^https?:// ]] || { print_error "$2 格式无效"; exit 1; }; }
validate_address() { [[ "$1" =~ ^0x[a-fA-F0-9]{40}$ ]] || { print_error "$2 格式无效"; exit 1; }; }
validate_private_key() { [[ "$1" =~ ^0x[a-fA-F0-9]{64}$ ]] || { print_error "$2 格式无效"; exit 1; }; }

# 查看节点状态
check_node_status() {
  print_info "=== 节点状态检查 ==="
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    local status=$(docker inspect aztec-sequencer --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
    echo -e " 容器状态: \033[1;32m$status\033[0m"
    docker port aztec-sequencer 8080 >/dev/null 2>&1 && echo -e " RPC 8080: \033[1;32m可用\033[0m" || echo -e " RPC 8080: \033[1;31m不可用\033[0m"
    docker port aztec-sequencer 40400 >/dev/null 2>&1 && echo -e " P2P 40400: \033[1;32m可用\033[0m" || echo -e " P2P 40400: \033[1;31m不可用\033[0m"
  else
    echo -e " 容器: \033[1;31m未运行\033[0m"
  fi
  echo; read -n 1 -s -r -p "按任意键继续..."
}

# 安装并启动节点
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
  read eth_private_key bls_private_key attester_address <<< $(generate_bls_keys)
  print_success "新验证者地址: $attester_address"
  print_warning "请给新地址转 0.2 ETH gas 费！"

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

# 主菜单
main_menu() {
  while true; do
    clear
    echo -e "\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m      Aztec 2.1.2 测试网节点管理脚本\033[0m"
    echo -e "\033[1;36m           (社区终极修复版)\033[0m"
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
    read -p "请选择 (1-8): " choice
    case $choice in
      1) install_and_start_node; read -n 1 -s -r -p "按任意键继续..." ;;
      2) docker logs -f --tail 100 aztec-sequencer 2>/dev/null || print_error "未运行" ;;
      3) check_node_status ;;
      4) grep -q "COINBASE" "$AZTEC_DIR/.env" 2>/dev/null && echo "排队地址: $(grep COINBASE "$AZTEC_DIR/.env" | cut -d= -f2)"; read -n 1 ;;
      5) grep -q "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env" 2>/dev/null && cast wallet address --private-key "$(grep VALIDATOR_PRIVATE_KEYS "$AZTEC_DIR/.env" | cut -d= -f2)"; read -n 1 ;;
      6) docker stop aztec-sequencer; docker rm aztec-sequencer; aztec-up latest; docker pull $AZTEC_IMAGE; cd "$AZTEC_DIR"; docker compose up -d || docker-compose up -d; print_success "更新完成"; read -n 1 ;;
      7) read -p "确认删除？(y/n): " c; [[ $c == y ]] && docker stop aztec-sequencer; docker rm aztec-sequencer; rm -rf "$AZTEC_DIR" "$DATA_DIR"; print_success "已删除"; read -n 1 ;;
      8) exit 0 ;;
      *) print_error "无效选项"; read -n 1 ;;
    esac
  done
}

# 启动
main_menu
