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
DATA_DIR="/root/.aztec/alpha-testnet/data"
AZTEC_IMAGE="aztecprotocol/aztec:2.0.4"
GOVERNANCE_PROPOSER_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"
SNAPSHOT_URL_1="https://snapshots.aztec.graphops.xyz/files/"

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

# 安装 Aztec CLI
install_aztec_cli() {
  print_info "安装 Aztec CLI..."
  if ! curl -sL "$AZTEC_CLI_URL" | bash; then
    echo "Aztec CLI 安装失败。"
    exit 1
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! check_command aztec-up; then
    echo "Aztec CLI 安装失败。"
    exit 1
  fi
  if ! aztec-up alpha-testnet 2.0.4; then
    echo "aztec-up alpha-testnet 2.0.4 执行失败。"
    exit 1
  fi
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

# 验证多个私钥格式
validate_private_keys() {
  local keys=$1
  local name=$2
  IFS=',' read -ra key_array <<< "$keys"
  for key in "${key_array[@]}"; do
    if [[ ! "$key" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
      echo "错误：$name 中包含无效私钥。"
      exit 1
    fi
  done
}

# 查看节点状态
check_node_status() {
  print_info "=== 节点状态检查 ==="
  echo

  # 检查容器状态
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    CONTAINER_STATUS=$(docker inspect aztec-sequencer --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [ "$CONTAINER_STATUS" = "running" ]; then
      echo "✅ Aztec 容器: 运行中"
      
      # 检查端口状态
      if docker port aztec-sequencer 8080 >/dev/null 2>&1; then
        echo "✅ RPC 端口 (8080): 可用"
      else
        echo "⚠️  RPC 端口 (8080): 不可用"
      fi

      if docker port aztec-sequencer 40400 >/dev/null 2>&1; then
        echo "✅ P2P 端口 (40400): 可用"
      else
        echo "⚠️  P2P 端口 (40400): 不可用"
      fi

      # 检查进程状态
      if docker exec aztec-sequencer ps aux 2>/dev/null | grep -q "node"; then
        echo "✅ Node.js 进程: 运行中"
      else
        echo "❌ Node.js 进程: 未运行"
      fi

      # 检查日志状态
      LOGS_COUNT=$(docker logs --tail 5 aztec-sequencer 2>/dev/null | wc -l)
      if [ "$LOGS_COUNT" -gt 0 ]; then
        echo "✅ 日志输出: 正常"
        
        # 显示最近的同步状态
        SYNC_STATUS=$(docker logs --tail 10 aztec-sequencer 2>/dev/null | grep -E "pending sync from L1|synced|block" | tail -1)
        if [ -n "$SYNC_STATUS" ]; then
          echo "📊 同步状态: $(echo "$SYNC_STATUS" | cut -c1-60)..."
        fi
      else
        echo "❌ 日志输出: 无输出"
      fi

    else
      echo "❌ Aztec 容器: $CONTAINER_STATUS"
    fi
  else
    echo "❌ Aztec 容器: 未运行"
  fi

  echo

  # 检查配置文件
  if [ -f "$AZTEC_DIR/.env" ]; then
    echo "✅ 配置文件: 存在"
    
    # 检查 RPC 配置
    if grep -q "ETHEREUM_HOSTS" "$AZTEC_DIR/.env"; then
      ETH_RPC=$(grep "ETHEREUM_HOSTS" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d ' ' | head -1)
      echo "✅ 执行层 RPC: 已配置"
      echo "   📍 $ETH_RPC"
      
      # 测试执行层 RPC 连接
      print_info "测试执行层 RPC 连接..."
      ETH_RPC_STATUS=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$ETH_RPC" 2>/dev/null | grep -o '"result"' || echo "failed")
      if [ "$ETH_RPC_STATUS" = '"result"' ]; then
        echo "   ✅ 执行层 RPC: 连接正常"
        
        # 获取执行层最新区块
        ETH_BLOCK_HEX=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$ETH_RPC" 2>/dev/null | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$ETH_BLOCK_HEX" ]; then
          ETH_BLOCK_DEC=$((16#${ETH_BLOCK_HEX#0x}))
          echo "   📦 最新区块: $ETH_BLOCK_DEC"
        fi
      else
        echo "   ❌ 执行层 RPC: 连接失败"
      fi
    else
      echo "❌ 执行层 RPC: 未配置"
    fi

    if grep -q "L1_CONSENSUS_HOST_URLS" "$AZTEC_DIR/.env"; then
      CONS_RPC=$(grep "L1_CONSENSUS_HOST_URLS" "$AZTEC_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d ' ' | head -1)
      echo "✅ 共识层 RPC: 已配置"
      echo "   📍 $CONS_RPC"
      
      # 测试共识层 RPC 连接
      print_info "测试共识层 RPC 连接..."
      CONS_RPC_STATUS=$(curl -s -X GET "$CONS_RPC/eth/v1/node/health" 2>/dev/null | head -1 | grep -o "200" || echo "failed")
      if [ "$CONS_RPC_STATUS" = "200" ]; then
        echo "   ✅ 共识层 RPC: 连接正常"
        
        # 获取共识层同步状态
        SYNC_STATUS=$(curl -s -X GET "$CONS_RPC/eth/v1/node/syncing" 2>/dev/null | grep -o '"is_syncing":[^,]*' | cut -d':' -f2 | tr -d ' ' || echo "unknown")
        if [ "$SYNC_STATUS" = "false" ]; then
          echo "   📊 同步状态: 已同步"
        elif [ "$SYNC_STATUS" = "true" ]; then
          echo "   📊 同步状态: 同步中"
        else
          echo "   📊 同步状态: 未知"
        fi
      else
        echo "   ❌ 共识层 RPC: 连接失败"
      fi
    else
      echo "❌ 共识层 RPC: 未配置"
    fi

    # 检查治理提案配置
    if grep -q "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS" "$AZTEC_DIR/.env"; then
      echo "✅ 治理提案: 已配置"
    else
      echo "⚠️  治理提案: 未配置"
    fi
  else
    echo "❌ 配置文件: 不存在"
  fi

  echo

  # 系统资源状态
  echo "=== 系统资源 ==="
  
  # 内存使用
  MEM_TOTAL=$(free -m 2>/dev/null | awk 'NR==2{print $2}' || echo "0")
  if [ "$MEM_TOTAL" -gt 0 ]; then
    MEM_USED=$(free -m | awk 'NR==2{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    echo "💾 内存使用: ${MEM_PERCENT}%"
  else
    echo "💾 内存使用: 无法获取"
  fi

  # 磁盘使用
  DISK_USED=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' || echo "0%")
  echo "💿 磁盘使用: $DISK_USED"

  # CPU 负载
  if [ -f /proc/loadavg ]; then
    LOAD_AVG=$(cat /proc/loadavg | awk '{print $1}')
    echo "🖥️  CPU负载: $LOAD_AVG"
  else
    echo "🖥️  CPU负载: 无法获取"
  fi

  echo
  echo "=== 网络连接 ==="
  
  # 检查网络连接
  if ping -c 1 -W 3 google.com &>/dev/null; then
    echo "🌐 互联网连接: 正常"
  else
    echo "🌐 互联网连接: 异常"
  fi

  # 检查 Docker 服务状态
  if systemctl is-active --quiet docker; then
    echo "🐳 Docker 服务: 运行中"
  else
    echo "🐳 Docker 服务: 未运行"
  fi

  echo
  echo "=== 建议操作 ==="
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    echo "1. 查看详细日志 (选项 2)"
    echo "2. 检查区块高度 (选项 3)"
    echo "3. 如遇 RPC 连接问题，请检查网络或更换 RPC 服务商"
    echo "4. 如遇问题可重启节点"
  else
    echo "1. 安装并启动节点 (选项 1)"
    echo "2. 检查配置文件"
    echo "3. 确认 RPC 服务可用性"
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
  install_aztec_cli

  # 创建配置目录
  print_info "创建配置目录 $AZTEC_DIR..."
  mkdir -p "$AZTEC_DIR"
  chmod -R 755 "$AZTEC_DIR"

  # 配置防火墙
  print_info "配置防火墙..."
  ufw allow 40400/tcp >/dev/null 2>&1
  ufw allow 40400/udp >/dev/null 2>&1
  ufw allow 8080/tcp >/dev/null 2>&1

  # 获取用户输入
  ETH_RPC="${ETH_RPC:-}"
  CONS_RPC="${CONS_RPC:-}"
  VALIDATOR_PRIVATE_KEYS="${VALIDATOR_PRIVATE_KEYS:-}"
  COINBASE="${COINBASE:-}"
  PUBLISHER_PRIVATE_KEY="${PUBLISHER_PRIVATE_KEY:-}"

  print_info "配置说明："
  print_info "  - L1 执行客户端 RPC URL (如 Alchemy 的 Sepolia RPC)"
  print_info "  - L1 共识 RPC URL (如 drpc.org 的 Beacon Chain Sepolia RPC)" 
  print_info "  - 验证者私钥 (多个用逗号分隔)"
  print_info "  - COINBASE 地址"
  print_info "  - 发布者私钥 (可选)"

  if [ -z "$ETH_RPC" ]; then
    read -p "L1 执行客户端 RPC URL: " ETH_RPC
  fi
  if [ -z "$CONS_RPC" ]; then
    read -p "L1 共识 RPC URL: " CONS_RPC
  fi
  if [ -z "$VALIDATOR_PRIVATE_KEYS" ]; then
    read -p "验证者私钥: " VALIDATOR_PRIVATE_KEYS
  fi
  if [ -z "$COINBASE" ]; then
    read -p "COINBASE 地址: " COINBASE
  fi
  read -p "发布者私钥 (可选): " PUBLISHER_PRIVATE_KEY
  
  # 验证输入
  validate_url "$ETH_RPC" "L1 执行客户端 RPC URL"
  validate_url "$CONS_RPC" "L1 共识 RPC URL"
  if [ -z "$VALIDATOR_PRIVATE_KEYS" ]; then
    echo "错误：验证者私钥不能为空。"
    exit 1
  fi
  validate_private_keys "$VALIDATOR_PRIVATE_KEYS" "验证者私钥"
  validate_address "$COINBASE" "COINBASE 地址"
  if [ -n "$PUBLISHER_PRIVATE_KEY" ]; then
    validate_private_key "$PUBLISHER_PRIVATE_KEY" "发布者私钥"
  fi

  # 获取公共 IP
  print_info "获取公共 IP..."
  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
  print_info "IP: $PUBLIC_IP"

  # 生成 .env 文件
  print_info "生成配置文件..."
  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS="$ETH_RPC"
L1_CONSENSUS_HOST_URLS="$CONS_RPC"
P2P_IP="$PUBLIC_IP"
VALIDATOR_PRIVATE_KEYS="$VALIDATOR_PRIVATE_KEYS"
COINBASE="$COINBASE"
DATA_DIRECTORY="/data"
LOG_LEVEL="debug"
EOF

  if [ -n "$PUBLISHER_PRIVATE_KEY" ]; then
    echo "PUBLISHER_PRIVATE_KEY=\"$PUBLISHER_PRIVATE_KEY\"" >> "$AZTEC_DIR/.env"
  fi

  # 设置启动标志
  VALIDATOR_FLAG="--sequencer.validatorPrivateKeys \$VALIDATOR_PRIVATE_KEYS"
  PUBLISHER_FLAG=""
  if [ -n "$PUBLISHER_PRIVATE_KEY" ]; then
    PUBLISHER_FLAG="--sequencer.publisherPrivateKeys \$PUBLISHER_PRIVATE_KEY"
  fi

  # 生成 docker-compose.yml 文件
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
      sh -c "node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network alpha-testnet --node --archiver --sequencer --snapshots-url $SNAPSHOT_URL_1 $VALIDATOR_FLAG $PUBLISHER_FLAG"
    volumes:
      - /root/.aztec/alpha-testnet/data/:/data
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
  print_info "查看日志: docker logs -f aztec-sequencer"
  print_info "配置目录: $AZTEC_DIR"
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
  aztec-up alpha-testnet 2.0.4

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

# 设置治理提案投票
set_governance_vote() {
  print_info "设置治理提案投票..."

  if [ ! -f "$AZTEC_DIR/.env" ]; then
    print_info "未找到节点配置。"
    return
  fi

  read -p "确认设置？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    return
  fi

  if grep -q "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS" "$AZTEC_DIR/.env"; then
    sed -i "s|GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=.*|GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=\"$GOVERNANCE_PROPOSER_PAYLOAD\"|" "$AZTEC_DIR/.env"
  else
    echo "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=\"$GOVERNANCE_PROPOSER_PAYLOAD\"" >> "$AZTEC_DIR/.env"
  fi

  print_info "治理提案已设置！"
  
  read -p "是否重启节点？(y/n): " restart_confirm
  if [[ "$restart_confirm" == "y" ]]; then
    cd "$AZTEC_DIR"
    docker compose restart
    print_info "节点已重启。"
  fi
}

# 修复快照同步问题
fix_snapshot_sync() {
  print_info "修复快照同步问题..."

  if [ ! -f "$AZTEC_DIR/docker-compose.yml" ]; then
    print_info "未找到节点配置。"
    return
  fi

  read -p "确认修复？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    return
  fi

  cd "$AZTEC_DIR"
  docker compose down

  # 更新快照 URL
  if grep -q "snapshots-url" "$AZTEC_DIR/docker-compose.yml"; then
    sed -i "s|--snapshots-url [^ ]*|--snapshots-url $SNAPSHOT_URL_1|" "$AZTEC_DIR/docker-compose.yml"
  else
    sed -i "s|--sequencer|--sequencer --snapshots-url $SNAPSHOT_URL_1|" "$AZTEC_DIR/docker-compose.yml"
  fi

  docker compose up -d
  print_info "修复完成！"
}

# 主菜单函数
main_menu() {
  while true; do
    clear
    echo "Aztec 节点管理脚本"
    echo "========================"
    echo "1. 安装并启动 Aztec 节点"
    echo "2. 查看节点日志"
    echo "3. 获取区块高度和同步证明"
    echo "4. 查看节点状态"
    echo "5. 停止和更新节点"
    echo "6. 删除节点数据"
    echo "7. 设置治理提案投票"
    echo "8. 修复快照同步问题"
    echo "9. 退出"
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
        set_governance_vote
        echo "按任意键继续..."
        read -n 1
        ;;
      8)
        fix_snapshot_sync
        echo "按任意键继续..."
        read -n 1
        ;;
      9)
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
