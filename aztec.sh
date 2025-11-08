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

# ==================== 主安装流程 ====================
install_and_start_node() {
  clear
  print_info "Aztec 2.1.2 测试网节点安装"
  echo "=========================================="
  
  # 环境检查
  if ! check_environment; then
    echo "请先安装依赖："
    echo "curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup"
    echo "curl -sL https://install.aztec.network | bash && source ~/.bashrc"
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
    print_error "私钥格式错误"
    return 1
  fi

  # 显示旧地址
  local old_address
  old_address=$(cast wallet address --private-key "$OLD_PRIVATE_KEY")
  print_info "旧验证者地址: $old_address"

  # 生成新密钥
  print_info "生成新的验证者密钥..."
  rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
  
  aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000

  if [ ! -f "$KEYSTORE_FILE" ]; then
    print_error "密钥文件未生成"
    return 1
  fi

  # 读取密钥
  local new_eth_key new_bls_key new_address
  new_eth_key=$(jq -r '.eth' "$KEYSTORE_FILE")
  new_bls_key=$(jq -r '.bls' "$KEYSTORE_FILE")
  new_address=$(cast wallet address --private-key "$new_eth_key")

  print_success "新验证者地址: $new_address"

  # 显示密钥信息
  echo ""
  print_warning "=== 请立即保存以下密钥信息！ ==="
  echo "=========================================="
  echo "🔑 新的以太坊私钥: $new_eth_key"
  echo "🔐 新的 BLS 私钥: $new_bls_key"  
  echo "📍 新的公钥地址: $new_address"
  echo "=========================================="
  read -p "确认已保存所有密钥信息后按 [Enter] 继续..."

  # STAKE 授权
  print_info "执行 STAKE 授权..."
  cast send "$STAKE_TOKEN" "approve(address,uint256)" \
    "$ROLLUP_CONTRACT" "200000ether" \
    --private-key "$OLD_PRIVATE_KEY" --rpc-url "$ETH_RPC"
  print_success "STAKE 授权成功"

  # 资金提示
  echo ""
  print_warning "请向新地址转入 0.2-0.5 Sepolia ETH: $new_address"
  read -p "转账完成后按 [Enter] 继续..."

  # 注册验证者
  print_info "注册验证者..."
  aztec add-l1-validator \
    --l1-rpc-urls "$ETH_RPC" \
    --network testnet \
    --private-key "$OLD_PRIVATE_KEY" \
    --attester "$new_address" \
    --withdrawer "$new_address" \
    --bls-secret-key "$new_bls_key" \
    --rollup "$ROLLUP_CONTRACT"
  print_success "验证者注册成功"

  # 设置节点环境
  print_info "设置节点环境..."
  mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"
  cp "$KEYSTORE_FILE" "$KEY_DIR/keystore.json"
  
  local public_ip
  public_ip=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

  # 生成配置文件
  cat > "$AZTEC_DIR/.env" <<EOF
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

  # 启动节点
  print_info "启动节点..."
  cd "$AZTEC_DIR"
  docker compose up -d

  print_success "🎉 Aztec 2.1.2 节点部署完成！"
  echo ""
  echo "新验证者地址: $new_address"
  echo "排队查询: $DASHTEC_URL/validator/$new_address"
  echo "查看日志: docker logs -f aztec-sequencer"
}

# ==================== 菜单 ====================
main_menu() {
  while true; do
    clear
    echo "========================================"
    echo "     Aztec 2.1.2 测试网节点安装"
    echo "========================================"
    echo "1. 安装节点 (自动注册)"
    echo "2. 查看节点日志" 
    echo "3. 检查节点状态"
    echo "4. 退出"
    echo "========================================"
    read -p "请选择 (1-4): " choice
    case $choice in
      1) install_and_start_node ;;
      2) docker logs -f aztec-sequencer ;;
      3) 
        if docker ps | grep -q aztec-sequencer; then
          echo "节点状态: 运行中"
          docker logs --tail 5 aztec-sequencer
        else
          echo "节点状态: 未运行"
        fi
        ;;
      4) exit 0 ;;
      *) echo "无效选项" ;;
    esac
    read -p "按任意键继续..."
  done
}

# 主程序
main_menu
