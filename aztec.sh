#!/usr/bin/env bash
set -euo pipefail

# 常量定义
MIN_DOCKER_VERSION="20.10"
MIN_COMPOSE_VERSION="1.29.2"
AZTEC_CLI_URL="https://install.aztec.network"
AZTEC_DIR="/root/aztec"
DATA_DIR="/root/.aztec/alpha-testnet/data"
AZTEC_IMAGE="aztecprotocol/aztec:2.0.2"
OLD_AZTEC_IMAGE="aztecprotocol/aztec:1.2.1"
STAKING_ASSET_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 函数：打印信息
print_info() {
  echo -e "${GREEN}[INFO] $1${NC}"
}

# 函数：打印错误
print_error() {
  echo -e "${RED}[ERROR] $1${NC}" >&2
}

# 函数：打印警告
print_warning() {
  echo -e "${YELLOW}[WARNING] $1${NC}"
}

# 函数：检查命令是否存在
check_command() {
  command -v "$1" &>/dev/null || { print_error "$1 未安装，请先安装！"; return 1; }
}

# 函数：比较版本号
version_ge() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# 函数：安装依赖
install_package() {
  local pkg=$1
  print_info "安装 $pkg..."
  apt-get install -y "$pkg" || { print_error "安装 $pkg 失败！"; exit 1; }
}

# 函数：更新 apt 源（只执行一次）
update_apt() {
  if [ -z "${APT_UPDATED:-}" ]; then
    print_info "更新 apt 源..."
    apt-get update || { print_error "apt-get update 失败！"; exit 1; }
    APT_UPDATED=1
  fi
}

# 函数：检查并安装必需工具
check_prerequisites() {
  print_info "检查必需工具..."
  for cmd in curl jq ufw; do
    check_command "$cmd" || install_package "$cmd"
  done
}

# 函数：检查并安装 Docker
install_docker() {
  if check_command docker; then
    local version
    version=$(docker --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_DOCKER_VERSION"; then
      print_info "Docker 已安装，版本 $version，满足要求（>= $MIN_DOCKER_VERSION）。"
      return
    else
      print_warning "Docker 版本 $version 过低（要求 >= $MIN_DOCKER_VERSION），将重新安装..."
    fi
  else
    print_info "未找到 Docker，正在安装..."
  fi
  update_apt
  install_package "apt-transport-https ca-certificates curl gnupg-agent software-properties-common"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  update_apt
  install_package "docker-ce docker-ce-cli containerd.io"
}

# 函数：检查并安装 Docker Compose
install_docker_compose() {
  if check_command docker-compose || docker compose version &>/dev/null; then
    local version
    version=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || docker compose version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_COMPOSE_VERSION"; then
      print_info "Docker Compose 已安装，版本 $version，满足要求（>= $MIN_COMPOSE_VERSION）。"
      return
    else
      print_warning "Docker Compose 版本 $version 过低（要求 >= $MIN_COMPOSE_VERSION），将重新安装..."
    fi
  else
    print_info "未找到 Docker Compose，正在安装..."
  fi
  update_apt
  install_package docker-compose-plugin
}

# 函数：检查并安装 Node.js
install_nodejs() {
  if check_command node; then
    local version
    version=$(node --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    print_info "Node.js 已安装，版本 $version。"
    return
  fi
  print_info "未找到 Node.js，正在安装最新版本..."
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  update_apt
  install_package nodejs
}

# 函数：检查 Aztec 镜像版本
check_aztec_image_version() {
  print_info "检查当前 Aztec 镜像版本..."
  if docker images "$AZTEC_IMAGE" | grep -q "$AZTEC_IMAGE"; then
    print_info "Aztec 镜像 $AZTEC_IMAGE 已存在。"
  else
    print_info "拉取最新 Aztec 镜像 $AZTEC_IMAGE..."
    for attempt in {1..3}; do
      if docker pull "$AZTEC_IMAGE"; then
        break
      elif [ "$attempt" -lt 3 ]; then
        print_warning "拉取镜像 $AZTEC_IMAGE 失败，重试 $((attempt + 1))/3..."
        sleep 5
      else
        print_error "无法拉取镜像 $AZTEC_IMAGE，请检查网络或 Docker 配置。"
        exit 1
      fi
    done
  fi
}

# 函数：安装 Aztec CLI
install_aztec_cli() {
  print_info "安装 Aztec CLI 并准备 alpha 测试网..."
  for attempt in {1..3}; do
    if curl -sL "$AZTEC_CLI_URL" | bash; then
      break
    elif [ "$attempt" -lt 3 ]; then
      print_warning "Aztec CLI 安装失败，重试 $((attempt + 1))/3..."
      sleep 5
    else
      print_error "Aztec CLI 安装失败。"
      exit 1
    fi
  done
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! check_command aztec-up; then
    print_error "Aztec CLI 安装失败，未找到 aztec-up 命令。"
    exit 1
  fi
  if ! aztec-up alpha-testnet 1.2.1; then
    print_error "aztec-up alpha-testnet 1.2.1 命令执行失败，请检查网络或 Aztec CLI 安装。"
    exit 1
  fi
}

# 函数：验证 URL 格式
validate_url() {
  local url=$1
  local name=$2
  if [[ -z "$url" || ! "$url" =~ ^https?:// ]]; then
    print_error "$name 格式无效，必须以 http:// 或 https:// 开头且不为空。"
    exit 1
  fi
}

# 函数：验证以太坊地址格式
validate_address() {
  local address=$1
  local name=$2
  if [[ -z "$address" || ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "$name 格式无效，必须是有效的以太坊地址（0x 开头的 40 位十六进制）。"
    exit 1
  fi
}

# 函数：验证私钥格式
validate_private_key() {
  local key=$1
  local name=$2
  if [[ -z "$key" || ! "$key" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    print_error "$name 格式无效，必须是 0x 开头的 64 位十六进制且不为空。"
    exit 1
  fi
}

# 函数：验证多个私钥格式
validate_private_keys() {
  local keys=$1
  local name=$2
  if [ -z "$keys" ]; then
    print_error "$name 不能为空。"
    exit 1
  fi
  IFS=',' read -ra key_array <<< "$keys"
  for key in "${key_array[@]}"; do
    validate_private_key "$key" "$name"
  done
}

# 函数：安装并启动 Aztec 节点
install_and_start_node() {
  print_info "=== 安装并启动 Aztec 节点 ==="
  # 清理旧配置和数据
  print_info "清理旧的 Aztec 配置和数据..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/docker-compose.yml" /tmp/aztec-world-state-* "$DATA_DIR"
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  # 安装依赖
  check_prerequisites
  install_docker
  install_docker_compose
  install_nodejs
  install_aztec_cli
  check_aztec_image_version

  # 创建配置目录
  print_info "创建 Aztec 配置目录 $AZTEC_DIR..."
  mkdir -p "$AZTEC_DIR"
  chmod -R 755 "$AZTEC_DIR"

  # 配置防火墙
  print_info "配置防火墙，开放端口 40400 和 8080..."
  if check_command ufw; then
    ufw allow 40400/tcp >/dev/null 2>&1
    ufw allow 40400/udp >/dev/null 2>&1
    ufw allow 8080/tcp >/dev/null 2>&1
    print_info "防火墙状态："
    ufw status
  else
    print_warning "未找到 ufw，请手动配置防火墙开放端口 40400 和 8080。"
  fi

  # 获取用户输入
  ETH_RPC="${ETH_RPC:-}"
  CONS_RPC="${CONS_RPC:-}"
  VALIDATOR_PRIVATE_KEYS="${VALIDATOR_PRIVATE_KEYS:-}"
  COINBASE="${COINBASE:-}"
  PUBLISHER_PRIVATE_KEY="${PUBLISHER_PRIVATE_KEY:-}"
  print_info "获取 RPC URL 和其他配置的说明："
  print_info "  - L1 执行客户端（EL）RPC URL：https://dashboard.alchemy.com/"
  print_info "  - L1 共识（CL）RPC URL：https://drpc.org/"
  print_info "  - COINBASE：接收奖励的以太坊地址（0x...）"
  print_info "  - 验证者私钥：多个私钥用逗号分隔（0x123...,0x234...）"
  print_info "  - 发布者私钥（可选）：用于提交交易的地址"
  if [ -z "$ETH_RPC" ]; then
    read -p "请输入 L1 执行客户端（EL）RPC URL： " ETH_RPC
  fi
  if [ -z "$CONS_RPC" ]; then
    read -p "请输入 L1 共识（CL）RPC URL： " CONS_RPC
  fi
  if [ -z "$VALIDATOR_PRIVATE_KEYS" ]; then
    read -p "请输入验证者私钥（多个私钥用逗号分隔，0x 开头）： " VALIDATOR_PRIVATE_KEYS
  fi
  if [ -z "$COINBASE" ]; then
    read -p "请输入 EVM 钱包地址（以太坊地址，0x 开头）： " COINBASE
  fi
  read -p "请输入发布者私钥（可选，0x 开头，按回车跳过）： " PUBLISHER_PRIVATE_KEY
  BLOB_URL=""

  # 验证输入
  validate_url "$ETH_RPC" "L1 执行客户端（EL）RPC URL"
  validate_url "$CONS_RPC" "L1 共识（CL）RPC URL"
  validate_private_keys "$VALIDATOR_PRIVATE_KEYS" "验证者私钥"
  validate_address "$COINBASE" "COINBASE 地址"
  if [ -n "$PUBLISHER_PRIVATE_KEY" ]; then
    validate_private_key "$PUBLISHER_PRIVATE_KEY" "发布者私钥"
  fi

  # 获取公共 IP
  print_info "获取公共 IP..."
  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
  print_info "    → $PUBLIC_IP"

  # 生成 .env 文件
  print_info "生成 $AZTEC_DIR/.env 文件..."
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
  if [ -n "$BLOB_URL" ]; then
    echo "BLOB_SINK_URL=\"$BLOB_URL\"" >> "$AZTEC_DIR/.env"
  fi
  chmod 600 "$AZTEC_DIR/.env"

  # 设置启动标志
  VALIDATOR_FLAG="--sequencer.validatorPrivateKeys \"$VALIDATOR_PRIVATE_KEYS\""
  PUBLISHER_FLAG=""
  if [ -n "$PUBLISHER_PRIVATE_KEY" ]; then
    PUBLISHER_FLAG="--sequencer.publisherPrivateKey \"$PUBLISHER_PRIVATE_KEY\""
  fi
  BLOB_FLAG=""
  if [ -n "$BLOB_URL" ]; then
    BLOB_FLAG="--sequencer.blobSinkUrl \"$BLOB_SINK_URL\""
  fi

  # 生成 docker-compose.yml 文件
  print_info "生成 $AZTEC_DIR/docker-compose.yml 文件..."
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
      - BLOB_SINK_URL=\${BLOB_SINK_URL:-}
    entrypoint:
      - sh
      - -c
      - "node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network alpha-testnet --node --archiver --sequencer $VALIDATOR_FLAG $PUBLISHER_FLAG \${BLOB_FLAG:-}"
    volumes:
      - /root/.aztec/alpha-testnet/data/:/data
EOF
  chmod 644 "$AZTEC_DIR/docker-compose.yml"

  # 创建数据目录
  print_info "创建数据目录 $DATA_DIR..."
  mkdir -p "$DATA_DIR"
  chmod -R 755 "$DATA_DIR"

  # 启动节点
  print_info "启动 Aztec 全节点..."
  cd "$AZTEC_DIR"
  if check_command docker && docker compose version &>/dev/null; then
    if ! docker compose up -d; then
      print_error "docker compose up -d 失败，请检查 Docker 安装或配置。"
      print_info "查看日志：docker logs -f aztec-sequencer"
      exit 1
    fi
  elif check_command docker-compose; then
    if ! docker-compose up -d; then
      print_error "docker-compose up -d 失败，请检查 Docker Compose 安装或配置。"
      print_info "查看日志：docker logs -f aztec-sequencer"
      exit 1
    fi
  else
    print_error "未找到 docker compose 或 docker-compose，请确保安装 Docker 和 Docker Compose。"
    exit 1
  fi

  print_info "安装和启动完成！"
  print_info "  - 查看日志：docker logs -f aztec-sequencer"
  print_info "  - 配置目录：$AZTEC_DIR"
  print_info "  - 数据目录：$DATA_DIR"
}

# 函数：停止、删除、更新并重启节点
stop_delete_update_restart_node() {
  print_info "=== 停止节点、删除 Docker 容器、更新节点并重新创建 Docker ==="
  read -p "警告：此操作将停止并删除 Aztec 容器（包括 $OLD_AZTEC_IMAGE）、更新 docker-compose.yml 到 $AZTEC_IMAGE、拉取最新镜像并重新创建 Docker，是否继续？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    print_info "已取消操作。"
    return
  fi

  # 检查配置目录
  if [ ! -f "$AZTEC_DIR/docker-compose.yml" ]; then
    print_error "未找到 $AZTEC_DIR/docker-compose.yml 文件，请先安装并启动节点。"
    return
  fi

  # 检查并更新 docker-compose.yml
  if grep -q "image: $OLD_AZTEC_IMAGE" "$AZTEC_DIR/docker-compose.yml"; then
    print_info "检测到 docker-compose.yml 使用旧镜像 $OLD_AZTEC_IMAGE，正在更新为 $AZTEC_IMAGE..."
    sed -i "s|image: $OLD_AZTEC_IMAGE|image: $AZTEC_IMAGE|" "$AZTEC_DIR/docker-compose.yml"
    print_info "docker-compose.yml 已更新为 $AZTEC_IMAGE。"
  elif grep -q "image: $AZTEC_IMAGE" "$AZTEC_DIR/docker-compose.yml"; then
    print_info "docker-compose.yml 已使用最新镜像 $AZTEC_IMAGE，无需更新。"
  else
    print_warning "docker-compose.yml 包含未知镜像版本，建议重新运行选项 1 重新生成配置。"
  fi

  # 停止并删除容器
  print_info "停止并删除 Aztec 容器..."
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    docker stop aztec-sequencer 2>/dev/null || true
    docker rm aztec-sequencer 2>/dev/null || true
    print_info "容器 aztec-sequencer 已停止并删除。"
  else
    print_info "未找到运行中的 aztec-sequencer 容器。"
  fi

  # 删除旧版本镜像
  print_info "删除旧版本 Aztec 镜像 $OLD_AZTEC_IMAGE..."
  if docker images -q "$OLD_AZTEC_IMAGE" | grep -q .; then
    docker rmi "$OLD_AZTEC_IMAGE" 2>/dev/null || true
    print_info "旧版本镜像 $OLD_AZTEC_IMAGE 已删除。"
  else
    print_info "未找到旧版本镜像 $OLD_AZTEC_IMAGE。"
  fi

  # 更新 Aztec CLI
  print_info "更新 Aztec CLI 到 1.2.1..."
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! check_command aztec-up; then
    print_error "未找到 aztec-up 命令，正在尝试重新安装 Aztec CLI..."
    install_aztec_cli
  else
    if ! aztec-up alpha-testnet 1.2.1; then
      print_error "aztec-up alpha-testnet 1.2.1 失败，请检查网络或 Aztec CLI 安装。"
      return
    fi
  fi

  # 更新 Aztec 镜像
  check_aztec_image_version

  # 重新创建并启动节点
  print_info "重新创建并启动 Aztec 节点..."
  cd "$AZTEC_DIR"
  if check_command docker && docker compose version &>/dev/null; then
    if ! docker compose up -d; then
      print_error "docker compose up -d 失败，请检查 Docker 安装或配置。"
      print_info "查看日志：docker logs -f aztec-sequencer"
      return
    fi
  elif check_command docker-compose; then
    if ! docker-compose up -d; then
      print_error "docker-compose up -d 失败，请检查 Docker Compose 安装或配置。"
      print_info "查看日志：docker logs -f aztec-sequencer"
      return
    fi
  else
    print_error "未找到 docker compose 或 docker-compose，请确保安装 Docker 和 Docker Compose。"
    return
  fi

  print_info "节点已停止、删除、更新并重新创建完成！"
  print_info "查看日志：docker logs -f aztec-sequencer"
}

# 函数：获取区块高度和同步证明
get_block_and_proof() {
  print_info "=== 获取区块高度和同步证明 ==="
  if ! check_command jq; then
    print_info "未找到 jq，正在安装..."
    update_apt
    install_package jq
  fi

  if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    if ! docker ps -q -f name=aztec-sequencer | grep -q .; then
      print_error "容器 aztec-sequencer 未运行，请先启动节点。"
      return
    fi
    print_info "获取当前区块高度..."
    BLOCK_NUMBER=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
      http://localhost:8080 | jq -r ".result.proven.number" || echo "")
    if [ -z "$BLOCK_NUMBER" ] || [ "$BLOCK_NUMBER" = "null" ]; then
      print_error "无法获取区块高度（请等待半个小时后再查询），请检查节点状态（docker logs -f aztec-sequencer）。"
      return
    fi
    print_info "当前区块高度：$BLOCK_NUMBER"
    print_info "获取同步证明..."
    PROOF=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d "$(jq -n --arg bn "$BLOCK_NUMBER" '{"jsonrpc":"2.0","method":"node_getArchiveSiblingPath","params":[$bn,$bn],"id":67}')" \
      http://localhost:8080 | jq -r ".result" || echo "")
    if [ -z "$PROOF" ] || [ "$PROOF" = "null" ]; then
      print_error "无法获取同步证明，请检查节点状态（docker logs -f aztec-sequencer）。"
    else
      print_info "同步一次证明：$PROOF"
    fi
  else
    print_error "未找到 $AZTEC_DIR/docker-compose.yml 文件，请先安装并启动节点。"
  fi
}

# 函数：注册验证者
register_validator() {
  print_info "=== 注册验证者 ==="
  read -p "是否继续注册验证者？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    print_info "已取消注册验证者。"
    return
  fi
  read -p "请输入以太坊私钥（0x...）： " L1_PRIVATE_KEY
  read -p "请输入验证者地址（0x...）： " VALIDATOR_ADDRESS
  read -p "请输入 L1 RPC 地址： " L1_RPC
  validate_private_key "$L1_PRIVATE_KEY" "以太坊私钥"
  validate_address "$VALIDATOR_ADDRESS" "验证者地址"
  validate_url "$L1_RPC" "L1 RPC 地址"
  print_info "正在注册验证者..."
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! check_command aztec; then
    print_error "未找到 aztec 命令，请确保已安装 Aztec CLI。"
    return
  fi
  if aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC" \
    --private-key "$L1_PRIVATE_KEY" \
    --attester "$VALIDATOR_ADDRESS" \
    --proposer-eoa "$VALIDATOR_ADDRESS" \
    --staking-asset-handler "$STAKING_ASSET_HANDLER" \
    --l1-chain-id 11155111; then
    print_info "注册命令已执行。请检查链上状态确认是否成功。"
    print_info "请访问 Sepolia 测试网查看验证者状态：https://sepolia.etherscan.io/address/$VALIDATOR_ADDRESS"
  else
    print_error "验证者注册失败，请检查输入参数或网络连接。"
  fi
}

# 函数：删除 Docker 容器和节点数据
delete_docker_and_node() {
  print_info "=== 删除 Docker 容器和节点数据 ==="
  print_warning "警告：此操作将删除所有节点数据（包括 $DATA_DIR 和 $AZTEC_DIR），建议备份重要数据。"
  read -p "是否继续？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    print_info "已取消删除操作。"
    return
  fi
  print_info "停止并删除 Aztec 容器..."
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    docker stop aztec-sequencer 2>/dev/null || true
    docker rm aztec-sequencer 2>/dev/null || true
    print_info "容器 aztec-sequencer 已停止并删除。"
  else
    print_info "未找到运行中的 aztec-sequencer 容器。"
  fi
  print_info "删除 Aztec 镜像 $AZTEC_IMAGE 和 $OLD_AZTEC_IMAGE..."
  if docker images -q "aztecprotocol/aztec" | sort -u | grep -q .; then
    docker rmi $(docker images -q "aztecprotocol/aztec" | sort -u) 2>/dev/null || true
    print_info "所有 aztecprotocol/aztec 镜像已删除。"
  else
    print_info "未找到 aztecprotocol/aztec 镜像。"
  fi
  print_info "删除配置文件和数据目录..."
  rm -rf "$AZTEC_DIR" "$DATA_DIR" /tmp/aztec-world-state-* 2>/dev/null || true
  print_info "配置文件目录 $AZTEC_DIR 和数据目录 $DATA_DIR 已删除。"
  print_info "删除 Aztec CLI..."
  rm -rf "$HOME/.aztec" 2>/dev/null || true
  print_info "Aztec CLI 目录 $HOME/.aztec 已删除。"
  print_info "所有 Docker 容器、镜像、配置文件和节点数据已删除。"
  print_info "如需重新部署，请选择菜单选项 1。"
}

# 函数：查看节点日志
view_logs() {
  print_info "=== 查看节点日志 ==="
  if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    docker logs --tail 100 aztec-sequencer > /tmp/aztec_logs.txt 2>/dev/null
    if grep -q "does not match the expected genesis archive" /tmp/aztec_logs.txt; then
      print_error "检测到错误：创世归档树根不匹配！"
      print_info "建议：1. 确保使用最新镜像 $AZTEC_IMAGE"
      print_info "      2. 清理旧数据：rm -rf /tmp/aztec-world-state-* $DATA_DIR"
      print_info "      3. 重新运行 aztec-up alpha-testnet 和 aztec start"
      print_info "      4. 检查 L1 RPC URL 是否正确（Sepolia 网络）"
      print_info "      5. 联系 Aztec 社区寻求帮助"
    fi
    docker logs -f --tail 100 aztec-sequencer
  else
    print_error "未找到 $AZTEC_DIR/docker-compose.yml 文件，请先运行并启动节点。"
  fi
}

# 函数：主菜单
main_menu() {
  while true; do
    clear
    echo "================================================================"
    echo "脚本由哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
    echo "如有问题，可联系推特，仅此只有一个号"
    echo "================================================================"
    echo "退出脚本，请按 Ctrl+C"
    echo "请选择要执行的操作:"
    echo "1. 安装并启动 Aztec 节点"
    echo "2. 查看节点日志"
    echo "3. 获取区块高度和同步证明（请等待半个小时后再查询）"
    echo "4. 停止节点、删除 Docker 容器、更新节点并重新创建 Docker"
    echo "5. 注册验证者"
    echo "6. 删除 Docker 容器和节点数据"
    echo "7. 退出"
    read -p "请输入选项 (1-7): " choice
    case $choice in
      1) install_and_start_node ;;
      2) view_logs ;;
      3) get_block_and_proof ;;
      4) stop_delete_update_restart_node ;;
      5) register_validator ;;
      6) delete_docker_and_node ;;
      7) print_info "退出脚本..."; exit 0 ;;
      *) print_error "无效选项，请输入 1-7。" ;;
    esac
    read -p "按任意键返回主菜单..." -n 1
  done
}

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  print_error "本脚本必须以 root 权限运行。"
  exit 1
fi

# 检查系统兼容性
if ! lsb_release -a 2>/dev/null | grep -qi "ubuntu"; then
  print_warning "本脚本针对 Ubuntu 优化，可能不完全兼容其他系统，请手动验证依赖。"
fi

# 执行主菜单
main_menu
