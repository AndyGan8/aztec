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
    local min_eth=${3:-0.2}
    
    local balance_wei=$(cast balance "$address" --rpc-url "$eth_rpc" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
    local balance_eth=$(echo "scale=4; $balance_wei / 1000000000000000000" | bc 2>/dev/null || echo "0")
    
    if (( $(echo "$balance_eth >= $min_eth" | bc -l 2>/dev/null || echo "0") )); then
        print_success "ETH 充足 ($balance_eth ETH)"
        return 0
    else
        print_warning "ETH 不足 ($balance_eth ETH)，需至少 $min_eth ETH"
        return 1
    fi
}

# ==================== 检查 STAKE 余额 ====================
check_stake_balance() {
    local eth_rpc=$1
    local address=$2
    
    print_info "检查 STAKE 余额..."
    local balance_hex=$(cast call "$STAKE_TOKEN" "balanceOf(address)(uint256)" "$address" --rpc-url "$eth_rpc" 2>/dev/null || echo "0x0")
    local balance=$(printf "%d" "$balance_hex" 2>/dev/null || echo "0")
    local formatted_balance=$(echo "scale=0; $balance / 1000000000000000000" | bc 2>/dev/null || echo "0")
    
    if [[ "$balance" -ge "$STAKE_AMOUNT" ]]; then
        print_success "STAKE 余额充足: $formatted_balance STAKE"
        return 0
    else
        print_error "STAKE 余额不足: $formatted_balance STAKE (需要 200k)"
        return 1
    fi
}

# ==================== 检查 STAKE 授权 ====================
check_stake_allowance() {
    local eth_rpc=$1
    local address=$2
    
    print_info "检查 STAKE 授权..."
    local allowance_hex=$(cast call "$STAKE_TOKEN" "allowance(address,address)(uint256)" "$address" "$ROLLUP_CONTRACT" --rpc-url "$eth_rpc" 2>/dev/null || echo "0x0")
    local allowance=$(printf "%d" "$allowance_hex" 2>/dev/null || echo "0")
    local formatted_allowance=$(echo "scale=0; $allowance / 1000000000000000000" | bc 2>/dev/null || echo "0")
    
    if [[ "$allowance" -ge "$STAKE_AMOUNT" ]]; then
        print_success "STAKE 已授权: $formatted_allowance STAKE"
        return 0
    else
        print_warning "STAKE 未授权或额度不足: $formatted_allowance STAKE"
        return 1
    fi
}

# ==================== 授权 STAKE ====================
approve_stake() {
    local eth_rpc=$1
    local private_key=$2
    
    print_info "执行 STAKE 授权..."
    
    for attempt in {1..3}; do
        print_info "授权尝试 $attempt/3..."
        
        if cast send "$STAKE_TOKEN" \
            "approve(address,uint256)" \
            "$ROLLUP_CONTRACT" \
            "200000000000000000000000" \
            --private-key "$private_key" \
            --rpc-url "$eth_rpc" \
            --gas-price 2gwei; then
            
            print_success "✅ 授权交易发送成功"
            
            # 等待交易确认
            print_info "等待交易确认..."
            sleep 10
            
            # 验证授权结果
            if check_stake_allowance "$eth_rpc" "$(generate_address_from_private_key "$private_key")"; then
                print_success "✅ STAKE 授权成功"
                return 0
            else
                print_warning "交易已确认但授权未生效，重试..."
            fi
        else
            print_warning "授权交易失败，重试..."
        fi
        
        if [[ $attempt -lt 3 ]]; then
            sleep 5
        fi
    done
    
    print_error "❌ STAKE 授权失败"
    return 1
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

# ==================== 优化的注册验证者函数 ====================
register_validator_optimized() {
    clear
    print_info "Aztec 验证者注册 (优化版)"
    echo "=========================================="
    
    if ! check_environment; then
        print_error "环境检查失败"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    echo ""
    echo "请提供注册信息："
    
    read -p "L1 RPC URL (推荐: https://rpc.sepolia.org): " ETH_RPC
    ETH_RPC=${ETH_RPC:-"https://rpc.sepolia.org"}
    echo
    
    read -sp "Funding 私钥 (必须有 200k STAKE 和 ETH): " FUNDING_PRIVATE_KEY
    echo
    echo
    
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "私钥格式错误"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    # 生成 funding 地址
    local funding_address
    funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY")
    print_info "Funding 地址: $funding_address"
    
    # 检查余额
    echo ""
    print_info "检查余额..."
    if ! check_eth_balance "$ETH_RPC" "$funding_address" "0.2"; then
        print_error "ETH 余额不足，无法继续注册"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    if ! check_stake_balance "$ETH_RPC" "$funding_address"; then
        print_error "STAKE 余额不足，无法继续注册"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    # 检查并授权 STAKE
    echo ""
    if ! check_stake_allowance "$ETH_RPC" "$funding_address"; then
        if ! approve_stake "$ETH_RPC" "$FUNDING_PRIVATE_KEY"; then
            print_error "STAKE 授权失败，无法继续注册"
            read -p "按任意键返回菜单..."
            return 1
        fi
    fi
    
    # 选择验证者密钥
    echo ""
    print_info "选择验证者密钥："
    echo "1. 使用现有节点密钥"
    echo "2. 生成新密钥"
    echo "3. 加载 keystore.json"
    read -p "请选择 (1-3): " key_choice
    
    local validator_eth_key validator_bls_key validator_address
    
    case $key_choice in
        1)
            # 使用现有节点密钥
            if [ -f "$AZTEC_DIR/.env" ]; then
                validator_eth_key=$(grep "VALIDATOR_PRIVATE_KEY" "$AZTEC_DIR/.env" | cut -d'=' -f2)
                validator_address=$(grep "COINBASE" "$AZTEC_DIR/.env" | cut -d'=' -f2)
                if [[ -n "$validator_eth_key" && -n "$validator_address" ]]; then
                    print_success "使用节点配置的密钥"
                    print_info "地址: $validator_address"
                    
                    # 需要用户提供 BLS 密钥
                    read -p "请输入该地址对应的 BLS 私钥: " validator_bls_key
                    if [[ -z "$validator_bls_key" ]]; then
                        print_error "BLS 私钥不能为空"
                        read -p "按任意键返回菜单..."
                        return 1
                    fi
                else
                    print_error "无法读取节点密钥"
                    read -p "按任意键返回菜单..."
                    return 1
                fi
            else
                print_error "节点配置文件不存在"
                read -p "按任意键返回菜单..."
                return 1
            fi
            ;;
        2)
            # 生成新密钥
            print_info "生成新验证者密钥..."
            rm -rf "/tmp/aztec_register_keystore" 2>/dev/null
            mkdir -p "/tmp/aztec_register_keystore"
            
            if aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000 --directory "/tmp/aztec_register_keystore"; then
                local temp_keystore="/tmp/aztec_register_keystore/key1.json"
                validator_eth_key=$(jq -r '.validators[0].attester.eth' "$temp_keystore")
                validator_bls_key=$(jq -r '.validators[0].attester.bls' "$temp_keystore")
                validator_address=$(generate_address_from_private_key "$validator_eth_key")
                
                print_success "新验证者地址: $validator_address"
                echo ""
                print_warning "=== 请保存这些密钥！ ==="
                echo "ETH 私钥: $validator_eth_key"
                echo "BLS 私钥: $validator_bls_key"
                echo "地址: $validator_address"
                echo ""
                read -p "确认已保存后按 [Enter] 继续..."
            else
                print_error "生成密钥失败"
                read -p "按任意键返回菜单..."
                return 1
            fi
            ;;
        3)
            # 加载 keystore
            read -p "请输入 keystore.json 路径: " keystore_path
            if [[ -f "$keystore_path" ]]; then
                validator_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path")
                validator_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path")
                validator_address=$(generate_address_from_private_key "$validator_eth_key")
                print_success "加载成功！地址: $validator_address"
            else
                print_error "keystore 文件不存在"
                read -p "按任意键返回菜单..."
                return 1
            fi
            ;;
        *)
            print_error "无效选择"
            read -p "按任意键返回菜单..."
            return 1
            ;;
    esac
    
    # 检查验证者地址余额
    echo ""
    print_info "检查验证者地址余额..."
    if ! check_eth_balance "$ETH_RPC" "$validator_address" "0.3"; then
        print_warning "验证者地址 ETH 余额不足，建议转账 0.3-0.5 ETH"
        echo "地址: $validator_address"
        read -p "确认后按 [Enter] 继续..."
    fi
    
    # 执行注册
    echo ""
    print_info "执行验证者注册..."
    print_info "注册信息:"
    echo "  - 验证者地址: $validator_address"
    echo "  - Funding 地址: $funding_address"
    echo "  - RPC: $ETH_RPC"
    echo ""
    
    read -p "确认注册信息正确后按 [Enter] 开始注册..."
    
    if aztec add-l1-validator \
        --l1-rpc-urls "$ETH_RPC" \
        --network testnet \
        --private-key "$FUNDING_PRIVATE_KEY" \
        --attester "$validator_address" \
        --withdrawer "$validator_address" \
        --bls-secret-key "$validator_bls_key" \
        --rollup "$ROLLUP_CONTRACT"; then
        
        echo ""
        print_success "🎉 验证者注册成功！"
        echo ""
        echo "✅ 注册完成信息:"
        echo "   - 验证者地址: $validator_address"
        echo "   - Funding 地址: $funding_address"
        echo "   - 网络: Sepolia Testnet"
        echo ""
        echo "📊 队列检查:"
        echo "   $DASHTEC_URL/validator/$validator_address"
        echo ""
        echo "💡 下一步:"
        echo "   1. 等待节点同步完成"
        echo "   2. 监控验证者状态"
        echo "   3. 确保节点持续运行"
        
    else
        print_error "❌ 验证者注册失败"
        echo ""
        echo "可能的原因:"
        echo "  1. 交易失败 (gas 不足或网络问题)"
        echo "  2. 参数错误"
        echo "  3. 网络连接问题"
    fi
    
    # 清理临时文件
    rm -rf "/tmp/aztec_register_keystore" 2>/dev/null
    
    echo ""
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
    # 重定向到优化版注册
    register_validator_optimized
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
        echo "6. 注册验证者 (推荐)"
        echo ""
        read -p "请选择 (1-6): " choice
        
        case $choice in
            1) install_and_start_node ;;
            2) view_logs_and_status ;;
            3) update_and_restart_node ;;
            4) monitor_performance ;;
            5) echo "再见！"; exit 0 ;;
            6) register_validator_optimized ;;
            *) echo "无效选择，请重新输入"; sleep 1 ;;
        esac
    done
}

# 启动脚本
main_menu
