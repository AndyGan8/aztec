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
AZTEC_IMAGE="aztecprotocol/aztec:latest"  # 更新到 latest 以兼容当前版本
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
DASHTEC_URL="https://dashtec.xyz"

# ==================== 安全配置 ====================
KEYSTORE_FILE="$HOME/.aztec/keystore/key1.json"

# ==================== 打印函数 ====================
print_info()    { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ==================== 环境检查 ====================
check_environment() {
  print_info "检查环境..."
  # 确保 PATH 正确
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
  # 使用更安全的方式生成地址
  local address
  address=$(cast wallet address --private-key "$private_key" 2>/dev/null || echo "")
  if [[ -z "$address" || ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    # 如果 cast 失败，尝试手动计算
    local stripped_key="${private_key#0x}"
    if [[ ${#stripped_key} -eq 64 ]]; then
      # 使用 openssl 生成地址 (简化版，实际需 keccak)
      address=$(echo -n "$stripped_key" | xxd -r -p | openssl dgst -sha3-256 -binary | xxd -p -c 40 | sed 's/^/0x/' || echo "")
    fi
  fi
  echo "$address"
}

# ==================== 检查 STAKE 授权 ====================
check_and_approve_stake() {
  local eth_rpc=$1
  local old_private_key=$2
  local old_address=$3
  local stake_amount=200000000000000000000000000  # 200k ether in wei

  print_info "检查 STAKE 授权..."
  local allowance
  allowance=$(cast call "$STAKE_TOKEN" "allowance(address,address)(uint256)" "$old_address" "$ROLLUP_CONTRACT" --rpc-url "$eth_rpc" 2>/dev/null || echo "0")
  if [[ "$allowance" -ge "$stake_amount" ]]; then
    print_success "STAKE 已授权 (当前: $((allowance / 1000000000000000000))k)"
    return 0
  fi

  print_warning "STAKE 未授权或不足，执行授权..."
  if ! cast send "$STAKE_TOKEN" "approve(address,uint256)" \
    "$ROLLUP_CONTRACT" "$stake_amount" \
    --private-key "$old_private_key" --rpc-url "$eth_rpc"; then
    print_error "STAKE 授权失败！请检查："
    echo "1. 私钥是否正确"
    echo "2. 地址是否有 200k STAKE"
    echo "3. RPC 是否可用"
    read -p "按任意键继续..."
    return 1
  fi
  print_success "STAKE 授权成功"
  return 0
}

# ==================== 检查 ETH 余额 ====================
check_eth_balance() {
  local eth_rpc=$1
  local address=$2
  local min_eth=0.2  # 最小 0.2 ETH

  local balance_wei
  balance_wei=$(cast call --rpc-url "$eth_rpc" "$address" "balanceOf(address)(uint256)" || echo "0")
  local balance_eth=$((balance_wei / 1000000000000000000))
  if [[ "$balance_eth" -ge "$min_eth" ]]; then
    print_success "ETH 余额充足 ($balance_eth ETH)"
    return 0
  else
    print_warning "ETH 余额不足 ($balance_eth ETH < $min_eth ETH)"
    return 1
  fi
}

# ==================== 主安装流程 ====================
install_and_start_node() {
  clear
  print_info "Aztec 测试网节点安装 (带地址选择版)"
  echo "=========================================="

  # 环境检查
  if ! check_environment; then
    echo "请先安装依赖"
    return 1
  fi

  # 获取用户输入
  echo ""
  echo "请输入以下信息："
  read -p "L1 执行 RPC URL (Sepolia): " ETH_RPC
  echo "您输入的 RPC: $ETH_RPC"
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC
  echo "您输入的 Beacon RPC: $CONS_RPC"
  read -p "旧验证者私钥 (有 200k STAKE): " OLD_PRIVATE_KEY
  echo "您输入的私钥: $OLD_PRIVATE_KEY"
  echo ""

  # 输入验证
  if [[ ! "$OLD_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    print_error "私钥格式错误，应该是 0x 开头的 64 位十六进制数"
    read -p "按任意键继续..."
    return 1
  fi

  # 显示旧地址
  local old_address
  old_address=$(generate_address_from_private_key "$OLD_PRIVATE_KEY")
  if [[ -z "$old_address" || ! "$old_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "私钥无效，无法生成地址"
    read -p "按任意键继续..."
    return 1
  fi
  print_info "旧验证者地址: $old_address"

  # 新功能：选择地址类型
  echo ""
  print_info "选择运行节点的验证者地址："
  echo "1. 生成新地址 (推荐新用户，自动注册)"
  echo "2. 复用旧地址 (需已注册，提供旧 BLS 私钥)"
  read -p "请选择 (1 或 2): " address_choice
  local new_eth_key new_bls_key new_address

  if [[ "$address_choice" == "1" ]]; then
    # 选项1: 生成新密钥
    print_info "生成新的验证者密钥..."
    rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
    if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000; then
      print_error "BLS 密钥生成失败"
      read -p "按任意键继续..."
      return 1
    fi
    if [ ! -f "$KEYSTORE_FILE" ]; then
      print_error "密钥文件未生成"
      read -p "按任意键继续..."
      return 1
    fi

    # 读取密钥
    new_eth_key=$(jq -r '.validators[0].attester.eth' "$KEYSTORE_FILE")
    new_bls_key=$(jq -r '.validators[0].attester.bls' "$KEYSTORE_FILE")

    # 添加错误检查
    if [[ -z "$new_eth_key" || "$new_eth_key" == "null" ]]; then
      print_error "ETH 私钥读取失败，检查 JSON 结构"
      cat "$KEYSTORE_FILE"  # 打印文件内容用于调试
      read -p "按任意键继续..."
      return 1
    fi
    if [[ -z "$new_bls_key" || "$new_bls_key" == "null" ]]; then
      print_error "BLS 私钥读取失败"
      read -p "按任意键继续..."
      return 1
    fi

    # 生成新地址
    new_address=$(generate_address_from_private_key "$new_eth_key")
    if [[ -z "$new_address" || ! "$new_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
      print_error "新地址生成失败"
      echo "ETH 私钥: $new_eth_key"
      read -p "按任意键继续..."
      return 1
    fi
    print_success "新验证者地址: $new_address"

    # 显示密钥信息
    echo ""
    print_warning "=== 请立即保存以下密钥信息！ ==="
    echo "=========================================="
    echo " 新的以太坊私钥: $new_eth_key"
    echo " 新的 BLS 私钥: $new_bls_key"
    echo " 新的公钥地址: $new_address"
    echo "=========================================="
    read -p "确认已保存所有密钥信息后按 [Enter] 继续..."

    # STAKE 授权 (用旧私钥)
    if ! check_and_approve_stake "$ETH_RPC" "$OLD_PRIVATE_KEY" "$old_address"; then
      return 1
    fi

    # 资金提示 (新地址)
    echo ""
    print_warning "=== 重要：请向新地址转入 Sepolia ETH ==="
    echo "转账地址: $new_address"
    echo "推荐金额: 0.2-0.5 ETH"
    echo ""
    print_info "可以使用以下命令转账："
    echo "cast send $new_address --value 0.3ether --private-key $OLD_PRIVATE_KEY --rpc-url $ETH_RPC"
    echo ""
    read -p "确认已完成转账后按 [Enter] 继续..."

    # 注册验证者
    print_info "注册新验证者到测试网..."
    if ! aztec add-l1-validator \
      --l1-rpc-urls "$ETH_RPC" \
      --network testnet \
      --private-key "$OLD_PRIVATE_KEY" \
      --attester "$new_address" \
      --withdrawer "$new_address" \
      --bls-secret-key "$new_bls_key" \
      --rollup "$ROLLUP_CONTRACT"; then
      print_error "验证者注册失败"
      read -p "按任意键继续..."
      return 1
    fi
    print_success "新验证者注册成功"

  elif [[ "$address_choice" == "2" ]]; then
    # 选项2: 复用旧地址
    echo "请输入旧 BLS 私钥 (从之前 keystore.json 获取): "
    read -p "旧 BLS 私钥: " OLD_BLS_KEY
    if [[ -z "$OLD_BLS_KEY" ]]; then
      print_error "BLS 私钥不能为空"
      read -p "按任意键继续..."
      return 1
    fi

    new_eth_key="$OLD_PRIVATE_KEY"  # 复用旧 ETH 私钥
    new_bls_key="$OLD_BLS_KEY"
    new_address="$old_address"
    print_success "使用现有验证者地址: $new_address"

    # 检查是否已注册 (简单提示，用 Dashtec 查询)
    echo ""
    print_info "请手动确认旧地址已注册: $DASHTEC_URL/validator/$new_address"
    read -p "确认已注册后按 [Enter] 继续..."

    # STAKE 授权 (用旧私钥/地址)
    if ! check_and_approve_stake "$ETH_RPC" "$OLD_PRIVATE_KEY" "$old_address"; then
      return 1
    fi

    # 资金检查 (旧地址)
    if ! check_eth_balance "$ETH_RPC" "$new_address"; then
      echo ""
      print_warning "=== ETH 余额不足，请向旧地址转入 Sepolia ETH ==="
      echo "转账地址: $new_address"
      echo "推荐金额: 0.2-0.5 ETH"
      echo ""
      print_info "可以使用以下命令转账："
      echo "cast send $new_address --value 0.3ether --private-key $OLD_PRIVATE_KEY --rpc-url $ETH_RPC"
      echo ""
      read -p "确认已完成转账后按 [Enter] 继续..."
    fi

    # 跳过注册
    print_success "复用旧验证者，跳过注册步骤"

    # 显示密钥信息 (提醒备份)
    echo ""
    print_warning "=== 请确认已保存旧密钥信息！ ==="
    echo "=========================================="
    echo " 以太坊私钥: $new_eth_key"
    echo " BLS 私钥: $new_bls_key"
    echo " 公钥地址: $new_address"
    echo "=========================================="
    read -p "确认后按 [Enter] 继续..."

  else
    print_error "无效选择，请选 1 或 2"
    read -p "按任意键继续..."
    return 1
  fi

  # 设置节点环境 (统一逻辑)
  print_info "设置节点环境..."
  mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"
  # 对于选项2，不复制新 keystore，但节点用 env 中的密钥运行
  if [[ "$address_choice" == "1" ]]; then
    cp "$KEYSTORE_FILE" "$KEY_DIR/keystore.json"
  fi
  local public_ip
  public_ip=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

  # 生成配置文件
  cat > "$AZTEC_DIR/.env" <<EOF
DATA_DIRECTORY=./data
KEY_STORE_DIRECTORY=./keys
LOG_LEVEL=debug  # 改为 debug 以获取更多日志
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

  # 启动节点
  print_info "启动节点..."
  cd "$AZTEC_DIR"
  if docker compose up -d; then
    print_success "节点启动成功"
    sleep 5  # 等待初始化
    print_info "检查初始日志..."
    docker logs aztec-sequencer --tail 20
  else
    print_error "节点启动失败"
    read -p "按任意键继续..."
    return 1
  fi

  # 完成信息
  echo ""
  print_success "Aztec 节点部署完成！"
  echo ""
  print_info "=== 重要信息汇总 ==="
  echo " 验证者地址: $new_address"
  echo " 排队查询: $DASHTEC_URL/validator/$new_address"
  echo " 查看日志: docker logs -f aztec-sequencer"
  echo " 查看状态: curl http://localhost:8080/status"
  echo " 数据目录: $AZTEC_DIR"
  echo ""
  print_warning "请确保已妥善保存所有密钥信息！如果仍卡住，检查 RPC 连通性和防火墙 (ufw allow 40400,8080)。"
  read -p "按任意键继续..."
}

# ==================== 菜单 ====================
main_menu() {
  while true; do
    clear
    echo "========================================"
    echo "     Aztec 测试网节点安装 (带地址选择版)"
    echo "========================================"
    echo "1. 安装节点 (带地址选择)"
    echo "2. 查看节点日志"
    echo "3. 检查节点状态"
    echo "4. 退出"
    echo "========================================"
    read -p "请选择 (1-4): " choice
    case $choice in
      1) install_and_start_node ;;
      2)
        echo "查看节点日志 (Ctrl+C 退出)..."
        docker logs -f aztec-sequencer 2>/dev/null || echo "节点未运行"
        read -p "按任意键继续..."
        ;;
      3)
        if docker ps | grep -q aztec-sequencer; then
          echo " 节点状态: 运行中"
          echo ""
          echo "最近日志:"
          docker logs --tail 10 aztec-sequencer 2>/dev/null | tail -10
        else
          echo " 节点状态: 未运行"
        fi
        read -p "按任意键继续..."
        ;;
      4) exit 0 ;;
      *)
        echo "无效选项"
        read -p "按任意键继续..."
        ;;
    esac
  done
}

# 主程序
main_menu
