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
STAKE_AMOUNT=200000000000000000000  # 200 STK (18 decimals)
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

# ==================== 打印函数 ====================
print_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ==================== 环境检查 ====================
check_environment() {
    print_info "检查环境..."
    export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"
    local missing=()
    if ! command -v docker >/dev/null 2>&1; then missing+=("docker"); fi
    if ! command -v jq >/dev/null 2>&1; then missing+=("jq"); fi
    if ! command -v cast >/dev/null 2>&1; then missing+=("cast"); fi
    if ! command -v aztec >/dev/null 2>&1; then missing+=("aztec"); fi
    if ! command -v bc >/dev/null 2>&1; then missing+=("bc"); fi  # 用于 hex 转 dec
    if [ ${#missing[@]} -gt 0 ]; then print_error "缺少命令: ${missing[*]}"; return 1; fi
    print_success "环境检查通过"
    return 0
}

# ==================== 从私钥生成地址 ====================
generate_address_from_private_key() {
    local private_key=$1
    private_key=$(echo "$private_key" | tr -d ' ' | sed 's/^0x//')
    if [[ ${#private_key} -ne 64 ]]; then print_error "私钥长度错误 (需64 hex): ${#private_key}"; return 1; fi
    private_key="0x$private_key"
    cast wallet address --private-key "$private_key" 2>/dev/null || echo ""
}

# ==================== 检查 STK 授权 ====================
check_stk_allowance() {
    local rpc_url=$1 funding_address=$2
    local allowance_hex=$(curl -s -X POST -H "Content-Type: application/json" --data "{
      \"jsonrpc\": \"2.0\",
      \"method\": \"eth_call\",
      \"params\": [
        {
          \"to\": \"$STAKE_TOKEN\",
          \"data\": \"0xdd62ed3e000000000000000000000000$(echo $funding_address | sed 's/0x//')00000000000000000000000000000000$(echo $ROLLUP_CONTRACT | sed 's/0x//')\"
        },
        \"latest\"
      ],
      \"id\": 1
    }" "$rpc_url" | jq -r '.result')
    if [[ "$allowance_hex" == "null" || "$allowance_hex" == "" || "$allowance_hex" == "0x" ]]; then echo "0"; else echo "$allowance_hex"; fi
}

# ==================== 发送 STK Approve ====================
send_stk_approve() {
    local rpc_url=$1 funding_private_key=$2
    local approve_tx=$(cast send "$STAKE_TOKEN" "approve(address,uint256)" "$ROLLUP_CONTRACT" "$STAKE_AMOUNT" --private-key "$funding_private_key" --rpc-url "$rpc_url" --gas-limit 200000 2>&1)
    if echo "$approve_tx" | jq . >/dev/null 2>&1; then
        local status=$(echo "$approve_tx" | jq -r '.status')
        local tx_hash=$(echo "$approve_tx" | jq -r '.transactionHash')
        if [[ "$status" == "1" ]]; then
            print_success "Approve 成功！Tx: $tx_hash"
            sleep 30
            return 0
        else
            print_error "Approve 失败 (status: $status)"
            return 1
        fi
    else
        print_error "Approve 发送失败: $approve_tx"
        return 1
    fi
}

# ==================== 清理容器 ====================
cleanup_existing_containers() {
    print_info "清理现有容器..."
    if docker ps -a | grep -q aztec-sequencer; then
        docker stop aztec-sequencer 2>/dev/null || true
        sleep 3
        docker rm aztec-sequencer 2>/dev/null || true
        print_success "容器清理完成"
    fi
    docker network rm aztec 2>/dev/null || true
}

# ==================== 安装/启动节点 ====================
install_and_start_node() {
    clear
    print_info "Aztec 测试网节点安装"
    echo "=========================================="
    if ! check_environment; then print_error "环境检查失败"; read -p "按任意键..."; return 1; fi
    
    echo "基础信息："
    read -p "L1 RPC (默认 https://rpc.sepolia.org): " ETH_RPC
    ETH_RPC=${ETH_RPC:-"https://rpc.sepolia.org"}
    read -p "Beacon RPC (默认 https://ethereum-sepolia-beacon-api.publicnode.com): " CONS_RPC
    CONS_RPC=${CONS_RPC:-"https://ethereum-sepolia-beacon-api.publicnode.com"}
    read -p "Funding 私钥: " FUNDING_PRIVATE_KEY
    
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "私钥无效"; read -p "按任意键..."; return 1
    fi
    
    local funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY")
    print_info "Funding: $funding_address"
    
    echo "密钥模式：1. 新生成 2. 加载 keystore"
    read -p "选择 (1-2): " mode_choice
    
    local new_eth_key new_bls_key new_address
    case $mode_choice in
        1)
            rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
            aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000 || { print_error "生成失败"; return 1; }
            new_eth_key=$(jq -r '.validators[0].attester.eth' "$DEFAULT_KEYSTORE")
            new_bls_key=$(jq -r '.validators[0].attester.bls' "$DEFAULT_KEYSTORE")
            new_address=$(generate_address_from_private_key "$new_eth_key")
            mkdir -p "$KEY_DIR"
            cp "$DEFAULT_KEYSTORE" "$KEY_DIR/key1.json"
            chmod 600 "$KEY_DIR/key1.json"
            print_success "新地址: $new_address (保存私钥: ETH $new_eth_key, BLS $new_bls_key)"
            read -p "确认保存 [Enter]..."
            ;;
        2)
            read -p "keystore 路径 (默认 $DEFAULT_KEYSTORE): " keystore_path
            keystore_path=${keystore_path:-$DEFAULT_KEYSTORE}
            if [[ ! -f "$keystore_path" ]]; then print_error "文件不存在"; return 1; fi
            new_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path")
            new_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path")
            new_address=$(generate_address_from_private_key "$new_eth_key")
            mkdir -p "$KEY_DIR"
            cp "$keystore_path" "$KEY_DIR/key1.json"
            chmod 600 "$KEY_DIR/key1.json"
            print_success "加载成功: $new_address"
            ;;
        *) print_error "无效选择"; return 1 ;;
    esac

    cleanup_existing_containers
    mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"
    local public_ip=$(curl -s --connect-timeout 5 ipv4.icanhazip.com || echo "127.0.0.1")
    
    cat > "$AZTEC_DIR/.env" <<EOF
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
    image: "${AZTEC_IMAGE}"
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
      node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --node --archiver --sequencer --network testnet
    networks:
      - aztec
    restart: always
networks:
  aztec:
    name: aztec
EOF

    print_info "启动节点..."
    cd "$AZTEC_DIR"
    docker compose up -d || { print_error "启动失败"; return 1; }
    sleep 10
    docker logs aztec-sequencer --tail 20
    if curl -s http://localhost:8080/status >/dev/null 2>&1; then
        print_success "节点启动成功！"
    else
        print_warning "节点启动中..."
    fi
    echo "日志: docker logs -f aztec-sequencer"
    read -p "按任意键..."
}

# ==================== 查看日志 ====================
view_logs_and_status() {
    clear
    print_info "节点日志和状态"
    if docker ps | grep -q aztec-sequencer; then
        echo "✅ 运行中"
        docker logs aztec-sequencer --tail 50
        curl -s http://localhost:8080/status || echo "API 未响应"
    else
        echo "❌ 未运行"
    fi
    read -p "按任意键..."
}

# ==================== 更新节点 ====================
update_and_restart_node() {
    clear
    print_info "更新节点"
    if [[ ! -d "$AZTEC_DIR" ]]; then print_error "目录不存在"; read -p "按任意键..."; return; fi
    cd "$AZTEC_DIR"
    docker compose pull
    docker compose down
    docker compose up -d
    print_success "更新完成"
    read -p "按任意键..."
}

# ==================== 性能监控 ====================
monitor_performance() {
    clear
    print_info "性能监控"
    free -h
    echo ""
    df -h
    read -p "按任意键..."
}

# ==================== 注册验证者 (手动版) ====================
register_validator_direct() {
    clear
    print_info "验证者注册 (手动版)"
    if ! check_environment; then print_error "环境失败"; read -p "按任意键..."; return 1; fi
    
    echo "信息："
    read -p "L1 RPC (默认 http://94.72.112.218:8545): " ETH_RPC
    ETH_RPC=${ETH_RPC:-"http://94.72.112.218:8545"}
    read -sp "Funding 私钥 (需以 0x 开头): " FUNDING_PRIVATE_KEY
    echo
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then print_error "私钥无效"; return 1; fi
    
    read -sp "BLS 私钥 (需以 0x 开头): " BLS_SECRET_KEY
    echo
    if [[ -z "$BLS_SECRET_KEY" || ! "$BLS_SECRET_KEY" =~ ^0x[a-fA-F0-9]{64,128}$ ]]; then print_error "BLS 私钥无效 (长度需 64-128 hex)"; return 1; fi  # BLS 私钥通常 32 字节 (64 hex)
    
    local funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY")
    print_info "Funding 地址: $funding_address"
    
    # 可选：检查并执行 STK 授权 (如果不需要，注释掉)
    print_info "检查授权..."
    local allowance_hex=$(check_stk_allowance "$ETH_RPC" "$funding_address")
    local allowance_dec=$(echo "ibase=16; ${allowance_hex#0x}" | bc 2>/dev/null || echo "0")  # 修正 bc 输入 (去掉 0x)
    local required_dec=200000000000000000000
    print_info "当前授权: $((allowance_dec / 10**18)) STK"
    
    if [ "$allowance_dec" -lt "$required_dec" ]; then
        print_warning "授权不足，执行 approve..."
        if ! send_stk_approve "$ETH_RPC" "$FUNDING_PRIVATE_KEY"; then
            print_error "Approve 失败，手动重试"
            read -p "按任意键..."; return 1
        fi
    fi
    
    # 固定 attester/withdrawer (你的示例地址)
    local ATTESTER="0x188df4682a70262bdb316b02c56b31eb53e7c0cb"
    local WITHDRAWER="0x188df4682a70262bdb316b02c56b31eb53e7c0cb"
    
    print_info "注册参数："
    echo "  Attester/Withdrawer: $ATTESTER"
    echo "  Rollup: $ROLLUP_CONTRACT"
    read -p "确认执行？[Enter] 或 Ctrl+C 取消..."
    
    # 执行你的命令
    if aztec add-l1-validator \
        --l1-rpc-urls "$ETH_RPC" \
        --network testnet \
        --private-key "$FUNDING_PRIVATE_KEY" \
        --attester "$ATTESTER" \
        --withdrawer "$WITHDRAWER" \
        --bls-secret-key "$BLS_SECRET_KEY" \
        --rollup "$ROLLUP_CONTRACT" \
        --yes; then  # --yes 自动确认
        
        print_success "注册成功！队列检查: $DASHTEC_URL/validator/$ATTESTER"
        echo "Tx 检查: https://sepolia.etherscan.io/address/$funding_address"
    else
        print_error "注册失败，重试或检查 aztec 命令输出"
    fi
    read -p "按任意键..."
}

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Aztec 节点管理"
        echo "1. 安装/启动节点"
        echo "2. 查看日志/状态"
        echo "3. 更新/重启"
        echo "4. 性能监控"
        echo "5. 退出"
        echo "6. 注册验证者 (自动)"
        echo ""
        read -p "选择 (1-6): " choice
        case $choice in
            1) install_and_start_node ;;
            2) view_logs_and_status ;;
            3) update_and_restart_node ;;
            4) monitor_performance ;;
            5) exit 0 ;;
            6) register_validator_direct ;;
            *) echo "无效"; sleep 1 ;;
        esac
    done
}

main_menu
