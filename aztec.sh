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

# 函数：打印信息
print_info() {
  echo "$1"
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
    echo "Foundry 安装失败。"
    exit 1
  fi
}

# 安装 Aztec CLI
install_aztec_cli() {
  print_info "安装 Aztec CLI..."
  if ! curl -sL "$AZTEC_CLI_URL" | bash; then
    echo "Aztec CLI 安装失败。"
    exit 1
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! aztec-up latest; then
    echo "aztec-up latest 执行失败。"
    exit 1
  fi
}

# 授权 STAKE 代币
authorize_stake() {
  local private_key=$1
  local rpc_url=$2
  
  print_info "授权 STAKE 代币..."
  if ! cast send $STAKE_TOKEN "approve(address,uint256)" $ROLLUP_CONTRACT 200000ether \
    --private-key "$private_key" --rpc-url "$rpc_url"; then
    echo "STAKE 授权失败。"
    exit 1
  fi
  print_info "STAKE 授权成功！"
}

# 生成 BLS 密钥
generate_bls_keys() {
  print_info "生成 BLS 密钥..."
  
  if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000; then
    echo "BLS 密钥生成失败。"
    exit 1
  fi
  
  # 读取生成的密钥
  local key_file="$HOME/.aztec/keystore/key1.json"
  if [ ! -f "$key_file" ]; then
    echo "未找到生成的密钥文件。"
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
  
  print_info "注册验证者..."
  if ! aztec add-l1-validator \
    --l1-rpc-urls "$rpc_url" \
    --network testnet \
    --private-key "$old_private_key" \
    --attester "$attester_address" \
    --withdrawer "$withdraw_address" \
    --bls-secret-key "$bls_private_key" \
    --rollup $ROLLUP_CONTRACT; then
    echo "验证者注册失败。"
    exit 1
  fi
  print_info "验证者注册成功！"
}

# 验证 URL 格式
validate_url() {
  local url=$1
  local name=$2
  if [[ ! "$url" =~ ^https?:// ]]; then
    echo "错误：$name 格式无效。"
    exit 1
  fi
}

# 验证以太坊地址格式
validate_address() {
  local address=$1
  local name=$2
  if [[ ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo "错误：$name 格式无效。"
    exit 1
  fi
}

# 验证私钥格式
validate_private_key() {
  local key=$1
  local name=$2
  if [[ ! "$key" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    echo "错误：$name 格式无效。"
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
      echo " Aztec 容器: 运行中"
      
      # 检查端口状态
      if docker port aztec-sequencer 8080 >/dev/null 2>&1; then
        echo " RPC 端口 (8080): 可用"
      else
        echo "  RPC 端口 (8080): 不可用"
      fi

      if docker port aztec-sequencer 40400 >/dev/null 2>&1; then
        echo " P2P 端口 (40400): 可用"
      else
        echo "  P2P 端口 (40400): 不可用"
      fi

      # 检查进程状态
      if docker exec aztec-sequencer ps aux 2>/dev/null | grep -q "node"; then
        echo " Node.js 进程: 运行中"
      else
        echo " Node.js 进程: 未运行"
      fi

      # 检查日志状态
      LOGS_COUNT=$(docker logs --tail 5 aztec-sequencer 2>/dev/null | wc -l)
      if [ "$LOGS_COUNT" -gt 0 ]; then
        echo " 日志输出: 正常"
        
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
        echo " 日志输出: 无输出"
      fi

    else
      echo " Aztec 容器: $CONTAINER_STATUS"
    fi
  else
    echo " Aztec 容器: 未运行"
  fi
  
  echo
  
  # 检查配置文件
  if [ -f "$AZTEC_DIR/.env" ]; then
    echo " 配置文件: 存在"
    
    # 检查 RPC 配置
    if grep -q "ETHEREUM_HOSTS" "$AZTEC_DIR/.env"; then
      ETH_RPC=$(grep "ETHEREUM_HOSTS" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"' | head -1)
      echo " 执行层 RPC: 已配置"
      
      # 处理多个执行层 RPC URL
      IFS=',' read -ra ETH_RPC_ARRAY <<< "$ETH_RPC"
      for i in "${!ETH_RPC_ARRAY[@]}"; do
        RPC_URL=$(echo "${ETH_RPC_ARRAY[$i]}" | tr -d ' ')
        echo "    $((i+1)). $RPC_URL"
        
        # 测试执行层 RPC 连接
        print_info "测试执行层 RPC $((i+1)) 连接..."
        ETH_RPC_STATUS=$(timeout 10 curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC_URL" 2>/dev/null | grep -o '"result"' || echo "failed")
        if [ "$ETH_RPC_STATUS" = '"result"' ]; then
          echo "    执行层 RPC $((i+1)): 连接正常"
          
          # 获取执行层最新区块
          ETH_BLOCK_HEX=$(timeout 10 curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC_URL" 2>/dev/null | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
          if [ -n "$ETH_BLOCK_HEX" ]; then
            ETH_BLOCK_DEC=$((16#${ETH_BLOCK_HEX#0x}))
            echo "    最新区块: $ETH_BLOCK_DEC"
          fi
        else
          echo "    执行层 RPC $((i+1)): 连接失败"
        fi
        echo
      done
    else
      echo " 执行层 RPC: 未配置"
    fi

    if grep -q "L1_CONSENSUS_HOST_URLS" "$AZTEC_DIR/.env"; then
      CONS_RPC=$(grep "L1_CONSENSUS_HOST_URLS" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"' | head -1)
      echo " 共识层 RPC: 已配置"
      
      # 处理多个共识层 RPC URL
      IFS=',' read -ra CONS_RPC_ARRAY <<< "$CONS_RPC"
      CONS_RPC_SUCCESS=false
      
      for i in "${!CONS_RPC_ARRAY[@]}"; do
        RPC_URL=$(echo "${CONS_RPC_ARRAY[$i]}" | tr -d ' ')
        echo "    $((i+1)). $RPC_URL"
        
        # 测试共识层 RPC 连接
        print_info "测试共识层 RPC $((i+1)) 连接..."
        
        # 尝试不同的 Beacon API 端点
        CONS_RPC_STATUS=$(timeout 10 curl -s -X GET "$RPC_URL/eth/v1/node/health" 2>/dev/null | head -1 | grep -o "200" || echo "failed")
        
        # 如果健康检查失败，尝试同步状态端点
        if [ "$CONS_RPC_STATUS" != "200" ]; then
          CONS_RPC_STATUS=$(timeout 10 curl -s -X GET "$RPC_URL/eth/v1/node/syncing" 2>/dev/null | head -1 | grep -o "200" || echo "failed")
        fi
        
        # 如果还是失败，尝试 genesis 端点
        if [ "$CONS_RPC_STATUS" != "200" ]; then
          CONS_RPC_STATUS=$(timeout 10 curl -s -X GET "$RPC_URL/eth/v1/beacon/genesis" 2>/dev/null | head -1 | grep -o "200" || echo "failed")
        fi
        
        if [ "$CONS_RPC_STATUS" = "200" ]; then
          echo "    共识层 RPC $((i+1)): 连接正常"
          CONS_RPC_SUCCESS=true
          
          # 获取共识层同步状态
          SYNC_RESPONSE=$(timeout 10 curl -s -X GET "$RPC_URL/eth/v1/node/syncing" 2>/dev/null)
          if [ -n "$SYNC_RESPONSE" ]; then
            SYNC_STATUS=$(echo "$SYNC_RESPONSE" | grep -o '"is_syncing":[^,]*' | cut -d':' -f2 | tr -d ' ' || echo "unknown")
            if [ "$SYNC_STATUS" = "false" ]; then
              echo "    同步状态: 已同步"
            elif [ "$SYNC_STATUS" = "true" ]; then
              echo "    同步状态: 同步中"
            else
              echo "    同步状态: 未知"
            fi
          fi
          
          # 获取链ID信息
          GENESIS_RESPONSE=$(timeout 10 curl -s -X GET "$RPC_URL/eth/v1/beacon/genesis" 2>/dev/null)
          if [ -n "$GENESIS_RESPONSE" ]; then
            CHAIN_ID=$(echo "$GENESIS_RESPONSE" | grep -o '"chain_id":"[^"]*"' | cut -d'"' -f4)
            if [ -n "$CHAIN_ID" ]; then
              echo "    链ID: $CHAIN_ID"
            fi
          fi
        else
          echo "    共识层 RPC $((i+1)): 连接失败"
        fi
        echo
      done
      
      # 总结共识层 RPC 状态
      if [ "$CONS_RPC_SUCCESS" = true ]; then
        echo "    共识层 RPC: 至少有一个连接正常"
      else
        echo "    共识层 RPC: 所有连接都失败"
      fi
    else
      echo " 共识层 RPC: 未配置"
    fi

    # 检查验证者配置
    if grep -q "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env"; then
      VALIDATOR_KEY=$(grep "VALIDATOR_PRIVATE_KEYS" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"')
      VALIDATOR_ADDRESS=$(cast wallet address --private-key "$VALIDATOR_KEY" 2>/dev/null || echo "未知")
      echo " 验证者地址: $VALIDATOR_ADDRESS"
    fi

  else
    echo " 配置文件: 不存在"
  fi
  
  echo
  
  # 系统资源状态
  echo "=== 系统资源 ==="
  
  # 内存使用
  MEM_TOTAL=$(free -m 2>/dev/null | awk 'NR==2{print $2}' || echo "0")
  if [ "$MEM_TOTAL" -gt 0 ]; then
    MEM_USED=$(free -m | awk 'NR==2{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    echo " 内存使用: ${MEM_PERCENT}%"
  else
    echo " 内存使用: 无法获取"
  fi
  
  # 磁盘使用
  DISK_USED=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' || echo "0%")
  echo " 磁盘使用: $DISK_USED"
  
  # CPU 负载
  if [ -f /proc/loadavg ]; then
    LOAD_AVG=$(cat /proc/loadavg | awk '{print $1}')
    echo "  CPU负载: $LOAD_AVG"
  else
    echo "  CPU负载: 无法获取"
  fi
  
  echo
  echo "=== 网络连接 ==="
  
  # 检查网络连接
  if ping -c 1 -W 3 google.com &>/dev/null; then
    echo " 互联网连接: 正常"
  else
    echo " 互联网连接: 异常"
  fi
  
  # 检查 Docker 服务状态
  if systemctl is-active --quiet docker; then
    echo " Docker 服务: 运行中"
  else
    echo " Docker 服务: 未运行"
  fi
  
  echo
  echo "=== 建议操作 ==="
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    echo "1. 查看详细日志 (选项 2)"
    echo "2. 检查区块高度 (选项 3)"
    if [ "$CONS_RPC_SUCCESS" = false ]; then
      echo "3.   共识层 RPC 连接失败，请检查网络或更换 RPC 服务商"
    fi
    echo "4. 如遇问题可重启节点"
  else
    echo "1. 安装并启动节点 (选项 1)"
    echo "2. 检查配置文件"
    if [ "$CONS_RPC_SUCCESS" = false ]; then
      echo "3.   确认共识层 RPC 服务可用性"
    fi
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
  ETH_RPC="${ETH_RPC:-}"
  CONS_RPC="${CONS_RPC:-}"
  OLD_VALIDATOR_PRIVATE_KEY="${OLD_VALIDATOR_PRIVATE_KEY:-}"
  WITHDRAW_ADDRESS="${WITHDRAW_ADDRESS:-}"

  print_info "配置说明："
  print_info "  - L1 执行客户端 RPC URL (如 Alchemy 的 Sepolia RPC)"
  print_info "  - L1 共识 RPC URL (如 drpc.org 的 Beacon Chain Sepolia RPC)" 
  print_info "  - 旧验证者私钥 (有 STAKE 的地址)"
  print_info "  - 提款地址 (任意接收地址)"

  if [ -z "$ETH_RPC" ]; then
    read -p "L1 执行客户端 RPC URL: " ETH_RPC
  fi
  if [ -z "$CONS_RPC" ]; then
    read -p "L1 共识 RPC URL: " CONS_RPC
  fi
  if [ -z "$OLD_VALIDATOR_PRIVATE_KEY" ]; then
    read -p "旧验证者私钥: " OLD_VALIDATOR_PRIVATE_KEY
  fi
  if [ -z "$WITHDRAW_ADDRESS" ]; then
    read -p "提款地址: " WITHDRAW_ADDRESS
  fi

  # 验证输入
  validate_url "$ETH_RPC" "L1 执行客户端 RPC URL"
  validate_url "$CONS_RPC" "L1 共识 RPC URL"
  validate_private_key "$OLD_VALIDATOR_PRIVATE_KEY" "旧验证者私钥"
  validate_address "$WITHDRAW_ADDRESS" "提款地址"

  # 授权 STAKE
  authorize_stake "$OLD_VALIDATOR_PRIVATE_KEY" "$ETH_RPC"

  # 生成 BLS 密钥
  print_info "生成新的 BLS 密钥对..."
  read eth_private_key bls_private_key attester_address <<< $(generate_bls_keys)
  
  print_info "生成的新验证者地址: $attester_address"
  print_info "请确保该地址有足够的 ETH 用于 gas 费"

  # 注册验证者
  register_validator "$OLD_VALIDATOR_PRIVATE_KEY" "$attester_address" "$bls_private_key" "$ETH_RPC" "$WITHDRAW_ADDRESS"

  # 创建配置目录
  print_info "创建配置目录 $AZTEC_DIR..."
  mkdir -p "$AZTEC_DIR"
  chmod -R 755 "$AZTEC_DIR"

  # 配置防火墙
  print_info "配置防火墙..."
  ufw allow 40400/tcp >/dev/null 2>&1
  ufw allow 40400/udp >/dev/null 2>&1
  ufw allow 8080/tcp >/dev/null 2>&1

  # 获取公共 IP
  print_info "获取公共 IP..."
  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
  print_info "IP: $PUBLIC_IP"

  # 生成 .env 文件 (使用新生成的密钥)
  print_info "生成配置文件..."
  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS="$ETH_RPC"
L1_CONSENSUS_HOST_URLS="$CONS_RPC"
P2P_IP="$PUBLIC_IP"
VALIDATOR_PRIVATE_KEYS="$eth_private_key"
COINBASE="$attester_address"
DATA_DIRECTORY="/data"
LOG_LEVEL="info"
LOG_FORMAT="json"
LOG_FILTER="warn,error"
LMDB_MAX_READERS="32"
EOF

  # 生成 docker-compose.yml 文件
  cat > "$AZTEC_DIR/docker-compose.yml" <<EOF
services:
  aztec-node:
    container_name: aztec-sequencer
    image: $AZTEC_IMAGE
    restart: unless-stopped
    environment:
      ETHEREUM_HOSTS: \${ETHEREUM_HOSTS}
      L1_CONSENSUS_HOST_URLS: \${L1_CONSENSUS_HOST_URLS}
      P2P_IP: \${P2P_IP}
      VALIDATOR_PRIVATE_KEYS: \${VALIDATOR_PRIVATE_KEYS}
      COINBASE: \${COINBASE}
      DATA_DIRECTORY: \${DATA_DIRECTORY}
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

  # 创建数据目录
  mkdir -p "$DATA_DIR"
  chmod -R 755 "$DATA_DIR"

  # 启动节点
  print_info "启动 Aztec 节点..."
  cd "$AZTEC_DIR"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if ! docker compose up -d; then
      echo "启动失败。"
      exit 1
    fi
  elif command -v docker-compose >/dev/null 2>&1; then
    if ! docker-compose up -d; then
      echo "启动失败。"
      exit 1
    fi
  else
    echo "未找到 docker compose。"
    exit 1
  fi

  print_info "安装完成！"
  print_info "新验证者地址: $attester_address"
  print_info "旧验证者地址: $(cast wallet address --private-key "$OLD_VALIDATOR_PRIVATE_KEY")"
  print_info "查看日志: docker logs -f aztec-sequencer"
  print_info "配置目录: $AZTEC_DIR"
  print_info "数据目录: $DATA_DIR"
  print_info "请在 dashtec.xyz 使用新地址查看排队状态"
}

# 查看节点日志
view_logs() {
  if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    print_info "查看节点日志..."
    docker logs -f --tail 100 aztec-sequencer
  else
    print_info "未找到节点配置。"
  fi
}

# 获取区块高度和同步证明
get_block_and_proof() {
  if ! check_command jq; then
    print_info "安装 jq..."
    update_apt
    install_package jq
  fi

  if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    if ! docker ps -q -f name=aztec-sequencer | grep -q .; then
      print_info "节点未运行。"
      return
    fi

    print_info "获取区块高度..."
    BLOCK_NUMBER=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
      http://localhost:8080 | jq -r ".result.proven.number" || echo "")

    if [ -z "$BLOCK_NUMBER" ] || [ "$BLOCK_NUMBER" = "null" ]; then
      print_info "无法获取区块高度。"
      return
    fi

    print_info "当前区块高度: $BLOCK_NUMBER"
    print_info "获取同步证明..."
    PROOF=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d "$(jq -n --arg bn "$BLOCK_NUMBER" '{"jsonrpc":"2.0","method":"node_getArchiveSiblingPath","params":[$bn,$bn],"id":67}')" \
      http://localhost:8080 | jq -r ".result" || echo "")

    if [ -z "$PROOF" ] || [ "$PROOF" = "null" ]; then
      print_info "无法获取同步证明。"
    else
      print_info "同步证明: $PROOF"
    fi
  else
    print_info "未找到节点配置。"
  fi
}

# 停止和更新节点
stop_and_update_node() {
  print_info "停止和更新节点..."

  if [ ! -f "$AZTEC_DIR/docker-compose.yml" ]; then
    print_info "未找到节点配置。"
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

  print_info "更新完成！"
}

# 删除节点数据
delete_node_data() {
  print_info "删除节点数据..."

  read -p "确认删除？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    return
  fi

  # 停止并删除容器
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    docker stop aztec-sequencer
    docker rm aztec-sequencer
  fi

  # 删除镜像
  if docker images -q "aztecprotocol/aztec" | grep -q .; then
    docker rmi $(docker images -q "aztecprotocol/aztec")
  fi

  # 删除配置和数据
  rm -rf "$AZTEC_DIR"
  rm -rf "$DATA_DIR"
  rm -rf /tmp/aztec-world-state-*
  rm -rf "$HOME/.aztec"

  print_info "删除完成！"
}

# 备份节点配置
backup_node_config() {
  print_info "备份节点配置..."

  local backup_dir="/root/aztec_backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup_dir"

  if [ -f "$AZTEC_DIR/.env" ]; then
    cp "$AZTEC_DIR/.env" "$backup_dir/"
    print_info "配置文件已备份到: $backup_dir/.env"
  fi

  if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    cp "$AZTEC_DIR/docker-compose.yml" "$backup_dir/"
    print_info "Docker配置已备份到: $backup_dir/docker-compose.yml"
  fi

  # 备份密钥文件
  if [ -f "$HOME/.aztec/keystore/key1.json" ]; then
    cp -r "$HOME/.aztec/keystore" "$backup_dir/"
    print_info "密钥文件已备份到: $backup_dir/keystore/"
  fi

  print_info "备份完成！备份目录: $backup_dir"
}

# 恢复节点配置
restore_node_config() {
  print_info "恢复节点配置..."

  # 查找最新的备份目录
  local latest_backup=$(ls -dt /root/aztec_backup_* 2>/dev/null | head -1)

  if [ -z "$latest_backup" ]; then
    print_info "未找到备份文件。"
    return
  fi

  print_info "找到备份: $latest_backup"
  read -p "确认恢复？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    return
  fi

  if [ -f "$latest_backup/.env" ]; then
    cp "$latest_backup/.env" "$AZTEC_DIR/"
    print_info "配置文件已恢复。"
  fi

  if [ -f "$latest_backup/docker-compose.yml" ]; then
    cp "$latest_backup/docker-compose.yml" "$AZTEC_DIR/"
    print_info "Docker配置已恢复。"
  fi

  # 恢复密钥文件
  if [ -d "$latest_backup/keystore" ]; then
    cp -r "$latest_backup/keystore" "$HOME/.aztec/"
    print_info "密钥文件已恢复。"
  fi

  print_info "配置恢复完成！"

  read -p "是否重启节点？(y/n): " restart_confirm
  if [[ "$restart_confirm" == "y" ]]; then
    cd "$AZTEC_DIR"
    docker compose restart
    print_info "节点已重启。"
  fi
}

# 检查系统要求
check_system_requirements() {
  print_info "=== 系统要求检查 ==="

  # 检查内存
  local total_mem=$(free -g | awk 'NR==2{print $2}')
  if [ "$total_mem" -lt 8 ]; then
    echo "  内存: ${total_mem}GB (推荐 16GB)"
  else
    echo " 内存: ${total_mem}GB"
  fi

  # 检查磁盘空间
  local disk_space=$(df -h / | awk 'NR==2{print $4}')
  local disk_avail=$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')
  if [ "$disk_avail" -lt 100 ]; then
    echo "  磁盘空间: ${disk_space} (推荐 200GB+)"
  else
    echo " 磁盘空间: ${disk_space}"
  fi

  # 检查 CPU 核心数
  local cpu_cores=$(nproc)
  if [ "$cpu_cores" -lt 4 ]; then
    echo "  CPU核心: ${cpu_cores} (推荐 8核)"
  else
    echo " CPU核心: ${cpu_cores}"
  fi

  # 检查操作系统
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo " 操作系统: $NAME $VERSION"
  else
    echo "  操作系统: 未知"
  fi

  echo
  echo "按任意键继续..."
  read -n 1
}

# 显示验证者信息
show_validator_info() {
  print_info "=== 验证者信息 ==="
  
  if [ -f "$AZTEC_DIR/.env" ]; then
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
    echo " 未找到节点配置。"
  fi
  
  # 检查密钥文件
  if [ -f "$HOME/.aztec/keystore/key1.json" ]; then
    echo " BLS 密钥: 已生成"
  else
    echo " BLS 密钥: 未生成"
  fi
  
  echo
  echo "按任意键继续..."
  read -n 1
}

# 主菜单函数
main_menu() {
  while true; do
    clear
    echo "Aztec 2.1.2 测试网节点管理脚本"
    echo "================================"
    echo "1. 安装并启动 Aztec 节点"
    echo "2. 查看节点日志"
    echo "3. 获取区块高度和同步证明"
    echo "4. 查看节点状态"
    echo "5. 停止和更新节点"
    echo "6. 删除节点数据"
    echo "7. 备份节点配置"
    echo "8. 恢复节点配置"
    echo "9. 检查系统要求"
    echo "10. 显示验证者信息"
    echo "11. 退出"
    read -p "请输入选项 (1-11): " choice

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
        get_block_and_proof
        echo "按任意键继续..."
        read -n 1
        ;;
      4)
        check_node_status
        ;;
      5)
        stop_and_update_node
        echo "按任意键继续..."
        read -n 1
        ;;
      6)
        delete_node_data
        echo "按任意键继续..."
        read -n 1
        ;;
      7)
        backup_node_config
        echo "按任意键继续..."
        read -n 1
        ;;
      8)
        restore_node_config
        echo "按任意键继续..."
        read -n 1
        ;;
      9)
        check_system_requirements
        ;;
      10)
        show_validator_info
        ;;
      11)
        print_info "退出脚本。"
        exit 0
        ;;
      *)
        print_info "无效选项。"
        echo "按任意键继续..."
        read -n 1
        ;;
    esac
  done
}

# 执行主菜单
main_menu
