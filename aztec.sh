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
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  update_apt
  install_package nodejs
}

# 安装 Foundry
install_foundry() {
  if check_command cast; then
    print_info "Foundry 已安装。"
    return
  fi
  print_info "安装 Foundry..."
  curl -L https://foundry.paradigm.xyz | bash
  source /root/.bashrc
  if ! foundryup; then
    print_error "Foundry 安装失败。"
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
  
  # 清理旧的密钥
  rm -rf "$HOME/.aztec/keystore"
  
  if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000; then
    print_error "BLS 密钥生成失败。"
    exit 1
  fi
  
  # 读取生成的密钥
  local key_file="$HOME/.aztec/keystore/key1.json"
  if [ ! -f "$key_file" ]; then
    print_error "未找到生成的密钥文件。"
    exit 1
  fi
  
  # 检查 jq 是否安装
  if ! check_command jq; then
    install_package jq
  fi
  
  # 提取 ETH 和 BLS 私钥
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
    print_error "验证者注册失败！请检查："
    print_error "1. 网络连接"
    print_error "2. RPC 服务"
    print_error "3. 参数是否正确"
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
  
  # 检查容器状态
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    CONTAINER_STATUS=$(docker inspect aztec-sequencer --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [ "$CONTAINER_STATUS" = "running" ]; then
      echo -e " Aztec 容器: \033[1;32m运行中\033[0m"
      
      # 检查端口状态
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

      # 检查进程状态
      if docker exec aztec-sequencer ps aux 2>/dev/null | grep -q "node"; then
        echo -e " Node.js 进程: \033[1;32m运行中\033[0m"
      else
        echo -e " Node.js 进程: \033[1;31m未运行\033[0m"
      fi

      # 检查日志状态
      LOGS_COUNT=$(docker logs --tail 5 aztec-sequencer 2>/dev/null | wc -l)
      if [ "$LOGS_COUNT" -gt 0 ]; then
        echo -e " 日志输出: \033[1;32m正常\033[0m"
        
        # 显示最近的同步状态
        SYNC_STATUS=$(docker logs --tail 10 aztec-sequencer 2>/dev/null | grep -E "pending sync from L1|synced|block|testnet" | tail -1)
        if [ -n "$SYNC_STATUS" ]; then
          echo " 同步状态: $(echo "$SYNC_STATUS" | cut -c1-60)..."
        fi
        
        # 检查网络
        NETWORK_STATUS=$(docker logs --tail 20 aztec-sequencer 2>/dev/null | grep -E "testnet|network" | tail -1)
        if [ -n "$NETWORK_STATUS" ]; then
          echo " 网络: testnet"
        fi
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
  
  # 检查配置文件
  if [ -f "$AZTEC_DIR/.env" ]; then
    echo -e " 配置文件: \033[1;32m存在\033[0m"
    
    # 检查验证者配置
    if grep -q "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env"; then
      VALIDATOR_KEY=$(grep "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"')
      VALIDATOR_ADDRESS=$(cast wallet address --private-key "$VALIDATOR_KEY" 2>/dev/null || echo "未知")
      echo " 当前验证者地址: $VALIDATOR_ADDRESS"
    fi

    if grep -q "COINBASE" "$AZTEC_DIR/.env"; then
      COINBASE=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"')
      echo " 收益地址: $COINBASE"
    fi
  else
    echo -e " 配置文件: \033[1;31m不存在\033[0m"
  fi
  
  echo
  echo "按任意键返回主菜单..."
  read -n 1
}

# 主逻辑：安装和启动 Aztec 节点
install_and_start_node() {
  # 清理旧配置和数据
  print_info "清理旧的配置和数据..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/docker-compose.yml"
  rm -rf /tmp/aztec-world-state-*
  rm -rf "$DATA_DIR"
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  # 安装依赖
  install_docker
  install_docker_compose
  install_nodejs
  install_foundry
  install_aztec_cli

  # 获取用户输入
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

  # 验证输入
  validate_url "$ETH_RPC" "L1 执行 RPC URL"
  validate_url "$CONS_RPC" "L1 共识 RPC URL"
  validate_private_key "$OLD_VALIDATOR_PRIVATE_KEY" "旧验证者私钥"
  validate_address "$WITHDRAW_ADDRESS" "提款地址"

  # 显示旧地址信息
  OLD_ADDRESS=$(cast wallet address --private-key "$OLD_VALIDATOR_PRIVATE_KEY")
  print_info "旧验证者地址: $OLD_ADDRESS"

  # 授权 STAKE
  authorize_stake "$OLD_VALIDATOR_PRIVATE_KEY" "$ETH_RPC"

  # 生成 BLS 密钥
  print_info "生成新的 BLS 密钥对..."
  read eth_private_key bls_private_key attester_address <<< $(generate_bls_keys)
  
  print_success "新验证者地址: $attester_address"
  print_warning "请确保给新地址转 0.1-0.3 Sepolia ETH 用于 gas 费！"

  # 注册验证者
  register_validator "$OLD_VALIDATOR_PRIVATE_KEY" "$attester_address" "$bls_private_key" "$ETH_RPC" "$WITHDRAW_ADDRESS"

  # 创建配置目录
  print_info "创建配置目录..."
  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  chmod -R 755 "$AZTEC_DIR" "$DATA_DIR"

  # 配置防火墙
  print_info "配置防火墙..."
  ufw allow 40400/tcp >/dev/null 2>&1 || true
  ufw allow 40400/udp >/dev/null 2>&1 || true
  ufw allow 8080/tcp >/dev/null 2>&1 || true

  # 获取公共 IP
  print_info "获取公共 IP..."
  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
  print_info "公网 IP: $PUBLIC_IP"

  # 生成 .env 文件 (使用新生成的密钥)
  print_info "生成配置文件..."
  cat > "$AZTEC_DIR/.env" <<EOF
# Aztec 2.1.2 测试网配置
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

  # 生成 docker-compose.yml 文件 (社区推荐配置)
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

  # 启动节点
  print_info "启动 Aztec 节点..."
  cd "$AZTEC_DIR"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if ! docker compose up -d; then
      print_error "启动失败。"
      exit 1
    fi
  elif command -v docker-compose >/dev/null 2>&1; then
    if ! docker-compose up -d; then
      print_error "启动失败。"
      exit 1
    fi
  else
    print_error "未找到 docker compose。"
    exit 1
  fi

  # 显示完成信息
  echo
  print_success "Aztec 2.1.2 节点部署完成！"
  echo
  print_info "=== 重要信息 ==="
  print_info "旧验证者地址: $OLD_ADDRESS"
  print_info "新验证者地址: $attester_address"
  print_info "提款地址: $WITHDRAW_ADDRESS"
  echo
  print_info "=== 下一步操作 ==="
  print_info "1. 查看排队状态: $DASHTEC_URL"
  print_info "   输入新地址: $attester_address"
  print_info "2. 给新地址转 Sepolia ETH (0.1-0.3):"
  echo "   cast send $attester_address --value 0.2ether --private-key $OLD_VALIDATOR_PRIVATE_KEY --rpc-url $ETH_RPC"
  print_info "3. 查看节点日志: docker logs -f aztec-sequencer"
  print_info "4. 配置目录: $AZTEC_DIR"
  echo
  print_warning "注意: 验证者需要排队，请耐心等待 epoch (约40分钟)"
}

# 查看节点日志
view_logs() {
  if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    print_info "查看节点日志 (Ctrl+C 退出)..."
    docker logs -f --tail 100 aztec-sequencer
  else
    print_error "未找到节点配置。"
  fi
}

# 获取排队状态
check_queue_status() {
  if [ -f "$AZTEC_DIR/.env" ]; then
    if grep -q "COINBASE" "$AZTEC_DIR/.env"; then
      NEW_ADDRESS=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2)
      print_info "新验证者地址: $NEW_ADDRESS"
      print_info "请在 $DASHTEC_URL 查询排队状态"
      print_info "或直接访问: $DASHTEC_URL/validator/$NEW_ADDRESS"
    else
      print_error "未找到新验证者地址。"
    fi
  else
    print_error "未找到节点配置。"
  fi
  echo
  echo "按任意键继续..."
  read -n 1
}

# 给新地址转账
fund_new_address() {
  if [ -f "$AZTEC_DIR/.env" ] && [ -n "${OLD_VALIDATOR_PRIVATE_KEY:-}" ] && [ -n "${ETH_RPC:-}" ]; then
    if grep -q "COINBASE" "$AZTEC_DIR/.env"; then
      NEW_ADDRESS=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2)
      print_info "给新地址转账 0.2 Sepolia ETH..."
      read -p "确认转账？(y/n): " confirm
      if [[ "$confirm" == "y" ]]; then
        if cast send "$NEW_ADDRESS" --value 0.2ether --private-key "$OLD_VALIDATOR_PRIVATE_KEY" --rpc-url "$ETH_RPC"; then
          print_success "转账成功！"
        else
          print_error "转账失败！"
        fi
      fi
    else
      print_error "未找到新验证者地址。"
    fi
  else
    print_error "无法执行转账，请先安装节点。"
  fi
}

# 停止和更新节点
stop_and_update_node() {
  print_info "停止和更新节点..."

  if [ ! -f "$AZTEC_DIR/docker-compose.yml" ]; then
    print_error "未找到节点配置。"
    return
  fi

  read -p "确认操作？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    return
  fi

  # 停止并删除容器
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    docker stop aztec-sequencer
    docker rm aztec-sequencer
  fi

  # 更新 Aztec CLI
  export PATH="$HOME/.aztec/bin:$PATH"
  aztec-up latest

  # 拉取最新镜像
  docker pull "$AZTEC_IMAGE"

  # 重新启动
  cd "$AZTEC_DIR"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose up -d
  else
    docker-compose up -d
  fi

  print_success "更新完成！"
}

# 删除节点数据
delete_node_data() {
  print_info "删除节点数据..."

  read -p "确认删除？此操作不可逆！(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    return
  fi

  # 停止并删除容器
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    docker stop aztec-sequencer
    docker rm aztec-sequencer
  fi

  # 删除配置和数据
  rm -rf "$AZTEC_DIR"
  rm -rf "$DATA_DIR"
  rm -rf /tmp/aztec-world-state-*

  print_success "删除完成！"
}

# 显示验证者信息
show_validator_info() {
  print_info "=== 验证者信息 ==="
  
  if [ -f "$AZTEC_DIR/.env" ]; then
    if grep -q "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env"; then
      VALIDATOR_KEY=$(grep "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"')
      VALIDATOR_ADDRESS=$(cast wallet address --private-key "$VALIDATOR_KEY" 2>/dev/null || echo "未知")
      echo -e " 当前验证者地址: \033[1;36m$VALIDATOR_ADDRESS\033[0m"
    fi
    
    if grep -q "COINBASE" "$AZTEC_DIR/.env"; then
      COINBASE=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"')
      echo -e " 收益地址: \033[1;36m$COINBASE\033[0m"
    fi
  else
    print_error "未找到节点配置。"
  fi
  
  # 检查密钥文件
  if [ -f "$HOME/.aztec/keystore/key1.json" ]; then
    echo -e " BLS 密钥: \033[1;32m已生成\033[0m"
  else
    echo -e " BLS 密钥: \033[1;31m未生成\033[0m"
  fi
  
  echo
  echo "按任意键继续..."
  read -n 1
}

# 主菜单函数
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
    echo "5. 给新地址转账"
    echo "6. 显示验证者信息"
    echo "7. 停止和更新节点"
    echo "8. 删除节点数据"
    echo "9. 退出"
    echo -e "\033[1;36m========================================\033[0m"
    read -p "请输入选项 (1-9): " choice

    case $choice in
      1)
        install_and_start_node
        echo "按任意键继续..."
        read -n 1
        ;;
      2)
        view_logs
        ;;
      3)
        check_node_status
        ;;
      4)
        check_queue_status
        ;;
      5)
        fund_new_address
        echo "按任意键继续..."
        read -n 1
        ;;
      6)
        show_validator_info
        ;;
      7)
        stop_and_update_node
        echo "按任意键继续..."
        read -n 1
        ;;
      8)
        delete_node_data
        echo "按任意键继续..."
        read -n 1
        ;;
      9)
        print_info "退出脚本。"
        exit 0
        ;;
      *)
        print_error "无效选项。"
        echo "按任意键继续..."
        read -n 1
        ;;
    esac
  done
}

# 执行主菜单
main_menu
