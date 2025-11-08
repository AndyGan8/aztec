#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行"
  exit 1
fi

# ==================== 常量 ====================
AZTEC_DIR="/root/aztec"
DATA_DIR="/root/.aztec/testnet/data"
AZTEC_IMAGE="aztecprotocol/aztec:2.1.2"
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
DASHTEC_URL="https://dashtec.xyz"

# ==================== 打印函数 ====================
print_info()    { echo -e "\033[1;34m[INFO]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1" >&2; }
print_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1" >&2; }

# ==================== 工具函数 ====================
check_command() { command -v "$1" >/dev/null 2>&1; }
install_package() { apt-get install -y "$1" >/dev/null 2>&1 || { print_error "安装 $1 失败"; exit 1; }; }

# ==================== RPC 检查 ====================
check_rpc() {
  local url=$1 name=$2
  print_info "检查 $name RPC: $url"
  local result
  
  if [[ "$url" == *"8545"* ]] || [[ "$url" == *"8545"* ]] || [[ "$url" == *"eth"* ]]; then
    # 执行层 RPC 检查
    result=$(timeout 10 curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$url" 2>/dev/null | grep -o '"result":"0x[^"]*"' || echo "")
  else
    # 共识层 RPC 检查
    result=$(timeout 10 curl -s "$url/eth/v1/beacon/headers/head" 2>/dev/null | grep -o '"slot":"[0-9]*"' || echo "")
  fi
  
  if [[ -z "$result" ]]; then
    print_error "$name RPC 连接失败！"
    return 1
  fi
  print_success "$name RPC 正常 ($result)"
  return 0
}

# ==================== 依赖路径 ====================
export PATH="$HOME/.foundry/bin:$PATH"
export PATH="$HOME/.aztec/bin:$PATH"

# ==================== 授权 STAKE ====================
authorize_stake() {
  local pk=$1 rpc=$2
  print_info "授权 200k STAKE..."
  if ! cast send $STAKE_TOKEN "approve(address,uint256)" $ROLLUP_CONTRACT 200000ether \
    --private-key "$pk" --rpc-url "$rpc" >/dev/null 2>&1; then
    print_error "授权失败！检查私钥、RPC、STAKE 余额"
    return 1
  fi
  print_success "STAKE 授权成功！"
  return 0
}

# ==================== 生成密钥 ====================
generate_bls_keys() {
  print_info "生成新的 BLS 密钥对..."
  rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
  
  if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1; then
    print_error "BLS 密钥生成失败"
    return 1
  fi
  
  local file="$HOME/.aztec/keystore/key1.json"
  if [ ! -f "$file" ]; then
    print_error "密钥文件未生成"
    return 1
  fi
  
  if ! check_command jq; then
    install_package jq
  fi
  
  local eth=$(jq -r '.eth' "$file" | tr -d '[:space:]')
  local bls=$(jq -r '.bls' "$file" | tr -d '[:space:]')
  local addr=$(cast wallet address --private-key "$eth" 2>/dev/null || echo "")
  
  if [[ ! "$addr" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "地址生成失败！"
    return 1
  fi
  
  print_success "新验证者地址: $addr" >&2
  printf "%s %s %s" "$eth" "$bls" "$addr"
  return 0
}

# ==================== 注册验证者 ====================
register_validator() {
  local old_pk=$1 attester=$2 bls=$3 rpc=$4 withdraw=$5
  print_info "注册验证者到 L1..."
  if ! aztec add-l1-validator \
    --l1-rpc-urls "$rpc" \
    --network testnet \
    --private-key "$old_pk" \
    --attester "$attester" \
    --withdrawer "$withdraw" \
    --bls-secret-key "$bls" \
    --rollup $ROLLUP_CONTRACT >/dev/null 2>&1; then
    print_error "注册失败！请检查 RPC、网络、参数"
    return 1
  fi
  print_success "验证者注册成功！"
  return 0
}

# ==================== 安装节点 ====================
install_and_start_node() {
  clear
  print_info "Aztec 2.1.2 测试网节点安装 (v8 - 修复版)"
  echo "=========================================="
  print_warning "重要提示："
  print_info "1. 旧地址需有 200k STAKE"
  print_info "2. 新地址（自动生成）需 0.1-0.3 Sepolia ETH"
  print_info "3. 提款地址 = 推荐旧地址 = 解押资金到账地址"
  echo "=========================================="

  read -p "L1 执行 RPC URL (Sepolia): " ETH_RPC
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC
  read -p "旧验证者私钥 (有 200k STAKE): " OLD_PK
  read -p "提款地址 (推荐旧地址): " WITHDRAW

  # 修复：使用正确的验证方式
  if [[ ! "$OLD_PK" =~ ^0x[a-fA-F0-9]{64}$ ]]; then 
    print_error "私钥格式错误"
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi
  
  if [[ ! "$WITHDRAW" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "提款地址格式错误"
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi

  # RPC 检查
  if ! check_rpc "$ETH_RPC" "执行层"; then
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi
  
  if ! check_rpc "$CONS_RPC" "共识层"; then
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi

  # 清理旧配置和数据
  print_info "清理旧的配置和数据..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/docker-compose.yml" 2>/dev/null || true
  rm -rf /tmp/aztec-world-state-* 2>/dev/null || true
  rm -rf "$DATA_DIR" 2>/dev/null || true
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  OLD_ADDR=$(cast wallet address --private-key "$OLD_PK" 2>/dev/null || echo "未知")
  print_info "旧地址: $OLD_ADDR"

  if ! authorize_stake "$OLD_PK" "$ETH_RPC"; then
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi

  local keys_output
  if ! keys_output=$(generate_bls_keys); then
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi
  
  read eth_key bls_key new_addr <<< "$keys_output"
  
  print_warning "请转 0.2 Sepolia ETH 到新地址："
  echo "   cast send $new_addr --value 0.2ether --private-key $OLD_PK --rpc-url $ETH_RPC" >&2
  
  if ! register_validator "$OLD_PK" "$new_addr" "$bls_key" "$ETH_RPC" "$WITHDRAW"; then
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi

  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")

  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS=$ETH_RPC
L1_CONSENSUS_HOST_URLS=$CONS_RPC
P2P_IP=$PUBLIC_IP
VALIDATOR_PRIVATE_KEYS=$eth_key
COINBASE=$new_addr
DATA_DIRECTORY=/data
LOG_LEVEL=info
LOG_FORMAT=json
LMDB_MAX_READERS=32
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=0xDCd9DdeAbEF70108cE02576df1eB333c4244C666
EOF

  cat > "$AZTEC_DIR/docker-compose.yml" <<'EOF'
services:
  aztec-node:
    container_name: aztec-sequencer
    image: aztecprotocol/aztec:2.1.2
    restart: unless-stopped
    network_mode: host
    environment:
      ETHEREUM_HOSTS: ${ETHEREUM_HOSTS}
      L1_CONSENSUS_HOST_URLS: ${L1_CONSENSUS_HOST_URLS}
      DATA_DIRECTORY: ${DATA_DIRECTORY}
      VALIDATOR_PRIVATE_KEYS: ${VALIDATOR_PRIVATE_KEYS}
      COINBASE: ${COINBASE}
      P2P_IP: ${P2P_IP}
      LOG_LEVEL: ${LOG_LEVEL}
      LOG_FORMAT: ${LOG_FORMAT}
      LMDB_MAX_READERS: ${LMDB_MAX_READERS}
      GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS: ${GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS}
    mem_limit: 4G
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
    entrypoint: >
      sh -c 'node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network testnet --node --archiver --sequencer'
    ports:
      - 40400:40400/tcp
      - 40400:40400/udp
      - 8080:8080
    volumes:
      - /root/.aztec/testnet/data:/data
EOF

  cd "$AZTEC_DIR"
  if check_command docker-compose; then
    docker-compose up -d
  elif check_command docker && docker compose version >/dev/null 2>&1; then
    docker compose up -d
  else
    print_error "未找到 docker compose 命令"
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi

  print_success "Aztec 节点部署完成！"
  echo
  print_info "新验证者地址: $new_addr"
  print_info "提款地址: $WITHDRAW"
  print_info "排队查询: $DASHTEC_URL/validator/$new_addr"
  print_info "转 gas 命令:"
  echo "   cast send $new_addr --value 0.2ether --private-key $OLD_PK --rpc-url $ETH_RPC"
  print_warning "转账后查看日志: docker logs -f aztec-sequencer"
  
  read -n 1 -s -r -p "按任意键继续..."
}

# ==================== 菜单功能 ====================
view_node_status() {
  if docker ps -a --filter "name=aztec-sequencer" | grep -q aztec-sequencer; then
    print_success "节点状态: 运行中"
    print_info "最近日志:"
    docker logs --tail 5 aztec-sequencer 2>/dev/null || print_info "暂无日志"
  else
    print_error "节点状态: 未运行"
  fi
}

check_queue_status() {
  if [ -f "$AZTEC_DIR/.env" ]; then
    local coinbase=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d= -f2)
    if [ -n "$coinbase" ]; then
      print_info "新验证者地址: $coinbase"
      print_info "排队查询: $DASHTEC_URL/validator/$coinbase"
    else
      print_error "未找到验证者地址"
    fi
  else
    print_error "未找到节点配置"
  fi
}

show_validator_info() {
  if [ -f "$AZTEC_DIR/.env" ]; then
    print_info "=== 验证者信息 ==="
    grep -E "(COINBASE|VALIDATOR_PRIVATE_KEYS)" "$AZTEC_DIR/.env" | while read line; do
      if [[ "$line" == VALIDATOR_PRIVATE_KEYS* ]]; then
        local key=$(echo "$line" | cut -d= -f2)
        local addr=$(cast wallet address --private-key "$key" 2>/dev/null || echo "未知")
        echo "验证者地址: $addr"
      elif [[ "$line" == COINBASE* ]]; then
        local addr=$(echo "$line" | cut -d= -f2)
        echo "收益地址: $addr"
      fi
    done
  else
    print_error "未找到节点配置"
  fi
}

update_node() {
  print_info "更新节点..."
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true
  docker pull $AZTEC_IMAGE
  cd "$AZTEC_DIR" 2>/dev/null && {
    if check_command docker-compose; then
      docker-compose up -d
    else
      docker compose up -d
    fi
    print_success "更新完成"
  } || print_error "节点目录不存在"
}

delete_node_data() {
  read -p "确认删除？(y/N): " confirm
  if [[ $confirm == [yY] ]]; then
    print_info "删除节点数据..."
    docker stop aztec-sequencer 2>/dev/null || true
    docker rm aztec-sequencer 2>/dev/null || true
    rm -rf "$AZTEC_DIR" "$DATA_DIR" 2>/dev/null || true
    print_success "已删除"
  else
    print_info "取消删除"
  fi
}

main_menu() {
  while true; do
    clear
    echo -e "\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m      Aztec 2.1.2 测试网节点管理脚本\033[0m"
    echo -e "\033[1;36m             (v8 - 修复版)\033[0m"
    echo -e "\033[1;36m========================================\033[0m"
    echo "1. 安装并启动节点 (自动注册)"
    echo "2. 查看节点日志"
    echo "3. 查看节点状态"
    echo "4. 检查排队状态"
    echo "5. 显示验证者信息"
    echo "6. 更新节点"
    echo "7. 删除节点数据"
    echo "8. 退出"
    echo -e "\033[1;36m========================================\033[0m"
    read -p "请选择 (1-8): " choice
    case $choice in
      1) install_and_start_node ;;
      2) docker logs -f --tail 100 aztec-sequencer 2>/dev/null || print_error "节点未运行" ;;
      3) view_node_status; read -n 1 -s -r -p "按任意键继续..." ;;
      4) check_queue_status; read -n 1 -s -r -p "按任意键继续..." ;;
      5) show_validator_info; read -n 1 -s -r -p "按任意键继续..." ;;
      6) update_node; read -n 1 -s -r -p "按任意键继续..." ;;
      7) delete_node_data; read -n 1 -s -r -p "按任意键继续..." ;;
      8) exit 0 ;;
      *) print_error "无效选项"; read -n 1 -s -r -p "按任意键继续..." ;;
    esac
  done
}

main_menu
