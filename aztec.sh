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
OLD_AZTEC_IMAGE="aztecprotocol/aztec:2.0.2"
GOVERNANCE_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"

# 函数：打印信息
print_info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
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
      print_info "Docker 已安装，版本 $version。"
      return
    else
      print_info "Docker 版本 $version 过低，将重新安装..."
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
      print_info "Docker Compose 已安装，版本 $version。"
      return
    else
      print_info "Docker Compose 版本 $version 过低，将重新安装..."
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
  if docker images "$AZTEC_IMAGE" | grep -q "2.0.4"; then
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
  if ! aztec-up alpha-testnet 2.0.4; then
    echo "错误：aztec-up alpha-testnet 2.0.4 命令执行失败，请检查网络或 Aztec CLI 安装。"
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

# ==================== 终极修复版：执行治理提案投票 ====================
vote_governance_proposal() {
  print_info "=== 执行治理提案投票（2.0.4） ==="

  # 检查容器是否运行
  if ! docker ps -q -f name=aztec-sequencer | grep -q .; then
    print_info "错误：容器 aztec-sequencer 未运行，请先启动节点（选项 1）。"
    echo "按任意键返回主菜单..."
    read -n 1
    return
  fi

  # 确认操作
  read -p "警告：此操作将向节点发送治理提案信号，确认继续？(y/n): " confirm
  [[ "$confirm" != "y" ]] && { print_info "已取消投票。"; echo "按任意键返回主菜单..."; read -n 1; return; }

  print_info "正在通过容器内部执行投票..."

  # 关键修复：使用 sh -c + || echo 防止中断
  RESPONSE=""
  set +e  # 临时禁用 set -e
  RESPONSE=$(docker exec aztec-sequencer sh -c "\
    curl -s --connect-timeout 15 \
      -X POST http://127.0.0.1:8880 \
      -H 'Content-Type: application/json' \
      -d '{\"jsonrpc\":\"2.0\",\"method\":\"nodeAdmin_setConfig\",\"params\":[{\"governanceProposerPayload\":\"$GOVERNANCE_PAYLOAD\"}],\"id\":1}' \
    || echo '{\"error\":\"curl failed or timeout\"}'" 2>/dev/null || echo '{"error":"docker exec failed"}')
  set -e  # 恢复 set -e

  print_info "原始返回: $RESPONSE"

  # 检查返回结果
  if echo "$RESPONSE" | grep -q '"result":true'; then
    print_info "投票成功！治理提案已信号。"
    print_info "Payload: $GOVERNANCE_PAYLOAD"
  elif echo "$RESPONSE" | grep -q "method not found"; then
    print_info "失败：nodeAdmin_setConfig 方法未找到。"
    print_info "请执行 选项 4 升级到 2.0.4 并重启节点"
  elif echo "$RESPONSE" | grep -q "curl failed\|timeout\|docker exec failed"; then
    print_info "失败：无法连接到 admin RPC (8880)"
    print_info "请检查："
    print_info "  1. docker logs aztec-sequencer | grep 'Admin RPC'"
    print_info "  2. ss -tulnp | grep 8880"
  elif [ -z "$RESPONSE" ] || [[ "$RESPONSE" == "null" ]]; then
    print_info "失败：空响应，请检查节点日志"
  else
    print_info "投票失败，返回：$RESPONSE"
  fi

  # 写入 .env 持久化环境变量
  ENV_FILE="$AZTEC_DIR/.env"
  if [ -f "$ENV_FILE" ] && ! grep -q "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS" "$ENV_FILE"; then
    echo "GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=\"$GOVERNANCE_PAYLOAD\"" >> "$ENV_FILE"
    print_info "已写入环境变量（重启后仍生效）。"
  fi

  print_info "投票流程结束。"
  echo "按任意键返回主菜单..."
  read -n 1
}

# 主逻辑：安装和启动 Aztec 节点（启用 admin RPC）
install_and_start_node() {
  print_info "清理旧配置和数据..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/docker-compose.yml"
  rm -rf /tmp/aztec-world-state-* "$DATA_DIR"
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  install_docker
  install_docker_compose
  install_nodejs
  install_aztec_cli
  check_aztec_image_version

  print_info "创建 Aztec 配置目录 $AZTEC_DIR..."
  mkdir -p "$AZTEC_DIR"
  chmod -R 755 "$AZTEC_DIR"

  print_info "配置防火墙..."
  ufw allow 40400/tcp >/dev/null 2>&1
  ufw allow 40400/udp >/dev/null 2>&1
  ufw allow 8080/tcp >/dev/null 2>&1

  ETH_RPC="${ETH_RPC:-}"
  CONS_RPC="${CONS_RPC:-}"
  VALIDATOR_PRIVATE_KEYS="${VALIDATOR_PRIVATE_KEYS:-}"
  COINBASE="${COINBASE:-}"
  PUBLISHER_PRIVATE_KEY="${PUBLISHER_PRIVATE_KEY:-}"

  if [ -z "$ETH_RPC" ]; then read -p " L1 执行客户端（EL）RPC URL： " ETH_RPC; fi
  if [ -z "$CONS_RPC" ]; then read -p " L1 共识（CL）RPC URL： " CONS_RPC; fi
  if [ -z "$VALIDATOR_PRIVATE_KEYS" ]; then read -p " 验证者私钥（多个用逗号分隔）： " VALIDATOR_PRIVATE_KEYS; fi
  if [ -z "$COINBASE" ]; then read -p " EVM钱包地址（0x...）： " COINBASE; fi
  read -p " 发布者私钥（可选，回车跳过）： " PUBLISHER_PRIVATE_KEY

  validate_url "$ETH_RPC" "L1 执行客户端 RPC"
  validate_url "$CONS_RPC" "L1 共识客户端 RPC"
  validate_private_keys "$VALIDATOR_PRIVATE_KEYS" "验证者私钥"
  validate_address "$COINBASE" "COINBASE 地址"
  [ -n "$PUBLISHER_PRIVATE_KEY" ] && validate_private_key "$PUBLISHER_PRIVATE_KEY" "发布者私钥"

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
  chmod 600 "$AZTEC_DIR/.env"

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
          --api.admin-rpc-http-host 0.0.0.0 \
          --api.admin-rpc-http-port 8880
      "
    volumes:
      - /root/.aztec/alpha-testnet/data/:/data
EOF
  chmod 644 "$AZTEC_DIR/docker-compose.yml"

  mkdir -p "$DATA_DIR"
  chmod -R 755 "$DATA_DIR"

  print_info "启动 Aztec 全节点（已启用 admin RPC）..."
  cd "$AZTEC_DIR"
  docker compose up -d || docker-compose up -d

  print_info "安装完成！"
  print_info "请在 30 秒后执行 选项 9 完成投票！"
}

# 停止、删除、更新、重启
stop_delete_update_restart_node() {
  print_info "=== 升级到 2.0.4 并重新创建容器 ==="
  read -p "确认继续？(y/n): " confirm
  [[ "$confirm" != "y" ]] && return

  [ -f "$AZTEC_DIR/docker-compose.yml" ] || { print_info "未找到配置，请先安装。"; return; }

  sed -i "s|image: .*|image: $AZTEC_IMAGE|" "$AZTEC_DIR/docker-compose.yml" 2>/dev/null || true
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true
  docker rmi "$OLD_AZTEC_IMAGE" 2>/dev/null || true
  docker pull "$AZTEC_IMAGE"
  cd "$AZTEC_DIR"
  docker compose up -d || docker-compose up -d
  print_info "升级完成！请等待 30 秒后执行选项 9 投票。"
}

# 获取区块高度和同步证明
get_block_and_proof() {
  check_command jq || { update_apt; install_package jq; }
  [ -f "$AZTEC_DIR/docker-compose.yml" ] || { print_info "未找到配置。"; return; }
  docker ps -q -f name=aztec-sequencer | grep -q . || { print_info "容器未运行。"; return; }

  BLOCK_NUMBER=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
    http://localhost:8080 | jq -r ".result.proven.number")

  [ -z "$BLOCK_NUMBER" ] || [ "$BLOCK_NUMBER" = "null" ] && { print_info "无法获取区块高度。"; return; }
  print_info "当前区块高度：$BLOCK_NUMBER"

  PROOF=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg bn "$BLOCK_NUMBER" '{"jsonrpc":"2.0","method":"node_getArchiveSiblingPath","params":[$bn,$bn],"id":67}')" \
    http://localhost:8080 | jq -r ".result")
  [ -n "$PROOF" ] && [ "$PROOF" != "null" ] && print_info "同步证明：$PROOF"
}

# 注册验证者
register_validator() {
  print_info "[注册验证者]"
  read -p "继续？(y/n): " confirm; [[ "$confirm" != "y" ]] && return
  read -p "以太坊私钥： " L1_PRIVATE_KEY
  read -p "验证者地址： " VALIDATOR_ADDRESS
  read -p "L1 RPC： " L1_RPC

  validate_private_key "$L1_PRIVATE_KEY" "私钥"
  validate_address "$VALIDATOR_ADDRESS" "地址"
  validate_url "$L1_RPC" "RPC"

  export PATH="$HOME/.aztec/bin:$PATH"
  aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC" \
    --private-key "$L1_PRIVATE_KEY" \
    --attester "$VALIDATOR_ADDRESS" \
    --proposer-eoa "$VALIDATOR_ADDRESS" \
    --staking-asset-handler "0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2" \
    --l1-chain-id 11155111 && print_info "注册成功！"
}

# 删除所有
delete_docker_and_node() {
  print_info "=== 删除所有数据 ==="
  read -p "确认？(y/n): " confirm; [[ "$confirm" != "y" ]] && return
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true
  docker rmi $(docker images -q aztecprotocol/aztec | sort -u) 2>/dev/null || true
  rm -rf "$AZTEC_DIR" "$DATA_DIR" /tmp/aztec-world-state-* "$HOME/.aztec"
  print_info "清理完成。"
}

# 检查节点状态
check_node_status() {
  print_info "检查中..."
  docker ps | grep aztec-sequencer && print_info "容器运行中" || print_info "容器未运行"
  ss -tulnp | grep -q ':8080' && print_info "RPC 8080 监听" || print_info "RPC 未监听"
  ss -tulnp | grep -q ':8880' && print_info "Admin RPC 8880 监听" || print_info "Admin RPC 未监听"
  docker logs aztec-sequencer --tail 10 | grep -i "Admin RPC" || true
}

# 主菜单
main_menu() {
  while true; do
    clear
    echo "Aztec 节点管理脚本（支持 2.0.4 升级 + 投票）"
    echo "脚本由哈哈哈哈编写，推特 @ferdie_jhovie"
    echo "========================================"
    echo "1. 安装并启动 Aztec 节点（2.0.4）"
    echo "2. 查看节点日志"
    echo "3. 获取区块高度和同步证明"
    echo "4. 停止、删除、升级到 2.0.4 并重启"
    echo "5. 注册验证者"
    echo "6. 删除所有数据"
    echo "7. 检查节点状态"
    echo "9. 执行治理提案投票（2.0.4）"
    echo "8. 退出"
    read -p "请输入选项 (1-9): " choice

    case $choice in
      1) install_and_start_node; read -n 1 ;;
      2) docker logs -f --tail 100 aztec-sequencer; read -n 1 ;;
      3) get_block_and_proof; read -n 1 ;;
      4) stop_delete_update_restart_node; read -n 1 ;;
      5) register_validator; read -n 1 ;;
      6) delete_docker_and_node; read -n 1 ;;
      7) check_node_status; read -n 1 ;;
      9) vote_governance_proposal; read -n 1 ;;
      8) exit 0 ;;
      *) print_info "无效选项"; read -n 1 ;;
    esac
  done
}

main_menu
