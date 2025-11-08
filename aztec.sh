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

# ==================== 直接安装 Foundry ====================
install_foundry_direct() {
  print_info "直接安装 Foundry 二进制文件..."
  
  # 创建目录
  mkdir -p ~/.foundry/bin
  
  # 检测系统架构
  local arch
  case $(uname -m) in
    x86_64) arch="x86_64" ;;
    aarch64) arch="aarch64" ;;
    *) arch="x86_64" ;;
  esac
  
  # 下载 cast 二进制文件
  local cast_url="https://github.com/foundry-rs/foundry/releases/download/nightly/cast-$arch-unknown-linux-gnu"
  
  print_info "下载 cast 工具..."
  if curl -L -o ~/.foundry/bin/cast "$cast_url" 2>/dev/null; then
    chmod +x ~/.foundry/bin/cast
    print_success "cast 安装成功"
  else
    print_error "cast 下载失败"
    return 1
  fi
  
  # 添加到 PATH
  echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
  export PATH="$HOME/.foundry/bin:$PATH"
  
  return 0
}

# ==================== 自动安装依赖 ====================
auto_install_dependencies() {
  print_info "开始自动安装依赖..."
  
  # 更新系统
  apt-get update >/dev/null 2>&1
  
  # 安装基础工具
  print_info "安装基础工具..."
  apt-get install -y curl wget jq net-tools >/dev/null 2>&1
  
  # 安装 Docker
  if ! command -v docker >/dev/null 2>&1; then
    print_info "安装 Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
  fi
  
  # 安装 Docker Compose
  if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    print_info "安装 Docker Compose..."
    apt-get install -y docker-compose-plugin >/dev/null 2>&1
  fi
  
  # 安装 Foundry - 使用直接下载方法
  if ! command -v cast >/dev/null 2>&1; then
    if ! install_foundry_direct; then
      print_error "Foundry 安装失败"
      return 1
    fi
  fi
  
  # 安装 Aztec CLI
  if ! command -v aztec >/dev/null 2>&1; then
    print_info "安装 Aztec CLI..."
    if curl -sL https://install.aztec.network | bash >/dev/null 2>&1; then
      export PATH="$HOME/.aztec/bin:$PATH"
      print_success "Aztec CLI 安装成功"
    else
      print_error "Aztec CLI 安装失败"
      return 1
    fi
  fi
  
  # 重新加载 bashrc 以确保 PATH 生效
  source ~/.bashrc >/dev/null 2>&1 || true
  
  # 最终检查
  local missing_tools=()
  for tool in docker jq cast aztec; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools+=("$tool")
    fi
  done
  
  if [ ${#missing_tools[@]} -eq 0 ]; then
    print_success "所有依赖安装完成！"
    return 0
  else
    print_error "以下工具安装失败: ${missing_tools[*]}"
    return 1
  fi
}

# ==================== 环境检查 ====================
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
    if auto_install_dependencies; then
      print_success "环境检查通过"
      return 0
    else
      print_error "自动安装失败，请手动安装依赖"
      echo "手动安装命令:"
      echo "  apt-get update && apt-get install -y curl jq"
      echo "  curl -fsSL https://get.docker.com | sh"
      echo "  curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup"
      echo "  curl -sL https://install.aztec.network | bash"
      return 1
    fi
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
  if ! validate_environment; then
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 获取用户输入 - 显示输入内容
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
    print_error "私钥格式错误，应该是 64 位十六进制数（0x开头）"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi

  # 显示旧地址
  local old_address
  old_address=$(cast wallet address --private-key "$OLD_PRIVATE_KEY" 2>/dev/null)
  if [[ ! "$old_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_error "私钥无效，无法生成地址"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi
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

  # 显示密钥信息 - 清晰显示
  echo ""
  print_warning "=== 请立即保存以下密钥信息！ ==="
  echo "=========================================="
  echo "🔑 新的以太坊私钥:"
  echo "   $new_eth_key"
  echo ""
  echo "🔐 新的 BLS 私钥:"
  echo "   $new_bls_key"
  echo ""
  echo "📍 新的公钥地址:"
  echo "   $new_address"
  echo "=========================================="
  print_warning "这些信息只会显示一次！请立即保存到安全的地方！"
  echo ""
  read -p "确认已保存所有密钥信息后按 [Enter] 继续..."

  # STAKE 授权
  print_info "执行 STAKE 授权..."
  echo "正在授权 200,000 STAKE 给 Rollup 合约..."
  if ! cast send "$STAKE_TOKEN" "approve(address,uint256)" \
    "$ROLLUP_CONTRACT" "200000ether" \
    --private-key "$OLD_PRIVATE_KEY" --rpc-url "$ETH_RPC" >/dev/null 2>&1; then
    print_error "STAKE 授权失败！请检查："
    echo "1. 私钥是否正确"
    echo "2. 地址是否有 200k STAKE"
    echo "3. RPC 是否可用"
    read -n 1 -s -r -p "按任意键返回菜单..."
    return 1
  fi
  print_success "STAKE 授权成功"

  # 资金提示
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
  print_info "注册验证者到测试网..."
  echo "正在注册验证者..."
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
  if docker compose up -d; then
    print_success "节点启动成功"
  else
    print_error "节点启动失败"
    read -n 1 -s -r -p "按任意键继续..."
    return 1
  fi

  # 完成信息
  echo ""
  print_success "🎉 Aztec 2.1.2 节点部署完成！"
  echo ""
  print_info "=== 重要信息汇总 ==="
  echo "📍 新验证者地址: $new_address"
  echo "📊 排队查询: $DASHTEC_URL/validator/$new_address"
  echo "📝 查看日志: docker logs -f aztec-sequencer"
  echo "🔄 查看状态: curl http://localhost:8080/status"
  echo "📁 数据目录: $AZTEC_DIR"
  echo ""
  print_warning "请确保已妥善保存所有密钥信息！"
  
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
      2) 
        echo "查看节点日志 (Ctrl+C 退出)..."
        docker logs -f aztec-sequencer 2>/dev/null || echo "节点未运行"
        ;;
      3) 
        if docker ps | grep -q aztec-sequencer; then
          echo "✅ 节点状态: 运行中"
          echo ""
          echo "最近日志:"
          docker logs --tail 10 aztec-sequencer 2>/dev/null | tail -10
        else
          echo "❌ 节点状态: 未运行"
        fi
        read -n 1 -s -r -p "按任意键继续..."
        ;;
      4) 
        echo "退出脚本"
        exit 0 
        ;;
      *) 
        echo "无效选项"
        read -n 1 -s -r -p "按任意键继续..." 
        ;;
    esac
  done
}

# 主程序
main_menu
