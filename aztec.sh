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
AZTEC_IMAGE="aztecprotocol/aztec:2.0.2"  # 更新为 2.0.2
OLD_AZTEC_IMAGE="aztecprotocol/aztec:1.2.1"  # 旧版本为 1.2.1

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

# 更新 apt 源（只执行一次）
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
      print_info "Docker 已安装，版本 $version，满足要求（>= $MIN_DOCKER_VERSION）。"
      return
    else
      print_info "Docker 版本 $version 过低（要求 >= $MIN_DOCKER_VERSION），将重新安装..."
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

# 检查并安装 Docker Compose
install_docker_compose() {
  if check_command docker-compose || docker compose version &> /dev/null; then
    local version
    version=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || docker compose version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_COMPOSE_VERSION"; then
      print_info "Docker Compose 已安装，版本 $version，满足要求（>= $MIN_COMPOSE_VERSION）。"
      return
    else
      print_info "Docker Compose 版本 $version 过低（要求 >= $MIN_COMPOSE_VERSION），将重新安装..."
    fi
  else
    print_info "未找到 Docker Compose，正在安装..."
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
  print_info "未找到 Node.js，正在安装最新版本..."
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  update_apt
  install_package nodejs
}

# 检查 Aztec 镜像版本
check_aztec_image_version() {
  print_info "检查当前 Aztec 镜像版本..."
  if docker images "$AZTEC_IMAGE" | grep -q "1.2.1"; then  # 更新为检查 1.2.1
    print_info "Aztec 镜像 $AZTEC_IMAGE 已存在。"
  else
    print_info "拉取最新 Aztec 镜像 $AZTEC_IMAGE..."
    if ! docker pull "$AZTEC_IMAGE"; then
      echo "错误：无法拉取镜像 $AZTEC_IMAGE，请检查网络或 Docker 配置。"
      exit 1
    fi
  fi
}

# 安装 Aztec CLI
install_aztec_cli() {
  print_info "安装 Aztec CLI 并准备 alpha 测试网..."
  if ! curl -sL "$AZTEC_CLI_URL" | bash; then
    echo "Aztec CLI 安装失败。"
    exit 1
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! check_command aztec-up; then
    echo "Aztec CLI 安装失败，未找到 aztec-up 命令。"
    exit 1
  fi
  if ! aztec-up alpha-testnet 1.2.1; then  # 更新为 1.2.1
    echo "错误：aztec-up alpha-testnet 1.2.1 命令执行失败，请检查网络或 Aztec CLI 安装。"
    exit 1
  fi
}

# 验证 RPC URL 格式
validate_url() {
  local url=$1
  local name=$2
  if [[ ! "$url" =~ ^https?:// ]]; then
    echo "错误：$name 格式无效，必须以 http:// 或 https:// 开头。"
    exit 1
  fi
}

# 验证以太坊地址格式
validate_address() {
  local address=$1
  local name=$2
  if [[ ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo "错误：$name 格式无效，必须是有效的以太坊地址（0x 开头的 40 位十六进制）。"
    exit 1
  fi
}

# 验证私钥格式
validate_private_key() {
  local key=$1
  local name=$2
  if [[ ! "$key" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    echo "错误：$name 格式无效，必须是 0x 开头的 64 位十六进制。"
    exit 1
  fi
}

# 验证多个私钥格式（以逗号分隔）
validate_private_keys() {
  local keys=$1
  local name=$2
  IFS=',' read -ra key_array <<< "$keys"
  for key in "${key_array[@]}"; do
    if [[ ! "$key" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
      echo "错误：$name 中包含无效私钥 '$key'，必须是 0x 开头的 64 位十六进制。"
      exit 1
    fi
  done
}

# 主逻辑：安装和启动 Aztec 节点
install_and_start_node() {
  # 清理旧配置和 Hawkins
  print_info "清理旧的 Aztec 配置和数据（如果存在）..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/docker-compose.yml"
  rm -rf /tmp/aztec-world-state-*  # 清理临时世界状态数据库
  rm -rf "$DATA_DIR"  # 清理持久化数据目录
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  # 安装依赖
  install_docker
  install_docker_compose
  install_nodejs
  install_aztec_cli
  check_aztec_image_version

  # 创建 Aztec 配置目录
  print_info "创建 Aztec 配置目录 $AZTEC_DIR..."
  mkdir -p "$AZTEC_DIR"
  chmod -R 755 "$AZTEC_DIR"

  # 配置防火墙
  print_info "配置防火墙，开放端口 40400 和 8080..."
  ufw allow 40400/tcp >/dev/null 2>&1
  ufw allow 40400/udp >/dev/null 2>&1
  ufw allow 8080/tcp >/dev/null 2>&1
  print_info "防火墙状态："
  ufw status

  # 获取用户输入（支持环境变量覆盖）
  ETH_RPC="${ETH_RPC:-}"
  CONS_RPC="${CONS_RPC:-}"
  VALIDATOR_PRIVATE_KEYS="${VALIDATOR_PRIVATE_KEYS:-}"
  COINBASE="${COINBASE:-}"
  PUBLISHER_PRIVATE_KEY="${PUBLISHER_PRIVATE_KEY:-}"
  print_info "获取 RPC URL 和其他配置的说明："
  print_info "  - L1 执行客户端（EL）RPC URL："
  print_info "    1. 在 https://dashboard.alchemy.com/ 获取 Sepolia 的 RPC (http://xxx)"
  print_info ""
  print_info "  - L1 共识（CL）RPC URL："
  print_info "    1. 在 https://drpc.org/ 获取 Beacon Chain Sepolia 的 RPC (http://xxx)"
  print_info ""
  print_info "  - COINBASE：接收奖励的以太坊地址（格式：0x...）"
  print_info ""
  print_info "  - 验证者私钥：支持多个私钥，用逗号分隔（格式：0x123...,0x234...）"
  print_info ""
  print_info "  - 发布者私钥（可选）：用于提交交易的地址，仅需为此地址充值 Sepolia ETH"
  print_info ""
  if [ -z "$ETH_RPC" ]; then
    read -p " L1 执行客户端（EL）RPC URL： " ETH_RPC
  fi
  if [ -z "$CONS_RPC" ]; then
    read -p " L1 共识（CL）RPC URL： " CONS_RPC
  fi
  if [ -z "$VALIDATOR_PRIVATE_KEYS" ]; then
    read -p " 验证者私钥（多个私钥用逗号分隔，0x 开头）： " VALIDATOR_PRIVATE_KEYS
  fi
  if [ -z "$COINBASE" ]; then
    read -p " EVM钱包地址（以太坊地址，0x 开头）： " COINBASE
  fi
  read -p " 发布者私钥（可选，0x 开头，按回车跳过）： " PUBLISHER_PRIVATE_KEY
  BLOB_URL="" # 默认跳过 Blob Sink URL

  # 验证输入
  validate_url "$ETH_RPC" "L1 执行客户端（EL）RPC URL"
  validate_url "$CONS_RPC" "L1 共识（CL）RPC URL"
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
  VALIDATOR_FLAG="--sequencer.validatorPrivateKeys \$VALIDATOR_PRIVATE_KEYS"
  PUBLISHER_FLAG=""
  if [ -n "$PUBLISHER_PRIVATE_KEY" ]; then
    PUBLISHER_FLAG="--sequencer.publisherPrivateKey \$PUBLISHER_PRIVATE_KEY"
  fi
  BLOB_FLAG=""
  if [ -n "$BLOB_URL" ]; then
    BLOB_FLAG="--sequencer.blobSinkUrl \$BLOB_SINK_URL"
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
    entrypoint: >
      sh -c "node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network alpha-testnet --node --archiver --sequencer $VALIDATOR_FLAG $PUBLISHER_FLAG \${BLOB_FLAG:-}"
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
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if ! docker compose up -d; then
      echo "错误：docker compose up -d 失败，请检查 Docker 安装或配置。"
      echo "查看日志：docker logs -f aztec-sequencer"
      exit 1
    fi
  elif command -v docker-compose >/dev/null 2>&1; then
    if ! docker-compose up -d; then
      echo "错误：docker-compose up -d 失败，请检查 Docker Compose 安装或配置。"
      echo "查看日志：docker logs -f aztec-sequencer"
      exit 1
    fi
  else
    echo "错误：未找到 docker compose 或 docker-compose，请确保安装 Docker 和 Docker Compose。"
    exit 1
  fi

  # 完成
  print_info "安装和启动完成！"
  print_info "  - 查看日志：docker logs -f aztec-sequencer"
  print_info "  - 配置目录：$AZTEC_DIR"
  print_info "  - 数据目录：$DATA_DIR"
}

# 停止、删除 Docker（包括旧版本）、更新节点并重新创建 Docker
stop_delete_update_restart_node() {
  print_info "=== 停止节点、删除 Docker 容器（包括 $OLD_AZTEC_IMAGE）、更新节点并重新创建 Docker ==="

  read -p "警告：此操作将停止并删除 Aztec 容器（包括 $OLD_AZTEC_IMAGE）、更新 docker-compose.yml 到 $AZTEC_IMAGE、拉取最新镜像并重新创建 Docker，是否继续？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    print_info "已取消操作。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
  fi

  # 检查配置目录是否存在
  if [ ! -f "$AZTEC_DIR/docker-compose.yml" ]; then
    print_info "错误：未找到 $AZTEC_DIR/docker-compose.yml 文件，请先安装并启动节点。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
  fi

  # 检查并更新 docker-compose.yml 中的镜像版本
  if grep -q "image: $OLD_AZTEC_IMAGE" "$AZTEC_DIR/docker-compose.yml"; then
    print_info "检测到 docker-compose.yml 使用旧镜像 $OLD_AZTEC_IMAGE，正在更新为 $AZTEC_IMAGE..."
    sed -i "s|image: $OLD_AZTEC_IMAGE|image: $AZTEC_IMAGE|" "$AZTEC_DIR/docker-compose.yml"
    print_info "docker-compose.yml 已更新为 $AZTEC_IMAGE。"
  elif grep -q "image: $AZTEC_IMAGE" "$AZTEC_DIR/docker-compose.yml"; then
    print_info "docker-compose.yml 已使用最新镜像 $AZTEC_IMAGE，无需更新。"
  else
    print_info "警告：docker-compose.yml 包含未知镜像版本，建议重新运行选项 1 重新生成配置。"
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

  # 删除旧版本镜像 aztecprotocol/aztec:1.2.0
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
    echo "错误：未找到 aztec-up 命令，正在尝试重新安装 Aztec CLI..."
    install_aztec_cli
  else
    if ! aztec-up alpha-testnet 1.2.1; then  # 更新为 1.2.1
      echo "错误：aztec-up alpha-testnet 1.2.1 失败，请检查网络或 Aztec CLI 安装。"
      echo "按任意键返回主菜单..."
      read -n 1
      return
    fi
  fi

  # 更新 Aztec 镜像
  print_info "检查并拉取最新 Aztec 镜像 $AZTEC_IMAGE..."
  if ! docker pull "$AZTEC_IMAGE"; then
    echo "错误：无法拉取镜像 $AZTEC_IMAGE，请检查网络或 Docker 配置。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
  fi
  print_info "Aztec 镜像已更新到最新版本 $AZTEC_IMAGE。"

  # 重新创建并启动节点
  print_info "重新创建并启动 Aztec 节点..."
  cd "$AZTEC_DIR"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if ! docker compose up -d; then
      echo "错误：docker compose up -d 失败，请检查 Docker 安装或配置。"
      echo "查看日志：docker logs -f aztec-sequencer"
      echo "按任意键返回主菜单..."
      read -n 1
      return
    fi
  elif command -v docker-compose >/dev/null 2>&1; then
    if ! docker-compose up -d; then
      echo "错误：docker-compose up -d 失败，请检查 Docker Compose 安装或配置。"
      echo "查看日志：docker logs -f aztec-sequencer"
      echo "按任意键返回主菜单..."
      read -n 1
      return
    fi
  else
    echo "错误：未找到 docker compose 或 docker-compose，请确保安装 Docker 和 Docker Compose。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
  fi

  print_info "节点已停止、删除、更新并重新创建完成！"
  print_info "查看日志：docker logs -f aztec-sequencer"
  echo "按任意键返回主菜单..."
  read -n 1
}

# 获取区块高度和同步证明
get_block_and_proof() {
  if ! check_command jq; then
    print_info "未找到 jq，正在安装..."
    update_apt
    if ! install_package jq; then
      print_info "错误：无法安装 jq，请检查网络或 apt 源。"
      echo "按任意键返回主菜单..."
      read -n 1
      return
    fi
  fi

  if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    # 检查容器是否运行
    if ! docker ps -q -f name=aztec-sequencer | grep -q .; then
      print_info "错误：容器 aztec-sequencer 未运行，请先启动节点。"
      echo "按任意键返回主菜单..."
      read -n 1
      return
    fi

    print_info "获取当前区块高度..."
    BLOCK_NUMBER=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
      http://localhost:8080 | jq -r ".result.proven.number" || echo "")

    if [ -z "$BLOCK_NUMBER" ] || [ "$BLOCK_NUMBER" = "null" ]; then
      print_info "错误：无法获取区块高度（请等待半个小时后再查询），请确保节点正在运行并检查日志（docker logs -f aztec-sequencer）。"
      echo "按任意键返回主菜单..."
      read -n 1
      return
    fi

    print_info "当前区块高度：$BLOCK_NUMBER"
    print_info "获取同步证明..."
    PROOF=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d "$(jq -n --arg bn "$BLOCK_NUMBER" '{"jsonrpc":"2.0","method":"node_getArchiveSiblingPath","params":[$bn,$bn],"id":67}')" \
      http://localhost:8080 | jq -r ".result" || echo "")

    if [ -z "$PROOF" ] || [ "$PROOF" = "null" ]; then
      print_info "错误：无法获取同步证明，请确保节点正在运行并检查日志（docker logs -f aztec-sequencer）。"
    else
      print_info "同步一次证明：$PROOF"
    fi
  else
    print_info "错误：未找到 $AZTEC_DIR/docker-compose.yml 文件，请先安装并启动节点。"
  fi

  echo "按任意键返回主菜单..."
  read -n 1
}

# 注册验证者函数
register_validator() {
  print_info "[注册验证者]"

  read -p "是否继续注册验证者？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    print_info "已取消注册验证者。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
  fi

  read -p "请输入以太坊私钥（0x...）： " L1_PRIVATE_KEY
  read -p "请输入验证者地址（0x...）： " VALIDATOR_ADDRESS
  read -p "请输入 L1 RPC 地址： " L1_RPC

  # 验证输入
  validate_private_key "$L1_PRIVATE_KEY" "以太坊私钥"
  validate_address "$VALIDATOR_ADDRESS" "验证者地址"
  validate_url "$L1_RPC" "L1 RPC 地址"

  STAKING_ASSET_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"

  print_info "正在注册验证者..."
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! check_command aztec; then
    print_info "错误：未找到 aztec 命令，请确保已安装 Aztec CLI。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
  fi

  if aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC" \
    --private-key "$L1_PRIVATE_KEY" \
    --attester "$VALIDATOR_ADDRESS" \
    --proposer-eoa "$VALIDATOR_ADDRESS" \
    --staking-asset-handler "$STAKING_ASSET_HANDLER" \
    --l1-chain-id 11155111; then
    print_info "✅ 注册命令已执行。请检查链上状态确认是否成功。"
    print_info "请访问 Sepolia 测试网查看验证者状态："
    print_info "https://sepolia.etherscan.io/address/$VALIDATOR_ADDRESS"
  else
    print_info "错误：验证者注册失败，请检查输入参数或网络连接。"
  fi
  echo "按任意键返回主菜单..."
  read -n 1
}

# 删除 Docker 容器和节点数据
delete_docker_and_node() {
  print_info "=== 删除 Docker 容器和节点数据 ==="

  read -p "警告：此操作将停止并删除 Aztec 容器、配置文件和所有节点数据，且无法恢复。是否继续？(y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    print_info "已取消删除操作。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
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

  # 删除 Docker 镜像
  print_info "删除 Aztec 镜像 $AZTEC_IMAGE 和 $OLD_AZTEC_IMAGE..."
  if docker images -q "aztecprotocol/aztec" | sort -u | grep -q .; then
    docker rmi $(docker images -q "aztecprotocol/aztec" | sort -u) 2>/dev/null || true
    print_info "所有 aztecprotocol/aztec 镜像（包括 $AZTEC_IMAGE 和 $OLD_AZTEC_IMAGE）已删除。"
  else
    print_info "未找到 aztecprotocol/aztec 镜像。"
  fi

  # 删除配置文件和数据
  print_info "删除配置文件和数据目录..."
  if [ -d "$AZTEC_DIR" ]; then
    rm -rf "$AZTEC_DIR"
    print_info "配置文件目录 $AZTEC_DIR 已删除。"
  else
    print_info "未找到 $AZTEC_DIR 目录。"
  fi

  if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR"
    print_info "数据目录 $DATA_DIR 已删除。"
  else
    print_info "未找到 $DATA_DIR 目录。"
  fi

  # 清理临时世界状态数据库
  print_info "清理临时世界状态数据库..."
  rm -rf /tmp/aztec-world-state-* 2>/dev/null || true
  print_info "临时世界状态数据库已清理。"

  # 删除 Aztec CLI
  print_info "删除 Aztec CLI..."
  if [ -d "$HOME/.aztec" ]; then
    rm -rf "$HOME/.aztec"
    print_info "Aztec CLI 目录 $HOME/.aztec 已删除。"
  else
    print_info "未找到 $HOME/.aztec 目录。"
  fi

  print_info "所有 Docker 容器、镜像、配置文件和节点数据已删除。"
  print_info "如果需要重新部署，请选择菜单选项 1 安装并启动节点。"
  echo "按任意键返回主菜单..."
  read -n 1
}

# 修改节点状态检查函数，支持分布式节点
check_node_status() {
  # 颜色定义
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color

  echo -e "${BLUE}=== 🔍 区块链节点状态检查 ===${NC}"
  echo

  # 检查 Aztec 节点状态（本地）
  echo -e "${BLUE}📦 Aztec 节点状态 (本地):${NC}"
  if docker ps -q -f name=aztec-sequencer | grep -q .; then
    CONTAINER_STATUS=$(docker inspect aztec-sequencer --format='{{.State.Status}}' 2>/dev/null)
    if [ "$CONTAINER_STATUS" = "running" ]; then
      echo -e "  ${GREEN}✅ Aztec 容器: 运行中${NC}"
      
      # 检查端口监听
      if ss -tulnp | grep -q ':8080'; then
        echo -e "  ${GREEN}✅ RPC 端口 (8080): 监听中${NC}"
      else
        echo -e "  ${YELLOW}🟡 RPC 端口 (8080): 未监听${NC}"
      fi
      
      if ss -tulnp | grep -q ':40400'; then
        echo -e "  ${GREEN}✅ P2P 端口 (40400): 监听中${NC}"
      else
        echo -e "  ${YELLOW}🟡 P2P 端口 (40400): 未监听${NC}"
      fi
      
      # 检查日志中的错误
      RECENT_LOGS=$(docker logs --tail 20 aztec-sequencer 2>/dev/null)
      if echo "$RECENT_LOGS" | grep -q -i "error\|failed\|exception"; then
        echo -e "  ${YELLOW}🟡 最近日志: 发现错误${NC}"
      else
        echo -e "  ${GREEN}✅ 最近日志: 正常${NC}"
      fi
    else
      echo -e "  ${RED}❌ Aztec 容器: $CONTAINER_STATUS${NC}"
    fi
  else
    echo -e "  ${RED}❌ Aztec 容器: 未运行${NC}"
  fi

  echo

  # 检查 Ethereum 节点状态（远程或本地）
  echo -e "${BLUE}⛓️ Ethereum 节点状态:${NC}"
  
  # 获取 Ethereum 节点配置信息
  if [ -f "$AZTEC_DIR/.env" ]; then
    ETH_RPC=$(grep "ETHEREUM_HOSTS" "$AZTEC_DIR/.env" | cut -d'"' -f2)
    CONS_RPC=$(grep "L1_CONSENSUS_HOST_URLS" "$AZTEC_DIR/.env" | cut -d'"' -f2)
    
    if [ -n "$ETH_RPC" ]; then
      echo -e "  ${BLUE}🌐 执行层 RPC: $ETH_RPC${NC}"
      # 测试执行层连接
      if curl -s -X POST -H "Content-Type: application/json" \
         --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
         "$ETH_RPC" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✅ 执行层连接: 正常${NC}"
        
        # 获取执行层区块高度
        ETH_BLOCK=$(curl -s -X POST -H "Content-Type: application/json" \
          --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
          "$ETH_RPC" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$ETH_BLOCK" ]; then
          BLOCK_DEC=$(printf "%d" "$ETH_BLOCK")
          echo -e "  ${GREEN}✅ 执行层区块: $BLOCK_DEC${NC}"
        fi
      else
        echo -e "  ${RED}❌ 执行层连接: 失败${NC}"
      fi
    else
      echo -e "  ${YELLOW}🟡 执行层 RPC: 未配置${NC}"
    fi

    if [ -n "$CONS_RPC" ]; then
      echo -e "  ${BLUE}🌐 共识层 RPC: $CONS_RPC${NC}"
      # 测试共识层连接
      if curl -s "$CONS_RPC/eth/v1/node/health" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✅ 共识层连接: 正常${NC}"
        
        # 获取共识层同步状态
        SYNC_STATUS=$(curl -s "$CONS_RPC/eth/v1/node/syncing" 2>/dev/null || echo "{}")
        if echo "$SYNC_STATUS" | grep -q '"is_syncing":false'; then
          echo -e "  ${GREEN}✅ 共识层同步: 完全同步${NC}"
        elif echo "$SYNC_STATUS" | grep -q '"is_syncing":true'; then
          SYNC_DISTANCE=$(echo "$SYNC_STATUS" | grep -o '"sync_distance":"[^"]*"' | cut -d'"' -f4)
          echo -e "  ${YELLOW}🟡 共识层同步: 同步中 (距离: $SYNC_DISTANCE)${NC}"
        else
          echo -e "  ${YELLOW}🟡 共识层同步: 未知${NC}"
        fi
      else
        echo -e "  ${RED}❌ 共识层连接: 失败${NC}"
      fi
    else
      echo -e "  ${YELLOW}🟡 共识层 RPC: 未配置${NC}"
    fi
  else
    echo -e "  ${YELLOW}🟡 Ethereum 节点: 未配置 (.env 文件不存在)${NC}"
  fi

  echo

  # 检查本地 Ethereum 节点（如果存在）
  echo -e "${BLUE}💻 本地 Ethereum 节点状态:${NC}"
  
  # 检查本地 Geth
  if systemctl is-active --quiet geth 2>/dev/null; then
    echo -e "  ${GREEN}✅ 本地 Geth: 运行中${NC}"
    
    # 检查 Geth 端口
    if ss -tulnp | grep -q ':8545'; then
      echo -e "  ${GREEN}✅ 本地 Geth RPC (8545): 监听中${NC}"
    else
      echo -e "  ${YELLOW}🟡 本地 Geth RPC (8545): 未监听${NC}"
    fi
  else
    echo -e "  ${BLUE}ℹ️  本地 Geth: 未运行 (可能使用远程节点)${NC}"
  fi

  # 检查本地 Lighthouse
  if systemctl is-active --quiet lighthouse 2>/dev/null; then
    echo -e "  ${GREEN}✅ 本地 Lighthouse: 运行中${NC}"
    
    # 检查 Lighthouse 端口
    if ss -tulnp | grep -q ':5052'; then
      echo -e "  ${GREEN}✅ 本地 Lighthouse API (5052): 监听中${NC}"
    else
      echo -e "  ${YELLOW}🟡 本地 Lighthouse API (5052): 未监听${NC}"
    fi
  else
    echo -e "  ${BLUE}ℹ️  本地 Lighthouse: 未运行 (可能使用远程节点)${NC}"
  fi

  echo

  # 系统资源检查
  echo -e "${BLUE}💻 系统资源状态:${NC}"
  
  # 内存使用
  MEM_USED=$(free -m | awk 'NR==2{printf "%.1f", $3*100/$2}')
  if (( $(echo "$MEM_USED < 80" | bc -l) )); then
    echo -e "  ${GREEN}✅ 内存使用: ${MEM_USED}%${NC}"
  else
    echo -e "  ${YELLOW}🟡 内存使用: ${MEM_USED}% (较高)${NC}"
  fi
  
  # 磁盘使用
  DISK_USED=$(df / | awk 'NR==2{printf "%.1f", $5}')
  DISK_USED=${DISK_USED%\%}
  if (( $(echo "$DISK_USED < 80" | bc -l) )); then
    echo -e "  ${GREEN}✅ 磁盘使用: ${DISK_USED}%${NC}"
  else
    echo -e "  ${YELLOW}🟡 磁盘使用: ${DISK_USED}% (较高)${NC}"
  fi

  # CPU 负载
  LOAD_AVG=$(cat /proc/loadavg | awk '{print $1}')
  CPU_CORES=$(nproc)
  if (( $(echo "$LOAD_AVG < $CPU_CORES" | bc -l) )); then
    echo -e "  ${GREEN}✅ CPU 负载: $LOAD_AVG${NC}"
  else
    echo -e "  ${YELLOW}🟡 CPU 负载: $LOAD_AVG (较高)${NC}"
  fi

  echo
  echo -e "${BLUE}=== 🎯 状态总结 ===${NC}"
  
  # 总体状态判断
  AZTEC_RUNNING=$(docker ps -q -f name=aztec-sequencer | wc -l)
  ETH_CONNECTION=0
  CONS_CONNECTION=0
  
  # 检查 Ethereum 连接状态
  if [ -n "$ETH_RPC" ] && curl -s -X POST -H "Content-Type: application/json" \
     --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
     "$ETH_RPC" > /dev/null 2>&1; then
    ETH_CONNECTION=1
  fi
  
  if [ -n "$CONS_RPC" ] && curl -s "$CONS_RPC/eth/v1/node/health" > /dev/null 2>&1; then
    CONS_CONNECTION=1
  fi
  
  TOTAL_STATUS=$((AZTEC_RUNNING + ETH_CONNECTION + CONS_CONNECTION))
  
  if [ $TOTAL_STATUS -eq 3 ]; then
    echo -e "${GREEN}🟢 所有服务正常运行！${NC}"
    echo -e "${GREEN}   • Aztec 节点: 运行中${NC}"
    echo -e "${GREEN}   • Ethereum 执行层: 连接正常${NC}"
    echo -e "${GREEN}   • Ethereum 共识层: 连接正常${NC}"
  elif [ $TOTAL_STATUS -ge 1 ]; then
    echo -e "${YELLOW}🟡 部分服务运行中 ($TOTAL_STATUS/3)${NC}"
    [ $AZTEC_RUNNING -eq 1 ] && echo -e "${GREEN}   • Aztec 节点: 运行中${NC}" || echo -e "${RED}   • Aztec 节点: 未运行${NC}"
    [ $ETH_CONNECTION -eq 1 ] && echo -e "${GREEN}   • Ethereum 执行层: 连接正常${NC}" || echo -e "${RED}   • Ethereum 执行层: 连接失败${NC}"
    [ $CONS_CONNECTION -eq 1 ] && echo -e "${GREEN}   • Ethereum 共识层: 连接正常${NC}" || echo -e "${RED}   • Ethereum 共识层: 连接失败${NC}"
  else
    echo -e "${RED}🔴 所有服务均未运行${NC}"
  fi

  echo
  echo "按任意键返回主菜单..."
  read -n 1
}

# 主菜单函数
main_menu() {
  while true; do
    clear
    echo "脚本由哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
    echo "如有问题，可联系推特，仅此只有一个号"
    echo "================================================================"
    echo "退出脚本，请按键盘 ctrl + C 退出即可"
    echo "请选择要执行的操作:"
    echo "1. 安装并启动 Aztec 节点"
    echo "2. 查看节点日志"
    echo "3. 获取区块高度和同步证明（请等待半个小时后再查询）"
    echo "4. 停止节点、删除 Docker 容器、更新节点并重新创建 Docker"
    echo "5. 注册验证者"
    echo "6. 删除 Docker 容器和节点数据"
    echo "7. 检查节点状态"
    echo "8. 退出"
    read -p "请输入选项 (1-8): " choice

    case $choice in
      1)
        install_and_start_node
        echo "按任意键返回主菜单..."
        read -n 1
        ;;
      2)
        if [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
          print_info "查看节点日志（最近 100 条，实时更新）..."
          docker logs --tail 100 aztec-sequencer > /tmp/aztec_logs.txt 2>/dev/null
          if grep -q "does not match the expected genesis archive" /tmp/aztec_logs.txt; then
            print_info "检测到错误：创世归档树根不匹配！"
            print_info "建议：1. 确保使用最新镜像 $AZTEC_IMAGE"
            print_info "      2. 清理旧数据：rm -rf /tmp/aztec-world-state-* $DATA_DIR"
            print_info "      3. 重新运行 aztec-up alpha-testnet 和 aztec start"
            print_info "      4. 检查 L1 RPC URL 是否正确（Sepolia 网络）"
            print_info "      5. 联系 Aztec 社区寻求帮助"
          fi
          docker logs -f --tail 100 aztec-sequencer
        else
          print_info "错误：未找到 $AZTEC_DIR/docker-compose.yml 文件，请先运行并启动节点..."
        fi
        echo "按任意键返回主菜单..."
        read -n 1
        ;;
      3)
        get_block_and_proof
        ;;
      4)
        stop_delete_update_restart_node
        ;;
      5)
        register_validator
        ;;
      6)
        delete_docker_and_node
        ;;
      7)
        check_node_status
        ;;
      8)
        print_info "退出脚本..."
        exit 0
        ;;
      *)
        print_info "无效输入选项，请重新输入 1-8..."
        echo "按任意键返回主菜单..."
        read -n 1
        ;;
    esac
  done
}

# 执行主菜单
main_menu
