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
AZTEC_IMAGE="aztecprotocol/aztec:latest"
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
DASHTEC_URL="https://dashtec.xyz"

# ==================== 安全配置 ====================
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

# ==================== 打印函数 ====================
print_info()    { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ==================== 环境检查 ====================
check_environment() {
  print_info "检查环境..."
  export PATH="$HOME/.foundry/bin:$PATH"
  export PATH="$HOME/.aztec/bin:$PATH"
  local missing=()
  for cmd in docker jq cast aztec; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    print_error "缺少命令: ${missing[*]}"
    return 1
  fi
  print_success "环境检查通过"
  return 0
}

# ==================== 从私钥生成地址 ====================
generate_address_from_private_key() {
  local private_key=$1
  local address
  address=$(cast wallet address --private-key "$private_key" 2>/dev/null || echo "")
  if [[ -z "$address" || ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    local stripped_key="${private_key#0x}"
    if [[ ${#stripped_key} -eq 64 ]]; then
      address=$(echo -n "$stripped_key" | xxd -r -p | openssl dgst -sha3-256 -binary | xxd -p -c 40 | sed 's/^/0x/' || echo "")
    fi
  fi
  echo "$address"
}

# ==================== 加载现有 keystore ====================
load_existing_keystore() {
  local keystore_path=$1
  if [ ! -f "$keystore_path" ]; then
    print_error "keystore 文件不存在: $keystore_path"
    return 1
  fi

  local new_eth_key new_bls_key new_address
  new_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path")
  new_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path")

  if [[ -z "$new_eth_key" || "$new_eth_key" == "null" ]]; then
    print_error "ETH 私钥读取失败"
    return 1
  fi
  if [[ -z "$new_bls_key" || "$new_bls_key" == "null" ]]; then
    print_error "BLS 私钥读取失败"
    return 1
  fi

  new_address=$(generate_address_from_private_key "$new_eth_key")
  if [[ -z "$new_address" || ! "$new_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "地址生成失败"
    return 1
  fi

  print_success "加载成功！地址: $new_address"
  echo "ETH 私钥: $new_eth_key"
  echo "BLS 私钥: $new_bls_key"
  echo "请立即备份这些密钥！"
  read -p "确认已保存后按 [Enter] 继续..."

  # 验证地址匹配用户预期
  read -p "输入预期地址确认 (e.g., 0x345...): " expected_address
  if [[ "$new_address" != "$expected_address" ]]; then
    print_warning "地址不匹配！预期: $expected_address, 实际: $new_address"
    read -p "是否继续? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 1
  fi

  # 设置全局变量
  export LOADED_ETH_KEY="$new_eth_key"
  export LOADED_BLS_KEY="$new_bls_key"
  export LOADED_ADDRESS="$new_address"
  export LOADED_KEYSTORE="$keystore_path"
  return 0
}

# ==================== 检查 STAKE 授权 ====================
check_and_approve_stake() {
  local eth_rpc=$1
  local old_private_key=$2
  local old_address=$3
  local stake_amount=200000000000000000000000000

  print_info "检查 STAKE 授权..."
  local allowance
  allowance=$(cast call "$STAKE_TOKEN" "allowance(address,address)(uint256)" "$old_address" "$ROLLUP_CONTRACT" --rpc-url "$eth_rpc" 2>/dev/null || echo "0")
  if [[ "$allowance" -ge "$stake_amount" ]]; then
    print_success "STAKE 已授权"
    return 0
  fi

  print_warning "执行授权..."
  if ! cast send "$STAKE_TOKEN" "approve(address,uint256)" \
    "$ROLLUP_CONTRACT" "$stake_amount" \
    --private-key "$old_private_key" --rpc-url "$eth_rpc"; then
    print_error "授权失败"
    return 1
  fi
  print_success "授权成功"
  return 0
}

# ==================== 检查 ETH 余额 ====================
check_eth_balance() {
  local eth_rpc=$1
  local address=$2
  local min_eth=0.2

  local balance_eth
  balance_eth=$(cast balance "$address" --rpc-url "$eth_rpc" | sed 's/.* \([0-9.]*\) eth.*/\1/' || echo "0")
  if [[ $(echo "$balance_eth >= $min_eth" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
    print_success "ETH 充足 ($balance_eth ETH)"
    return 0
  else
    print_warning "ETH 不足 ($balance_eth ETH)"
    return 1
  fi
}

# ==================== 检查 RPC 连通性 ====================
check_rpc_connectivity() {
  local eth_rpc=$1
  local cons_rpc=$2

  print_info "检查执行层 RPC ($eth_rpc)..."
  if cast block-number --rpc-url "$eth_rpc" >/dev/null 2>&1; then
    local eth_block=$(cast block-number --rpc-url "$eth_rpc")
    print_success "执行层 RPC 正常 (最新块: $eth_block)"
  else
    print_error "执行层 RPC 不可达"
    return 1
  fi

  print_info "检查 Beacon Chain RPC ($cons_rpc)..."
  if cast block-number --rpc-url "$cons_rpc" >/dev/null 2>&1; then
    local cons_block=$(cast block-number --rpc-url "$cons_rpc")
    print_success "Beacon Chain RPC 正常 (最新块: $cons_block)"
  else
    print_error "Beacon Chain RPC 不可达"
    return 1
  fi
  return 0
}

# ==================== 检查系统资源 ====================
check_system_resources() {
  print_info "检查 VPS 内存使用..."
  free -h | grep -E "^Mem:" | awk '{printf "总内存: %s 已用: %s (%.1f%%)\n", $2, $3, ($3/$2)*100}'

  print_info "检查 VPS CPU 使用..."
  local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | awk '{printf "%.1f%%\n", $1}')
  print_success "CPU 使用率: $cpu_usage"

  local cpu_cores=$(nproc)
  print_info "CPU 核心数: $cpu_cores"

  if [[ $(echo "$cpu_usage > 80" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
    print_warning "CPU 使用率较高 (>80%)，建议监控"
  fi

  if ! command -v bc >/dev/null 2>&1; then
    print_warning "未安装 bc 工具，无法精确计算百分比"
  fi
}

# ==================== 检查 RPC 和系统资源 ====================
check_rpc_and_resources() {
  echo "请输入 RPC 信息（如果已安装节点，可使用相同值）："
  read -p "L1 执行 RPC URL: " ETH_RPC_CHECK
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC_CHECK

  if ! check_rpc_connectivity "$ETH_RPC_CHECK" "$CONS_RPC_CHECK"; then
    print_error "RPC 检查失败"
    return 1
  fi

  echo ""
  check_system_resources

  read -p "按 [Enter] 继续..."
}

# ==================== 主安装流程 ====================
install_and_start_node() {
  clear
  print_info "Aztec 测试网节点安装 (简化版)"
  echo "=========================================="

  if ! check_environment; then
    return 1
  fi

  echo ""
  echo "请输入基础信息："
  read -p "L1 执行 RPC URL: " ETH_RPC
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC
  read -p "旧验证者私钥 (用于授权，如果需要): " OLD_PRIVATE_KEY
  echo ""

  if [[ -n "$OLD_PRIVATE_KEY" && ! "$OLD_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    print_error "私钥格式错误"
    return 1
  fi

  local old_address
  if [[ -n "$OLD_PRIVATE_KEY" ]]; then
    old_address=$(generate_address_from_private_key "$OLD_PRIVATE_KEY")
    print_info "旧地址: $old_address"
  fi

  # 选择模式（简化：无选项2）
  echo ""
  print_info "选择模式："
  echo "1. 生成新地址 (自动注册)"
  echo "2. 加载现有 keystore.json (推荐，用于已注册地址)"
  read -p "请选择 (1-2): " mode_choice
  local new_eth_key new_bls_key new_address is_new=false

  case $mode_choice in
    1)
      # 选项1: 生成新
      print_info "生成新密钥..."
      rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
      aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000
      new_eth_key=$(jq -r '.validators[0].attester.eth' "$DEFAULT_KEYSTORE")
      new_bls_key=$(jq -r '.validators[0].attester.bls' "$DEFAULT_KEYSTORE")
      new_address=$(generate_address_from_private_key "$new_eth_key")
      is_new=true
      print_success "新地址: $new_address"
      # 密钥打印
      echo ""
      print_warning "=== 保存密钥！ ==="
      echo "ETH 私钥: $new_eth_key"
      echo "BLS 私钥: $new_bls_key"
      echo "地址: $new_address"
      read -p "确认保存后继续..."

      # 授权、转账、注册
      if ! check_and_approve_stake "$ETH_RPC" "$OLD_PRIVATE_KEY" "$old_address"; then return 1; fi
      if ! check_eth_balance "$ETH_RPC" "$new_address"; then
        print_warning "转 ETH 到 $new_address (0.3 ETH)"
        read -p "确认后继续..."
      fi
      print_info "注册新验证者..."
      aztec add-l1-validator --l1-rpc-urls "$ETH_RPC" --network testnet --private-key "$OLD_PRIVATE_KEY" --attester "$new_address" --withdrawer "$new_address" --bls-secret-key "$new_bls_key" --rollup "$ROLLUP_CONTRACT"
      print_success "注册成功"
      ;;
    2)
      # 选项2: 加载现有 (原3)
      echo "输入 keystore.json 路径 (默认 $DEFAULT_KEYSTORE): "
      read -p "路径: " keystore_path
      keystore_path=${keystore_path:-$DEFAULT_KEYSTORE}
      if ! load_existing_keystore "$keystore_path"; then return 1; fi
      new_eth_key="$LOADED_ETH_KEY"
      new_bls_key="$LOADED_BLS_KEY"
      new_address="$LOADED_ADDRESS"
      cp "$LOADED_KEYSTORE" "$KEY_DIR/keystore.json"
      # 跳过授权/转账/注册
      if [[ -n "$OLD_PRIVATE_KEY" ]]; then
        check_and_approve_stake "$ETH_RPC" "$OLD_PRIVATE_KEY" "$old_address" || true
      fi
      if ! check_eth_balance "$ETH_RPC" "$new_address"; then
        print_warning "ETH 不足？转到 $new_address"
        read -p "确认后继续..."
      fi
      print_info "检查队列: $DASHTEC_URL/validator/$new_address"
      read -p "确认在队列后继续..."
      print_success "跳过注册 (已完成)"
      ;;
    *)
      print_error "无效选择"
      return 1
      ;;
  esac

  # 统一设置环境
  print_info "设置节点环境..."
  mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"
  local public_ip=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

  cat > "$AZTEC_DIR/.env" <<EOF
DATA_DIRECTORY=./data
KEY_STORE_DIRECTORY=./keys
LOG_LEVEL=debug
ETHEREUM_HOSTS=${ETH_RPC}
L1_CONSENSUS_HOST_URLS=${CONS_RPC}
P2P_IP=${public_ip}
P2P_PORT=40400
AZTEC_PORT=8080
AZTEC_ADMIN_PORT=8880
VALIDATOR_PRIVATE_KEY=${new_eth_key}
COINBASE=${new_address}
EOF

  cat > "$AZTEC_DIR/docker-compose.yml" <<'EOF'
services:
  aztec-sequencer:
    image: "aztecprotocol/aztec:latest"
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
      VALIDATOR_PRIVATE_KEY: ${VALIDATOR_PRIVATE_KEY}
      COINBASE: ${COINBASE}
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

  # 启动
  print_info "启动节点..."
  cd "$AZTEC_DIR"
  docker compose up -d
  sleep 5
  docker logs aztec-sequencer --tail 20

  echo ""
  print_success "部署完成！"
  echo "地址: $new_address"
  echo "队列: $DASHTEC_URL/validator/$new_address"
  echo "日志: docker logs -f aztec-sequencer"
  echo "状态: curl http://localhost:8080/status"
  read -p "按任意键继续..."
}

# ==================== 菜单 ====================
main_menu() {
  while true; do
    clear
    echo "========================================"
    echo "     Aztec 节点安装 (简化版)"
    echo "========================================"
    echo "1. 安装/启动节点 (带选择)"
    echo "2. 查看日志"
    echo "3. 检查状态"
    echo "4. 检查 RPC 和系统资源"
    echo "5. 退出"
    read -p "选择: " choice
    case $choice in
      1) install_and_start_node ;;
      2) docker logs -f aztec-sequencer 2>/dev/null || echo "未运行"; read -p "继续...";;
      3)
        if docker ps | grep -q aztec-sequencer; then
          echo "运行中"
          docker logs --tail 10 aztec-sequencer
          echo ""
          curl -s http://localhost:8080/status || echo "API 未响应"
        else
          echo "未运行"
        fi
        read -p "继续...";;
      4) check_rpc_and_resources ;;
      5) exit 0 ;;
      *) echo "无效"; read -p "继续...";;
    esac
  done
}

main_menu
