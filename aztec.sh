#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行"
  exit 1
fi

# ==================== 常量 ====================
AZTEC_DIR="/root/aztec-sequencer"
DATA_DIR="/root/aztec-sequencer/data"
KEY_DIR="/root/aztec-sequencer/keys"
AZTEC_IMAGE="aztecprotocol/aztec:2.1.2"
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
DASHTEC_URL="https://dashtec.xyz"

# ==================== 安全配置 ====================
KEYSTORE_FILE="$HOME/.aztec/keystore/key1.json"
BACKUP_DIR="/root/aztec-backup-$(date +%Y%m%d-%H%M%S)"

# ==================== 打印函数 ====================
print_info()    { echo -e "\033[1;34m[INFO]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1" >&2; }
print_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1" >&2; }

# ==================== 环境检查与安装 ====================
install_dependencies() {
  print_info "检查并安装必要的依赖..."
  
  # 更新系统
  apt-get update >/dev/null 2>&1
  
  # 安装基础工具
  local base_packages=("curl" "jq" "net-tools")
  for pkg in "${base_packages[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
      print_info "安装 $pkg..."
      apt-get install -y "$pkg" >/dev/null 2>&1
    fi
  done
  
  # 检查并安装 Docker
  if ! command -v docker >/dev/null 2>&1; then
    print_info "安装 Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
  fi
  
  # 检查并安装 Docker Compose
  if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    print_info "安装 Docker Compose..."
    apt-get install -y docker-compose-plugin >/dev/null 2>&1
  fi
  
  # 检查并安装 Foundry (cast)
  if ! command -v cast >/dev/null 2>&1; then
    print_info "安装 Foundry..."
    curl -L https://foundry.paradigm.xyz | bash >/dev/null 2>&1
    # 重新加载 bashrc
    if [ -f ~/.bashrc ]; then
      source ~/.bashrc >/dev/null 2>&1
    fi
    # 确保 foundryup 在 PATH 中
    export PATH="$HOME/.foundry/bin:$PATH"
    # 安装 foundry
    ~/.foundry/bin/foundryup >/dev/null 2>&1 || {
      print_warning "Foundry 安装遇到问题，尝试替代方法..."
      curl -L https://foundry.paradigm.xyz | bash
      source ~/.bashrc
      foundryup
    }
  fi
  
  # 检查并安装 Aztec CLI
  if ! command -v aztec >/dev/null 2>&1; then
    print_info "安装 Aztec CLI..."
    curl -sL https://install.aztec.network | bash >/dev/null 2>&1
    export PATH="$HOME/.aztec/bin:$PATH"
  fi
  
  # 最终验证
  local missing_tools=()
  for tool in docker jq cast aztec; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools+=("$tool")
    fi
  done
  
  if [ ${#missing_tools[@]} -ne 0 ]; then
    print_error "以下工具安装失败: ${missing_tools[*]}"
    print_info "请手动安装:"
    echo "  # 安装 Docker"
    echo "  curl -fsSL https://get.docker.com | sh"
    echo "  # 安装 Foundry"  
    echo "  curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup"
    echo "  # 安装 Aztec CLI"
    echo "  curl -sL https://install.aztec.network | bash"
    return 1
  fi
  
  print_success "所有依赖安装完成"
  return 0
}

validate_environment() {
  print_info "检查环境依赖..."
  
  local missing_tools=()
  
  for tool in docker jq cast aztec; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools+=("$tool")
    fi
  done
  
  if [ ${#missing_tools[@]} -ne 0 ]; then
    print_warning "缺少必要的工具: ${missing_tools[*]}"
    print_info "开始自动安装..."
    if ! install_dependencies; then
      print_error "依赖安装失败，请手动安装上述工具"
      return 1
    fi
  fi
  
  # 确保 PATH 正确
  export PATH="$HOME/.foundry/bin:$PATH"
  export PATH="$HOME/.aztec/bin:$PATH"
  
  print_success "环境检查通过"
  return 0
}

# ==================== 安全函数 ====================
secure_cleanup() {
  print_info "清理敏感信息..."
  unset OLD_PRIVATE_KEY NEW_ETH_PRIVATE_KEY NEW_BLS_PRIVATE_KEY
  history -c
  clear
}

backup_keys() {
  print_info "备份密钥文件..."
  mkdir -p "$BACKUP_DIR"
  if [ -f "$KEYSTORE_FILE" ]; then
    cp "$KEYSTORE_FILE" "$BACKUP_DIR/"
    print_success "密钥已备份到: $BACKUP_DIR/"
  fi
}

# ==================== RPC 检查 ====================
check_rpc_connection() {
  local url=$1 name=$2
  print_info "检查 $name RPC 连接..."
  
  local result
  if [[ "$url" == *"8545"* ]] || [[ "$url" == *"8545"* ]]; then
    result=$(timeout 10 curl -s -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      "$url" 2>/dev/null | grep -o '"result":"0x[^"]*"' || echo "")
  else
    result=$(timeout 10 curl -s "$url/eth/v1/beacon/headers/head" 2>/dev/null | grep -o '"slot":"[0-9]*"' || echo "")
  fi
  
  if [[ -z "$result" ]]; then
    print_error "$name RPC 连接失败: $url"
    return 1
  fi
  print_success "$name RPC 正常 ($result)"
  return 0
}

# ==================== 密钥生成 ====================
generate_new_keys() {
  print_info "生成新的验证者密钥..."
  
  # 备份现有密钥
  backup_keys
  
  # 清理旧密钥
  rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
  
  if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1; then
    print_error "BLS 密钥生成失败"
    return 1
  fi
  
  if [ ! -f "$KEYSTORE_FILE" ]; then
    print_error "密钥文件未生成: $KEYSTORE_FILE"
    return 1
  fi
  
  # 安全读取密钥信息
  local eth_key bls_key new_address
  
  eth_key=$(jq -r '.eth' "$KEYSTORE_FILE" 2>/dev/null | tr -d '[:space:]')
  bls_key=$(jq -r '.bls' "$KEYSTORE_FILE" 2>/dev/null | tr -d '[:space:]')
  new_address=$(cast wallet address --private-key "$eth_key" 2>/dev/null)
  
  if [[ -z "$eth_key" || -z "$bls_key" || ! "$new_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "密钥信息读取失败"
    return 1
  fi
  
  print_success "新验证者地址: $new_address"
  printf "%s %s %s" "$eth_key" "$bls_key" "$new_address"
  return 0
}

# ==================== STAKE 授权 ====================
check_and_approve_stake() {
  local old_pk=$1 rpc_url=$2
  print_info "检查 STAKE 授权状态..."
  
  local old_address
  old_address=$(cast wallet address --private-key "$old_pk" 2>/dev/null)
  
  # 检查当前授权额度
  local allowance
  allowance=$(cast call "$STAKE_TOKEN" "allowance(address,address)(uint256)" \
    "$old_address" "$ROLLUP_CONTRACT" --rpc-url "$rpc_url" 2>/dev/null || echo "0")
  
  if [[ "$allowance" != "0" && "$allowance" != "0x0" ]]; then
    print_success "检测到已有授权额度: $allowance (跳过授权)"
    return 0
  fi
  
  print_info "执行 STAKE 代币授权..."
  local tx_hash
  tx_hash=$(cast send "$STAKE_TOKEN" "approve(address,uint256)" \
    "$ROLLUP_CONTRACT" "200000ether" \
    --private-key "$old_pk" --rpc-url "$rpc_url" 2>/dev/null | grep -oE '0x[a-fA-F0-9]{64}' | head -n 1)
  
  if [ -z "$tx_hash" ]; then
    print_error "授权交易失败"
    return 1
  fi
  
  print_success "授权交易已发送: $tx_hash"
  print_info "等待交易确认..."
  sleep 10
  return 0
}

# ==================== 验证者注册 ====================
register_validator() {
  local old_pk=$1 new_addr=$2 bls_key=$3 rpc_url=$4
  print_info "检查验证者注册状态..."
  
  # 检查是否已注册
  local is_registered
  is_registered=$(cast call "$ROLLUP_CONTRACT" "isValidator(address)(bool)" \
    "$new_addr" --rpc-url "$rpc_url" 2>/dev/null || echo "false")
  
  if [ "$is_registered" == "true" ]; then
    print_success "该地址已经是验证者 (跳过注册)"
    return 0
  fi
  
  print_info "注册验证者到 L1..."
  local reg_output
  reg_output=$(aztec add-l1-validator \
    --l1-rpc-urls "$rpc_url" \
    --network testnet \
    --private-key "$old_pk" \
    --attester "$new_addr" \
    --withdrawer "$new_addr" \
    --bls-secret-key "$bls_key" \
    --rollup "$ROLLUP_CONTRACT" 2>&1)
  
  if echo "$reg_output" | grep -qE '0x[a-fA-F0-9]{64}'; then
    local tx_hash
    tx_hash=$(echo "$reg_output" | grep -oE '0x[a-fA-F0-9]{64}' | head -n 1)
    print_success "注册交易已发送: $tx_hash"
  else
    print_warning "未检测到交易哈希，请手动确认注册状态"
    echo "$reg_output"
  fi
  
  return 0
}

# ==================== 节点安装 ====================
setup_node_environment() {
  print_info "设置节点环境..."
  
  # 清理旧数据
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true
  rm -rf "$AZTEC_DIR" 2>/dev/null || true
  
  # 创建目录结构
  mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"
  
  # 复制密钥文件
  if [ -f "$KEYSTORE_FILE" ]; then
    cp "$KEYSTORE_FILE" "$KEY_DIR/keystore.json"
    print_success "密钥文件已复制"
  else
    print_error "未找到密钥文件: $KEYSTORE_FILE"
    return 1
  fi
  
  # 获取公网 IP
  local public_ip
  public_ip=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")
  
  # 生成环境配置
  cat > "$AZTEC_DIR/.env" <<EOF
# Aztec 2.1.2 节点配置
DATA_DIRECTORY=./data
KEY_STORE_DIRECTORY=./keys
LOG_LEVEL=info
ETHEREUM_HOSTS=${ETH_RPC}
L1_CONSENSUS_HOST_URLS=${CONS_RPC}
P2P_IP=${public_ip}
P2P_PORT=40400
AZTEC_PORT=8080
AZTEC_ADMIN_PORT=8880
EOF

  # 生成 Docker 配置
  cat > "$AZTEC_DIR/docker-compose.yml" <<'EOF'
services:
  aztec-sequencer:
    image: "aztecprotocol/aztec:2.1.2"
    container_name: "aztec-sequencer"
    ports:
      - ${AZTEC_PORT}:${AZTEC_PORT}
      - ${AZTEC_ADMIN_PORT}:${AZTEC_ADMIN_PORT}
      - ${P2P_PORT}:${P2P_PORT}
      - ${P2P_PORT}:${P2P_PORT}/udp
    volumes:
      - ${DATA_DIRECTORY}:/var/lib/data
      - ${KEY_STORE_DIRECTORY}:/var/lib/keystore
    environment:
      KEY_STORE_DIRECTORY: /var/lib/keystore
      DATA_DIRECTORY: /var/lib/data
      LOG_LEVEL: ${LOG_LEVEL}
      ETHEREUM_HOSTS: ${ETHEREUM_HOSTS}
      L1_CONSENSUS_HOST_URLS: ${L1_CONSENSUS_HOST_URLS}
      P2P_IP: ${P2P_IP}
      P2P_PORT: ${P2P_PORT}
      AZTEC_PORT: ${AZTEC_PORT}
      AZTEC_ADMIN_PORT: ${AZTEC_ADMIN_PORT}
    entrypoint: >-
      node
      --no-warnings
      /usr/src/yarn-project/aztec/dest/bin/index.js
      start
      --node
      --archiver
      --sequencer
      --network testnet
    networks:
      - aztec
    restart: always

networks:
  aztec:
    name: aztec
EOF

  print_success "节点环境设置完成"
  return 0
}

# ==================== 主安装流程 ====================
install_and_start_node() {
  clear
  print_info "Aztec 2.1.2 测试网节点安装 (安全优化版)"
  echo "=========================================="
  print_warning "重要安全提示："
  print_info "1. 请确保在安全环境中运行"
  print_info "2. 私钥信息会自动清理"
  print_info "3. 密钥文件会自动备份"
  echo "=========================================="

  # 环境检查
  if ! validate_environment; then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 获取用户输入
  read -p "L1 执行 RPC URL (Sepolia): " ETH_RPC
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC
  read -sp "旧验证者私钥 (有 200k STAKE): " OLD_PRIVATE_KEY && echo
  print_info "输入完成，开始验证..."

  # 输入验证
  if [[ ! "$OLD_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    print_error "私钥格式错误"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # RPC 连接检查
  if ! check_rpc_connection "$ETH_RPC" "执行层"; then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  if ! check_rpc_connection "$CONS_RPC" "共识层"; then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 显示旧地址
  local old_address
  old_address=$(cast wallet address --private-key "$OLD_PRIVATE_KEY" 2>/dev/null)
  print_info "旧验证者地址: $old_address"

  # 生成新密钥
  local keys_output
  if ! keys_output=$(generate_new_keys); then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  local new_eth_key new_bls_key new_address
  read new_eth_key new_bls_key new_address <<< "$keys_output"

  # 显示密钥信息（安全提示）
  print_warning "请立即保存以下密钥信息！"
  echo "=========================================="
  echo "新的以太坊私钥: $new_eth_key"
  echo "新的 BLS 私钥: $new_bls_key"  
  echo "新的公钥地址: $new_address"
  echo "=========================================="
  print_warning "这些信息只会显示一次！请立即保存！"
  read -p "确认已保存密钥信息后按 [Enter] 继续..."

  # STAKE 授权
  if ! check_and_approve_stake "$OLD_PRIVATE_KEY" "$ETH_RPC"; then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 资金提示
  print_warning "请向新地址转入 0.2-0.5 Sepolia ETH:"
  echo "   $new_address"
  print_info "转账命令:"
  echo "   cast send $new_address --value 0.3ether --private-key $OLD_PRIVATE_KEY --rpc-url $ETH_RPC"
  read -p "转账完成后按 [Enter] 继续..."

  # 注册验证者
  if ! register_validator "$OLD_PRIVATE_KEY" "$new_address" "$new_bls_key" "$ETH_RPC"; then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 设置节点环境
  if ! setup_node_environment; then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 启动节点
  print_info "启动 Aztec 节点..."
  cd "$AZTEC_DIR"
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d
  else
    docker compose up -d
  fi

  # 安全清理
  secure_cleanup

  # 完成信息
  print_success "Aztec 2.1.2 节点部署完成！"
  echo
  print_info "新验证者地址: $new_address"
  print_info "排队查询: $DASHTEC_URL/validator/$new_address"
  print_info "查看日志: docker logs -f aztec-sequencer"
  print_info "查看状态: curl http://localhost:8080/status"
  print_info "数据目录: $AZTEC_DIR"
  print_info "密钥备份: $BACKUP_DIR"
  
  read -n 1 -s -r -p "按任意键继续..."
}

# ==================== 菜单功能 ====================
view_node_logs() {
  if docker ps --filter "name=aztec-sequencer" --format "{{.Names}}" | grep -q aztec-sequencer; then
    print_info "查看节点日志 (Ctrl+C 退出)..."
    docker logs -f --tail 100 aztec-sequencer
  else
    print_error "节点未运行"
  fi
}

check_node_status() {
  print_info "节点状态检查..."
  if docker ps --filter "name=aztec-sequencer" --format "{{.Names}}" | grep -q aztec-sequencer; then
    print_success "节点状态: 运行中"
    
    # 检查端口
    if netstat -tuln | grep -q :8080; then
      print_success "API 端口 (8080): 正常"
    else
      print_error "API 端口 (8080): 异常"
    fi
    
    # 显示区块高度
    local block_height
    block_height=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
      http://localhost:8080 2>/dev/null | jq -r ".result.proven.number" || echo "未知")
    print_info "当前区块: $block_height"
    
    # 显示最近日志
    print_info "最近日志:"
    docker logs --tail 5 aztec-sequencer 2>/dev/null | tail -5
  else
    print_error "节点状态: 未运行"
  fi
}

check_queue_status() {
  if [ -f "$KEYSTORE_FILE" ]; then
    local new_address
    new_address=$(jq -r '.eth' "$KEYSTORE_FILE" 2>/dev/null | xargs cast wallet address --private-key 2>/dev/null)
    if [ -n "$new_address" ]; then
      print_info "新验证者地址: $new_address"
      print_info "排队查询: $DASHTEC_URL/validator/$new_address"
    else
      print_error "无法获取验证者地址"
    fi
  else
    print_error "未找到密钥文件"
  fi
}

update_node() {
  print_info "更新节点..."
  cd "$AZTEC_DIR" 2>/dev/null && {
    docker-compose down 2>/dev/null || docker compose down 2>/dev/null
    docker pull "$AZTEC_IMAGE"
    docker-compose up -d 2>/dev/null || docker compose up -d
    print_success "节点更新完成"
  } || print_error "节点目录不存在"
}

delete_node_data() {
  read -p "确认删除所有节点数据？(y/N): " confirm
  if [[ $confirm == [yY] ]]; then
    print_info "删除节点数据..."
    cd "$AZTEC_DIR" 2>/dev/null && {
      docker-compose down 2>/dev/null || docker compose down 2>/dev/null
    }
    rm -rf "$AZTEC_DIR" 2>/dev/null || true
    print_success "节点数据已删除"
  else
    print_info "取消删除"
  fi
}

main_menu() {
  while true; do
    clear
    echo -e "\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m      Aztec 2.1.2 测试网节点管理脚本\033[0m"
    echo -e "\033[1;36m             (安全优化版)\033[0m"
    echo -e "\033[1;36m========================================\033[0m"
    echo "1. 安装并启动节点 (自动注册)"
    echo "2. 查看节点日志"
    echo "3. 查看节点状态"
    echo "4. 检查排队状态"
    echo "5. 更新节点"
    echo "6. 删除节点数据"
    echo "7. 退出"
    echo -e "\033[1;36m========================================\033[0m"
    read -p "请选择 (1-7): " choice
    case $choice in
      1) install_and_start_node ;;
      2) view_node_logs ;;
      3) check_node_status; read -n 1 -s -r -p "按任意键继续..." ;;
      4) check_queue_status; read -n 1 -s -r -p "按任意键继续..." ;;
      5) update_node; read -n 1 -s -r -p "按任意键继续..." ;;
      6) delete_node_data; read -n 1 -s -r -p "按任意键继续..." ;;
      7) secure_cleanup; exit 0 ;;
      *) print_error "无效选项"; read -n 1 -s -r -p "按任意键继续..." ;;
    esac
  done
}

# 主程序
main_menu
