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

# ==================== 更新并重启节点 ====================
update_and_restart_node() {
  if [ ! -d "$AZTEC_DIR" ]; then
    print_error "节点目录不存在，请先安装节点！"
    read -p "按 [Enter] 继续..."
    return 1
  fi

  print_info "检查并拉取最新 Aztec 镜像..."
  cd "$AZTEC_DIR"
  local old_image=$(docker inspect aztec-sequencer --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  print_info "当前镜像: $old_image"

  docker compose pull aztec-sequencer
  print_success "镜像拉取完成！"

  print_warning "重启节点（可能有短暂中断）..."
  docker compose up -d
  sleep 10  # 等待重启

  local new_image=$(docker inspect aztec-sequencer --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  if [[ "$old_image" != "$new_image" ]]; then
    print_success "更新成功！新镜像: $new_image"
  else
    print_info "无新版本可用。"
  fi

  print_info "重启后日志（最近20行）："
  docker logs aztec-sequencer --tail 20

  echo ""
  print_success "更新和重启完成！"
  read -p "按 [Enter] 继续..."
}

# ==================== 查看日志和状态 ====================
view_logs_and_status() {
  if docker ps | grep -q aztec-sequencer; then
    echo "节点运行中"
    docker logs --tail 100 aztec-sequencer
    echo ""
    local api_status=$(curl -s http://localhost:8080/status 2>/dev/null || echo "")
    if [[ -n "$api_status" && $(echo "$api_status" | jq -e '.error == null' 2>/dev/null) == "true" ]]; then
      echo "$api_status"
      print_success "API 响应正常！"
    else
      echo "$api_status"
      print_error "API 响应异常或无响应！"
    fi

    # 更精确的日志错误检测：针对Aztec常见问题，如连接失败、同步错误、P2P问题
    # 排除正常日志（如"no blocks"、"too far into slot"、"rate limit"）
    local error_logs=$(docker logs --tail 100 aztec-sequencer 2>/dev/null | grep -E "(ERROR|WARN|FATAL|failed to|connection refused|timeout|sync failed|RPC error|P2P error|disconnected.*failed)" | grep -v -E "(no blocks|too far into slot|rate limit exceeded|yamux error)")
    local error_count=$(echo "$error_logs" | wc -l)
    if [[ "$error_count" -eq 0 ]]; then
      print_success "日志正常，无明显错误！（P2P活跃，同步稳定）"
    else
      print_warning "日志中发现 $error_count 条潜在问题 (如连接/同步失败)，详情："
      echo "$error_logs"
    fi

    echo ""
    print_info "是否查看实时日志？(y/N): "
    read -r realtime_choice
    if [[ "$realtime_choice" == "y" || "$realtime_choice" == "Y" ]]; then
      print_info "实时日志（按 Ctrl+C 停止）..."
      docker logs -f aztec-sequencer
    fi
  else
    print_error "节点未运行！"
  fi
  read -p "按 [Enter] 继续..."
}

# ==================== 性能监控 ====================
monitor_performance() {
  if [ ! -d "$AZTEC_DIR" ]; then
    print_error "节点目录不存在，请先安装节点！"
    read -p "按 [Enter] 继续..."
    return 1
  fi

  print_info "=== 系统性能监控 ==="
  echo "VPS 整体资源："
  free -h | grep -E "^Mem:" | awk '{printf "内存: 总 %s | 已用 %s | 可用 %s (%.1f%% 已用)\n", $2, $3, $7, ($3/$2)*100}'
  echo "CPU 使用率: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | awk '{printf "%.1f%%\n", $1}')"
  echo "磁盘使用: $(df -h / | awk 'NR==2 {printf "%.1f%% 已用 (%s 可用)", $5, $4}')"
  echo "网络 I/O (最近1min): $(cat /proc/net/dev | grep eth0 | awk '{print "接收: " $2/1024/1024 "MB, 发送: " $10/1024/1024 "MB"}' 2>/dev/null || echo "网络接口未找到")"

  if docker ps | grep -q aztec-sequencer; then
    print_info "=== Aztec 容器性能 ==="
    docker stats aztec-sequencer --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" | tail -n1
    print_info "Aztec API 响应时间 (ms): $(curl -s -w "%{time_total}" -o /dev/null http://localhost:8080/status 2>/dev/null || echo "N/A")"
    local peers=$(curl -s http://localhost:8080/status 2>/dev/null | jq -r '.peers // empty' || echo "N/A")
    echo "P2P 连接数: $peers"
  else
    print_warning "Aztec 容器未运行，无法监控容器指标。"
  fi

  echo ""
  print_info "监控刷新间隔 (s): "
  read -r interval
  interval=${interval:-5}
  print_warning "实时监控（按 Ctrl+C 停止）... (每 $interval s 更新)"
  while true; do
    clear
    monitor_performance  # 递归调用以刷新（但避免无限循环，实际用 watch 或循环）
    sleep "$interval"
  done
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
    echo "2. 查看日志和状态"
    echo "3. 更新并重启节点"
    echo "4. 性能监控"
    echo "5. 退出"
    read -p "选择: " choice
    case $choice in
      1) install_and_start_node ;;
      2) view_logs_and_status ;;
      3) update_and_restart_node ;;
      4) monitor_performance ;;
      5) exit 0 ;;
      *) echo "无效"; read -p "继续...";;
    esac
  done
}

main_menu
