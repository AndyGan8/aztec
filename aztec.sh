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

# 修复 Foundry 安装（使用预编译二进制）
install_foundry() {
  if check_command cast; then
    print_info "Foundry 已安装（$(cast --version 2>/dev/null || echo 'unknown')）"
    return
  fi

  print_info "安装 Foundry（预编译二进制，快速稳定）..."

  local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local arch=$(uname -m)
  local latest=$(curl -s --connect-timeout 10 --retry 3 \
    https://api.github.com/repos/foundry-rs/foundry/releases/latest | grep tag_name | cut -d '"' -f 4)

  if [ -z "$latest" ]; then
    print_error "无法获取 Foundry 最新版本，请检查网络"
    exit 1
  fi

  local url="https://github.com/foundry-rs/foundry/releases/download/${latest}/foundry_${latest}_${os}_${arch}.tar.gz"
  local tmpdir="/tmp/foundry-install"

  mkdir -p "$tmpdir" ~/.foundry/bin
  cd "$tmpdir"

  print_info "下载 Foundry $latest ..."
  if ! curl -L --connect-timeout 10 --retry 3 -o foundry.tar.gz "$url"; then
    print_error "下载失败，请检查网络"
    exit 1
  fi

  tar -xzf foundry.tar.gz -C ~/.foundry/bin/ || {
    print_error "解压失败"
    exit 1
  }

  export PATH="$HOME/.foundry/bin:$PATH"

  if cast --version >/dev/null 2>&1; then
    print_success "Foundry 安装成功: $(cast --version)"
  else
    print_error "Foundry 安装失败"
    exit 1
  fi

  cd /
  rm -rf "$tmpdir"
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
  
  if ! check_command jq; then
    install_package jq
  fi
  
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

# 查看节点状态
check_node_status() {
  print_info "=== 节点状态检查 ==="
  echo
  
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    CONTAINER_STATUS=$(docker inspect aztec-sequencer --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [ "$CONTAINER_STATUS" = "running" ]; then
      echo -e " Aztec 容器: \033[1;32m运行中\033[0m"
      
      if docker port aztec-sequencer 8080 >/dev/null 2>&1; then
        echo -e " RPC 端口 (8080): \033[1;32m可用\033[0m"
      else
        echo -e " RPC 端口 (8080): \033[1;31m不可用\033[0m"
      fi

      if docker port aztec-sequencer 40400 >/dev/null 2>&1; then
        echo -e " P2P 端口 (40400): \033[1;32m可用\033[0m"
      else
        echo -e " P2P 端口 (40400): \033[1;31m不可用\033[0m"
      fi

      LOGS_COUNT=$(docker logs --tail 5 aztec-sequencer 2>/dev/null | wc -l)
      if [ "$LOGS_COUNT" -gt 0 ]; then
        echo -e " 日志输出: \033[1;32m正常\033[0m"
        SYNC_STATUS=$(docker logs --tail 10 aztec-sequencer 2>/dev/null | grep -E "pending sync from L1|synced|block|testnet" | tail -1)
        [ -n "$SYNC_STATUS" ] && echo " 同步状态: $(echo "$SYNC_STATUS" | cut -c1-60)..."
      else
        echo -e " 日志输出: \033[1;31m无输出\033[0m"
      fi
    else
      echo -e " Aztec 容器: \033[1;31m$CONTAINER_STATUS\033[0m"
    fi
  else
    echo -e " Aztec 容器: \033[1;31m未运行\033[0m"
  fi
  
  echo
  echo "按任意键返回主菜单..."
  read -n 1
}

# 主逻辑：安装和启动 Aztec 节点
install_and_start_node() {
  print_info "清理旧的配置和数据..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/docker-compose.yml"
  rm -rf /tmp/aztec-world-state-*
  rm -rf "$DATA_DIR"
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  install_docker
  install_docker_compose
  install_nodejs
  install_foundry
  install_aztec_cli

  clear
  print_info "Aztec 2.1.2 测试网节点安装 (社区优化版)"
  echo "=========================================="
  print_warning "重要提示："
  print_info "1. 需要旧地址有 200k STAKE 用于授权"
  print_info "2. 会自动生成新的 BLS 密钥对"
  print_info "3. 注册后会在 dashtec.xyz 显示排队"
  print_info "4. 新地址需要 Sepolia ETH 作为 gas"
  echo "=========================================="

  read -p "L1 执行 RPC URL (Sepolia): " ETH_RPC
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC
  read -p "旧验证者私钥 (有 200k STAKE): " OLD_VALIDATOR_PRIVATE_KEY
  read -p "提款地址 (推荐用旧地址): " WITHDRAW_ADDRESS

  validate_url "$ETH_RPC" "L1 执行 RPC URL"
  validate_url "$CONS_RPC" "L1 共识 RPC URL"
  validate_private_key "$OLD_VALIDATOR_PRIVATE_KEY" "旧验证者私钥"
  validate_address "$WITHDRAW_ADDRESS" "提款地址"

  OLD_ADDRESS=$(cast wallet address --private-key "$OLD_VALIDATOR_PRIVATE_KEY")
  print_info "旧验证者地址: $OLD_ADDRESS"

  authorize_stake "$OLD_VALIDATOR_PRIVATE_KEY" "$ETH_RPC"

  read eth_private_key bls_private_key attester_address <<< $(generate_bls_keys)
  
  print_success "新验证者地址: $attester_address"
  print_warning "请确保给新地址转 0.1-0.3 Sepolia ETH！"

  register_validator "$OLD_VALIDATOR_PRIVATE_KEY" "$attester_address" "$bls_private_key" "$ETH_RPC" "$WITHDRAW_ADDRESS"

  print_info "创建配置目录..."
  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  chmod -R 755 "$AZTEC_DIR" "$DATA_DIR"

  print_info "配置防火墙..."
  ufw allow 40400/tcp >/dev/null 2>&1 || true
  ufw allow 40400/udp >/dev/null 2>&1 || true
  ufw allow 8080/tcp >/dev/null 2>&1 || true

  print_info "获取公共 IP..."
  PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me || echo "127.0.0.1")
  print_info "公网 IP: $PUBLIC_IP"

  print_info "生成配置文件..."
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

  print_info "生成 Docker 配置..."
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

  print_info "启动 Aztec 节点..."
  cd "$AZTEC_DIR"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose up -d || { print_error "启动失败"; exit 1; }
  else
    docker-compose up -d || { print_error "启动失败"; exit 1; }
  fi

  echo
  print_success "Aztec 2.1.2 节点部署完成！"
  echo
  print_info "=== 重要信息 ==="
  print_info "旧验证者地址: $OLD_ADDRESS"
  print_info "新验证者地址: $attester_address"
  print_info "提款地址: $WITHDRAW_ADDRESS"
  echo
  print_info "=== 下一步操作 ==="
  print_info "1. 查看排队状态: $DASHTEC_URL/validator/$attester_address"
  print_info "2. 给新地址转 ETH:"
  echo "   cast send $attester_address --value 0.2ether --private-key $OLD_VALIDATOR_PRIVATE_KEY --rpc-url $ETH_RPC"
  print_info "3. 查看日志: docker logs -f aztec-sequencer"
  print_info "4. 配置目录: $AZTEC_DIR"
  echo
  print_warning "注意: 验证者需要排队，约40分钟一个 epoch"
}

# 其余函数（view_logs, check_queue_status, show_validator_info, stop_and_update_node, delete_node_data）保持不变
# 为节省篇幅，省略（可从原脚本复制）

# 主菜单
main_menu() {
  while true; do
    clear
    echo -e "\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m      Aztec 2.1.2 测试网节点管理脚本\033[0m"
    echo -e "\033[1;36m           (社区优化版)\033[0m"
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
    read -p "请输入选项 (1-8): " choice

    case $choice in
      1) install_and_start_node; read -n 1 -s -r -p "按任意键继续..." ;;
      2) docker logs -f --tail 100 aztec-sequencer 2>/dev/null || print_error "节点未运行" ;;
      3) check_node_status ;;
      4) 
        if [ -f "$AZTEC_DIR/.env" ] && grep -q "COINBASE" "$AZTEC_DIR/.env"; then
          addr=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2)
          echo "新验证者地址: $addr"
          echo "排队查询: $DASHTEC_URL/validator/$addr"
        else
          print_error "未找到节点配置"
        fi
        read -n 1 -s -r -p "按任意键继续..."
        ;;
      5)
        if [ -f "$AZTEC_DIR/.env" ]; then
          key=$(grep "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env" | cut -d= -f2)
          addr=$(cast wallet address --private-key "$key" 2>/dev/null || echo "未知")
          coinbase=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2)
          echo "验证者地址: $addr"
          echo "收益地址: $coinbase"
          [ -f "$HOME/.aztec/keystore/key1.json" ] && echo "BLS 密钥: 已生成" || echo "BLS 密钥: 未生成"
        else
          print_error "未找到配置"
        fi
        read -n 1 -s -r -p "按任意键继续..."
        ;;
      6)
        read -p "确认更新？(y/n): " c
        [[ "$c" = "y" ]] || continue
        docker stop aztec-sequencer 2>/dev/null || true
        docker rm aztec-sequencer 2>/dev/null || true
        aztec-up latest
        docker pull $AZTEC_IMAGE
        cd "$AZTEC_DIR" && docker compose up -d 2>/dev/null || docker-compose up -d
        print_success "更新完成"
        read -n 1 -s -r -p "按任意键继续..."
        ;;
      7)
        read -p "确认删除所有数据？(y/n): " c
        [[ "$c" = "y" ]] || continue
        docker stop aztec-sequencer 2>/dev/null || true
        docker rm aztec-sequencer 2>/dev/null || true
        rm -rf "$AZTEC_DIR" "$DATA_DIR" /tmp/aztec-world-state-*
        print_success "删除完成"
        read -n 1 -s -r -p "按任意键继续..."
        ;;
      8) print_info "退出脚本。"; exit 0 ;;
      *) print_error "无效选项"; read -n 1 -s -r -p "按任意键继续..." ;;
    esac
  done
}

main_menu
