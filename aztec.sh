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
STAKE_AMOUNT=200000000000000000000000
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

# ==================== 打印函数 ====================
print_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ==================== 修复的环境检查 ====================
check_environment() {
    print_info "检查环境..."
    
    # 设置环境变量
    export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"
    
    # 检查必要命令
    local missing=()
    
    if ! command -v docker >/dev/null 2>&1; then
        missing+=("docker")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq")
    fi
    
    if ! command -v cast >/dev/null 2>&1; then
        missing+=("cast")
    fi
    
    if ! command -v aztec >/dev/null 2>&1; then
        missing+=("aztec")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "缺少命令: ${missing[*]}"
        return 1
    fi
    
    # 最终验证
    print_info "环境验证:"
    echo "Docker: $(command -v docker)"
    echo "jq: $(command -v jq)"
    echo "cast: $(command -v cast)"
    echo "aztec: $(command -v aztec)"
    
    # 检查 Aztec CLI 版本
    local aztec_version=$(aztec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    print_info "Aztec CLI 版本: $aztec_version"
    
    if [[ "$aztec_version" < "2.1.2" ]]; then
        print_warning "Aztec CLI 版本过旧，建议更新到 v2.1.2"
    fi
    
    print_success "环境检查通过"
    return 0
}

# ==================== 从私钥生成地址 ====================
generate_address_from_private_key() {
    local private_key=$1
    private_key=$(echo "$private_key" | tr -d ' ' | sed 's/^0x//')
    if [[ ${#private_key} -ne 64 ]]; then
        print_error "私钥长度错误 (需64 hex): ${#private_key}"
        return 1
    fi
    private_key="0x$private_key"
    cast wallet address --private-key "$private_key" 2>/dev/null || echo ""
}

# ==================== 检查 ETH 余额 ====================
check_eth_balance() {
    local eth_rpc=$1
    local address=$2
    local balance_eth=$(cast balance "$address" --rpc-url "$eth_rpc" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "0")
    
    if [[ $(echo "$balance_eth >= 0.2" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
        print_success "ETH 充足 ($balance_eth ETH)"
        return 0
    else
        print_warning "ETH 不足 ($balance_eth ETH)，需至少 0.2 ETH 用于 gas"
        return 1
    fi
}

# ==================== 清理现有容器 ====================
cleanup_existing_containers() {
    print_info "检查并清理现有容器..."
    
    if docker ps -a | grep -q aztec-sequencer; then
        print_warning "发现现有的 aztec-sequencer 容器，正在清理..."
        
        if docker ps | grep -q aztec-sequencer; then
            docker stop aztec-sequencer
            sleep 3
        fi
        
        docker rm aztec-sequencer 2>/dev/null || true
        print_success "现有容器已清理"
    else
        print_info "没有找到现有的 aztec-sequencer 容器"
    fi
    
    if docker network ls | grep -q aztec; then
        print_info "清理现有网络..."
        docker network rm aztec 2>/dev/null || true
    fi
}

# ==================== 修复的主安装流程 ====================
install_and_start_node() {
    clear
    print_info "Aztec 测试网节点安装 - v2.1.2 兼容"
    echo "=========================================="
    
    # 环境检查
    if ! check_environment; then
        print_error "环境检查失败，请先安装必要的依赖"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    echo ""
    echo "请输入基础信息："
    
    read -p "L1 执行 RPC URL (推荐: https://rpc.sepolia.org): " ETH_RPC
    ETH_RPC=${ETH_RPC:-"https://rpc.sepolia.org"}
    echo
    
    read -p "L1 共识 Beacon RPC URL (推荐: https://ethereum-sepolia-beacon-api.publicnode.com): " CONS_RPC
    CONS_RPC=${CONS_RPC:-"https://ethereum-sepolia-beacon-api.publicnode.com"}
    echo
    
    read -p "Funding 私钥 (必须有 200k STAKE 和 0.2 ETH): " FUNDING_PRIVATE_KEY
    echo ""
    
    if [[ -z "$FUNDING_PRIVATE_KEY" ]]; then
        print_error "Funding 私钥不能为空"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    if [[ ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "私钥格式错误 (需 0x + 64 hex)"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    # 生成 funding 地址
    print_info "生成 Funding 地址..."
    local funding_address
    funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY")
    if [[ -z "$funding_address" || ! "$funding_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        print_error "Funding 地址生成失败"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    print_info "Funding 地址: $funding_address"
    
    # 检查余额
    if ! check_eth_balance "$ETH_RPC" "$funding_address"; then
        print_warning "Funding 地址 ETH 余额不足"
        read -p "请补充 ETH 后按任意键继续..."
    fi
    
    echo ""
    print_info "选择密钥模式："
    echo "1. 生成新地址"
    echo "2. 加载现有 keystore.json"
    read -p "请选择 (1-2): " mode_choice
    
    local new_eth_key new_bls_key new_address
    
    case $mode_choice in
        1)
            print_info "生成新密钥..."
            rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
            
            print_info "正在生成密钥对..."
            if ! aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000; then
                print_error "生成密钥失败"
                read -p "按任意键返回菜单..."
                return 1
            fi
            
            if [ ! -f "$DEFAULT_KEYSTORE" ]; then
                print_error "密钥文件未生成: $DEFAULT_KEYSTORE"
                read -p "按任意键返回菜单..."
                return 1
            fi
            
            new_eth_key=$(jq -r '.validators[0].attester.eth' "$DEFAULT_KEYSTORE")
            new_bls_key=$(jq -r '.validators[0].attester.bls' "$DEFAULT_KEYSTORE")
            new_address=$(generate_address_from_private_key "$new_eth_key")
            
            if [[ -z "$new_address" ]]; then
                print_error "地址生成失败"
                read -p "按任意键返回菜单..."
                return 1
            fi
            
            print_success "新地址: $new_address"
            echo ""
            print_warning "=== 请立即保存这些密钥！ ==="
            echo "ETH 私钥: $new_eth_key"
            echo "BLS 私钥: $new_bls_key"
            echo "地址: $new_address"
            echo ""
            read -p "确认已保存后按 [Enter] 继续..."
            ;;
        2)
            echo "输入 keystore.json 路径 (默认 $DEFAULT_KEYSTORE): "
            read -p "路径: " keystore_path
            keystore_path=${keystore_path:-$DEFAULT_KEYSTORE}
            
            if [ ! -f "$keystore_path" ]; then
                print_error "keystore 文件不存在: $keystore_path"
                read -p "按任意键返回菜单..."
                return 1
            fi
            
            new_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path")
            new_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path")
            
            if [[ -z "$new_eth_key" || "$new_eth_key" == "null" ]]; then
                print_error "ETH 私钥读取失败"
                read -p "按任意键返回菜单..."
                return 1
            fi
            
            new_address=$(generate_address_from_private_key "$new_eth_key")
            print_success "加载成功！地址: $new_address"
            ;;
        *)
            print_error "无效选择"
            read -p "按任意键返回菜单..."
            return 1
            ;;
    esac

    # 清理现有容器
    cleanup_existing_containers

    # 安装和启动节点
    print_info "设置节点环境..."
    mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"
    local public_ip=$(curl -s --connect-timeout 5 ipv4.icanhazip.com || echo "127.0.0.1")
    
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

    cat > "$AZTEC_DIR/docker-compose.yml" <<EOF
services:
  aztec-sequencer:
    image: "aztecprotocol/aztec:latest"
    container_name: "aztec-sequencer"
    ports:
      - "8080:8080"
      - "8880:8880"
      - "40400:40400"
      - "40400:40400/udp"
    volumes:
      - ./data:/var/lib/data
      - ./keys:/var/lib/keystore
    environment:
      KEY_STORE_DIRECTORY: /var/lib/keystore
      DATA_DIRECTORY: /var/lib/data
      LOG_LEVEL: debug
      ETHEREUM_HOSTS: ${ETH_RPC}
      L1_CONSENSUS_HOST_URLS: ${CONS_RPC}
      P2P_IP: ${public_ip}
      P2P_PORT: 40400
      AZTEC_PORT: 8080
      AZTEC_ADMIN_PORT: 8880
      VALIDATOR_PRIVATE_KEY: ${new_eth_key}
      COINBASE: ${new_address}
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

    print_info "启动节点..."
    cd "$AZTEC_DIR"
    
    if ! docker compose up -d; then
        print_error "节点启动失败"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    sleep 10
    print_info "启动后日志（最近20行）："
    docker logs aztec-sequencer --tail 20
    echo ""
    
    print_info "检查节点状态..."
    if curl -s http://localhost:8080/status >/dev/null 2>&1; then
        print_success "节点启动成功！API 可访问。"
    else
        print_warning "节点启动中... API 暂无响应（正常，等待同步）。"
    fi
    
    print_success "节点安装和启动完成！"
    echo "地址: $new_address"
    echo "注册请使用菜单选项6"
    echo "队列: $DASHTEC_URL/validator/$new_address"
    echo ""
    echo "日志: docker logs -f aztec-sequencer"
    echo "状态: curl http://localhost:8080/status"
    
    read -p "按任意键继续..."
    return 0
}

# ==================== 简化的其他菜单功能 ====================
view_logs_and_status() {
    clear
    print_info "节点日志和状态"
    echo "=========================================="
    
    if docker ps | grep -q aztec-sequencer; then
        echo "✅ 节点运行中"
        echo ""
        echo "最近日志:"
        docker logs aztec-sequencer --tail 50
    else
        echo "❌ 节点未运行"
    fi
    
    echo ""
    read -p "按任意键继续..."
}

update_and_restart_node() {
    clear
    print_info "更新并重启节点"
    echo "=========================================="
    
    if [ ! -d "$AZTEC_DIR" ]; then
        print_error "节点目录不存在"
        read -p "按任意键继续..."
        return
    fi
    
    cd "$AZTEC_DIR"
    print_info "拉取最新镜像..."
    docker compose pull
    print_info "重启节点..."
    docker compose down
    docker compose up -d
    print_success "节点已更新重启"
    read -p "按任意键继续..."
}

monitor_performance() {
    clear
    print_info "性能监控"
    echo "=========================================="
    echo "系统资源:"
    free -h
    echo ""
    echo "磁盘使用:"
    df -h
    echo ""
    read -p "按任意键继续..."
}

register_validator() {
    clear
    print_info "注册验证者"
    echo "=========================================="
    echo "请先确保节点已安装并运行"
    echo "使用选项7进行快速注册"
    read -p "按任意键继续..."
}

register_validator_optimized() {
    clear
    print_info "快速注册验证者"
    echo "=========================================="
    echo "请运行单独的注册脚本或使用官方指南"
    echo "参考: https://docs.aztec.network"
    read -p "按任意键继续..."
}

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Aztec 节点管理脚本"
        echo "========================================"
        echo "1. 安装/启动节点"
        echo "2. 查看日志和状态"
        echo "3. 更新并重启节点"
        echo "4. 性能监控"
        echo "5. 退出"
        echo "6. 注册验证者"
        echo "7. 快速注册验证者"
        echo ""
        read -p "请选择 (1-7): " choice
        
        case $choice in
            1) install_and_start_node ;;
            2) view_logs_and_status ;;
            3) update_and_restart_node ;;
            4) monitor_performance ;;
            5) echo "再见！"; exit 0 ;;
            6) register_validator ;;
            7) register_validator_optimized ;;
            *) echo "无效选择，请重新输入"; sleep 1 ;;
        esac
    done
}

# 启动脚本
main_menu
