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
install_foundry_silent() {
  print_info "静默安装 Foundry..."
  
  # 方法1: 使用预编译的二进制文件
  local foundry_url="https://raw.githubusercontent.com/foundry-rs/foundry/master/foundryup/install"
  
  # 创建安装目录
  mkdir -p "$HOME/.foundry/bin"
  
  # 下载并安装 foundryup
  curl -L https://raw.githubusercontent.com/foundry-rs/foundry/master/foundryup/install -o /tmp/install-foundryup.sh
  chmod +x /tmp/install-foundryup.sh
  
  # 非交互式安装
  EXPECTED_FOUNDRYUP_VERSION="1.0.0" /tmp/install-foundryup.sh > /dev/null 2>&1
  
  # 添加到 PATH
  echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
  export PATH="$HOME/.foundry/bin:$PATH"
  
  # 安装 foundry
  if [ -f "$HOME/.foundry/bin/foundryup" ]; then
    "$HOME/.foundry/bin/foundryup" --no-modify-path > /dev/null 2>&1
  fi
  
  # 验证安装
  if command -v cast >/dev/null 2>&1; then
    print_success "Foundry 安装成功"
    return 0
  else
    print_warning "Foundry 自动安装失败，尝试手动安装..."
    return 1
  fi
}

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
    if ! install_foundry_silent; then
      print_error "Foundry 自动安装失败，请手动运行以下命令："
      echo "  curl -L https://foundry.paradigm.xyz | bash"
      echo "  source ~/.bashrc"  
      echo "  foundryup"
      echo ""
      read -p "按 [Enter] 继续手动安装过程，或 Ctrl+C 退出..."
      
      # 给用户时间手动安装
      print_info "请在新终端中手动安装 Foundry，然后返回此脚本继续..."
      read -p "Foundry 安装完成后按 [Enter] 继续..."
    fi
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
    print_info "请手动运行以下命令安装："
    echo "  # 安装 Docker"
    echo "  curl -fsSL https://get.docker.com | sh"
    echo "  # 安装 Foundry"  
    echo "  curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup"
    echo "  # 安装 Aztec CLI"
    echo "  curl -sL https://install.aztec.network | bash"
    echo ""
    read -p "手动安装完成后按 [Enter] 继续..."
  fi
  
  # 最终检查
  if command -v cast >/dev/null 2>&1 && command -v aztec >/dev/null 2>&1; then
    print_success "所有依赖安装完成"
    return 0
  else
    print_error "依赖安装不完整，请手动安装上述工具"
    return 1
  fi
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
      print_error "依赖安装失败"
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

# ==================== 主安装流程 ====================
install_and_start_node() {
  clear
  print_info "Aztec 2.1.2 测试网节点安装 (安全优化版)"
  echo "=========================================="
  print_warning "重要提示：请先确保已安装必要依赖"
  print_info "如果依赖安装失败，请手动运行："
  echo "  curl -L https://foundry.paradigm.xyz | bash"
  echo "  source ~/.bashrc && foundryup"
  echo "  curl -sL https://install.aztec.network | bash"
  echo "=========================================="

  # 环境检查
  if ! validate_environment; then
    print_error "环境检查失败，请先安装必要依赖"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 获取用户输入
  read -p "L1 执行 RPC URL (Sepolia): " ETH_RPC
  read -p "L1 共识 Beacon RPC URL: " CONS_RPC
  read -sp "旧验证者私钥 (有 200k STAKE): " OLD_PRIVATE_KEY && echo

  # 输入验证
  if [[ ! "$OLD_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    print_error "私钥格式错误"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 显示旧地址
  local old_address
  old_address=$(cast wallet address --private-key "$OLD_PRIVATE_KEY" 2>/dev/null)
  print_info "旧验证者地址: $old_address"

  # 生成新密钥
  print_info "生成新的验证者密钥..."
  rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
  
  if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1; then
    print_error "BLS 密钥生成失败"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  if [ ! -f "$KEYSTORE_FILE" ]; then
    print_error "密钥文件未生成"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 读取密钥
  local new_eth_key new_bls_key new_address
  new_eth_key=$(jq -r '.eth' "$KEYSTORE_FILE" 2>/dev/null)
  new_bls_key=$(jq -r '.bls' "$KEYSTORE_FILE" 2>/dev/null)
  new_address=$(cast wallet address --private-key "$new_eth_key" 2>/dev/null)

  if [[ -z "$new_eth_key" || -z "$new_bls_key" || ! "$new_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "密钥信息读取失败"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  print_success "新验证者地址: $new_address"

  # 显示密钥信息
  print_warning "请立即保存以下密钥信息！"
  echo "=========================================="
  echo "新的以太坊私钥: $new_eth_key"
  echo "新的 BLS 私钥: $new_bls_key"  
  echo "新的公钥地址: $new_address"
  echo "=========================================="
  read -p "确认已保存密钥信息后按 [Enter] 继续..."

  # STAKE 授权
  print_info "执行 STAKE 授权..."
  if ! cast send "$STAKE_TOKEN" "approve(address,uint256)" \
    "$ROLLUP_CONTRACT" "200000ether" \
    --private-key "$OLD_PRIVATE_KEY" --rpc-url "$ETH_RPC" >/dev/null 2>&1; then
    print_error "STAKE 授权失败"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi
  print_success "STAKE 授权成功"

  # 资金提示
  print_warning "请向新地址转入 0.2-0.5 Sepolia ETH:"
  echo "   $new_address"
  print_info "转账命令:"
  echo "   cast send $new_address --value 0.3ether --private-key $OLD_PRIVATE_KEY --rpc-url $ETH_RPC"
  read -p "转账完成后按 [Enter] 继续..."

  # 注册验证者
  print_info "注册验证者..."
  if ! aztec add-l1-validator \
    --l1-rpc-urls "$ETH_RPC" \
    --network testnet \
    --private-key "$OLD_PRIVATE_KEY" \
    --attester "$new_address" \
    --withdrawer "$new_address" \
    --bls-secret-key "$new_bls_key" \
    --rollup "$ROLLUP_CONTRACT" >/dev/null 2>&1; then
    print_error "验证者注册失败"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi
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

  # 安全清理
  secure_cleanup

  print_success "Aztec 2.1.2 节点部署完成！"
  echo
  print_info "新验证者地址: $new_address"
  print_info "排队查询: $DASHTEC_URL/validator/$new_address"
  print_info "查看日志: docker logs -f aztec-sequencer"
  
  read -n 1 -s -r -p "按任意键继续..."
}

# ==================== 简化菜单 ====================
main_menu() {
  while true; do
    clear
    echo -e "\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m      Aztec 2.1.2 测试网节点安装\033[0m"
    echo -e "\033[1;36m========================================\033[0m"
    echo "1. 安装节点 (自动注册)"
    echo "2. 查看节点日志" 
    echo "3. 检查节点状态"
    echo "4. 退出"
    echo -e "\033[1;36m========================================\033[0m"
    read -p "请选择 (1-4): " choice
    case $choice in
      1) install_and_start_node ;;
      2) docker logs -f aztec-sequencer 2>/dev/null || echo "节点未运行" ;;
      3) 
        if docker ps | grep -q aztec-sequencer; then
          echo "节点状态: 运行中"
          echo "最近日志:"
          docker logs --tail 5 aztec-sequencer 2>/dev/null | tail -5
        else
          echo "节点状态: 未运行"
        fi
        read -n 1 -s -r -p "按任意键继续..."
        ;;
      4) exit 0 ;;
      *) echo "无效选项"; read -n 1 -s -r -p "按任意键继续..." ;;
    esac
  done
}

# 主程序
main_menu
