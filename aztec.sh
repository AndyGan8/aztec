#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Aztec 节点管理脚本（优化版 v3.1）
# 优化点：
# - 移除 aztec validator-keys new 中的 --fee-recipient 选项（默认使用 attester 地址，避免零地址无效错误）
# - 其他功能保持不变
# ==================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi

SCRIPT_VERSION="v3.1 (2025-11-11)"

# ------------------ 可配置项 ------------------
AZTEC_DIR="/root/aztec-sequencer"
DATA_DIR="$AZTEC_DIR/data"
KEY_DIR="$AZTEC_DIR/keys"
AZTEC_IMAGE="aztecprotocol/aztec:latest"

ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
STAKE_AMOUNT=200000000000000000000  # 200 STK (18 decimals)
DASHTEC_URL="https://dashtec.xyz"
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

# RPC 默认值从环境变量读取，提示中不显示具体值
# export DEFAULT_ETH_RPC="https://rpc.sepolia.org"
# export DEFAULT_CONS_RPC="https://ethereum-sepolia-beacon-api.publicnode.com"

# ------------------ 输出样式 ------------------
print_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ------------------ 环境检查 ------------------
check_environment() {
    print_info "检查环境..."
    export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"
    local missing=()
    for cmd in docker jq cast aztec bc curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "缺少命令: ${missing[*]}。请安装后重试。"
        return 1
    fi
    print_success "环境检查通过"
    return 0
}

# ------------------ 私钥生成地址 ------------------
generate_address_from_private_key() {
    local private_key=$1
    private_key=$(echo "$private_key" | tr -d ' ' | sed 's/^0x//')
    if [[ ${#private_key} -ne 64 ]]; then
        print_error "私钥长度无效（需 64 位 hex）"
        return 1
    fi
    local address
    address=$(cast wallet address --private-key "0x$private_key" 2>/dev/null) || {
        print_error "无法从私钥生成地址"
        return 1
    }
    echo "$address"
}

# ------------------ 检查 STK 授权 ------------------
# 返回 hex string（0x...）
check_stk_allowance() {
    local rpc_url=$1
    local funding_address=$2

    local owner_padded=$(printf "%064s" "${funding_address#0x}" | tr ' ' '0')
    local spender_padded=$(printf "%064s" "${ROLLUP_CONTRACT#0x}" | tr ' ' '0')
    local data="0xdd62ed3e${owner_padded}${spender_padded}"

    local result
    result=$(curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$STAKE_TOKEN\",\"data\":\"$data\"},\"latest\"],\"id\":1}" "$rpc_url" | jq -r '.result // "0x0"') || {
        print_error "RPC 调用失败"
        return 1
    }
    echo "$result"
}

# ------------------ 发送 STK Approve ------------------
send_stk_approve() {
    local rpc_url=$1
    local funding_private_key=$2

    print_info "发送 STK Approve（spender: $ROLLUP_CONTRACT）"

    local approve_tx
    approve_tx=$(cast send "$STAKE_TOKEN" "approve(address,uint256)" "$ROLLUP_CONTRACT" "$STAKE_AMOUNT" --private-key "$funding_private_key" --rpc-url "$rpc_url" --gas-limit 200000 --json 2>&1) || {
        print_error "Approve 发送失败：$approve_tx"
        return 1
    }

    if echo "$approve_tx" | jq . >/dev/null 2>&1; then
        local status txhash
        status=$(echo "$approve_tx" | jq -r '.status // empty')
        txhash=$(echo "$approve_tx" | jq -r '.transactionHash // empty')
        if [[ "$status" == "1" || "$status" == "0x1" ]]; then
            print_success "Approve 成功！Tx: $txhash"
            sleep 25
            return 0
        else
            print_error "Approve 返回 status=$status"
            return 1
        fi
    else
        # 备用解析（如果非 JSON 输出）
        local grep_status=$(echo "$approve_tx" | grep -i "status" | head -1 | sed -E 's/.*status[^0-9]*([0-9x]+).*/\1/' | tr -d ' ')
        local grep_hash=$(echo "$approve_tx" | grep -i "transactionHash\|0x[0-9a-f]\{64\}" | head -1 | sed -E 's/.*(0x[0-9a-f]{64}).*/\1/')
        if [[ "$grep_status" == "1" || "$grep_status" == "0x1" ]]; then
            print_success "Approve 成功！Tx: ${grep_hash:-unknown}"
            sleep 25
            return 0
        fi
        print_error "Approve 解析失败：$approve_tx"
        return 1
    fi
}

# ------------------ 容器检查 ------------------
is_container_running() {
    docker ps --filter "name=aztec-sequencer" --format '{{.Names}}' | grep -q '^aztec-sequencer$'
}

# ------------------ 容器清理 ------------------
cleanup_existing_containers() {
    print_info "清理现有容器..."
    if is_container_running; then
        docker stop aztec-sequencer
        sleep 2
    fi
    docker rm aztec-sequencer 2>/dev/null || true
    docker network rm aztec 2>/dev/null || true
    print_success "容器清理完成"
}

# ------------------ 获取公网 IP ------------------
get_public_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 --max-time 10 ipv4.icanhazip.com) ||
        ip=$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me) ||
        ip="127.0.0.1"
    echo "$ip"
}

# ------------------ 安装并启动节点 ------------------
install_and_start_node() {
    clear
    print_info "Aztec 节点安装/启动 (v$SCRIPT_VERSION)"
    if ! check_environment; then
        print_error "环境检查失败"
        read -p "按任意键继续..."
        return 1
    fi

    local DEFAULT_ETH_RPC_ENV=${DEFAULT_ETH_RPC:-}
    local DEFAULT_CONS_RPC_ENV=${DEFAULT_CONS_RPC:-}

    read -p "L1 RPC（回车使用环境变量 DEFAULT_ETH_RPC，如未设置则必须输入）: " ETH_RPC
    ETH_RPC=${ETH_RPC:-$DEFAULT_ETH_RPC_ENV}
    if [[ -z "$ETH_RPC" ]]; then
        print_error "L1 RPC 未提供。请设置环境变量 DEFAULT_ETH_RPC 或输入。"
        read -p "按任意键继续..."
        return 1
    fi

    read -p "Beacon/Consensus RPC（回车使用环境变量 DEFAULT_CONS_RPC，如未设置则必须输入）: " CONS_RPC
    CONS_RPC=${CONS_RPC:-$DEFAULT_CONS_RPC_ENV}
    if [[ -z "$CONS_RPC" ]]; then
        print_error "Consensus RPC 未提供。请设置环境变量 DEFAULT_CONS_RPC 或输入。"
        read -p "按任意键继续..."
        return 1
    fi

    read -sp "Funding 私钥 (以 0x 开头): " FUNDING_PRIVATE_KEY
    echo
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "Funding 私钥格式无效（需 0x + 64 位 hex）"
        read -p "按任意键继续..."
        return 1
    fi

    local funding_address
    funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY") || {
        read -p "按任意键继续..."
        return 1
    }
    print_info "Funding 地址: $funding_address"

    echo
    echo "密钥模式：1. 新生成  2. 加载 keystore"
    read -p "选择 (1-2): " mode_choice

    local new_eth_key new_bls_key new_address keystore_path
    case $mode_choice in
        1)
            rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
            aztec validator-keys new || { print_error "生成键失败"; read -p "按任意键继续..."; return 1; }
            if [[ ! -f "$DEFAULT_KEYSTORE" ]]; then
                print_error "新生成后未找到 keystore: $DEFAULT_KEYSTORE"
                read -p "按任意键继续..."
                return 1
            fi
            keystore_path="$DEFAULT_KEYSTORE"
            ;;
        2)
            read -p "keystore 路径 (回车使用 $DEFAULT_KEYSTORE): " keystore_path_input
            keystore_path=${keystore_path_input:-$DEFAULT_KEYSTORE}
            if [[ ! -f "$keystore_path" ]]; then
                print_error "keystore 文件不存在: $keystore_path"
                read -p "按任意键继续..."
                return 1
            fi
            ;;
        *) print_error "无效选择"; read -p "按任意键继续..."; return 1 ;;
    esac

    new_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path") || { print_error "无法读取 eth 私钥"; return 1; }
    new_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path") || { print_error "无法读取 bls 私钥"; return 1; }
    new_address=$(generate_address_from_private_key "$new_eth_key") || { print_error "无法从 eth 私钥生成地址"; return 1; }
    mkdir -p "$KEY_DIR"
    cp "$keystore_path" "$KEY_DIR/key1.json"
    chmod 600 "$KEY_DIR/key1.json"
    print_success "密钥加载成功: $new_address (keystore 已保存到 $KEY_DIR/key1.json)"

    cleanup_existing_containers
    mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"

    local public_ip
    public_ip=$(get_public_ip)
    print_info "检测到公网 IP: $public_ip"

    # 生成 .env
    cat > "$AZTEC_DIR/.env" << EOF
LOG_LEVEL=debug
ETHEREUM_HOSTS=$ETH_RPC
L1_CONSENSUS_HOST_URLS=$CONS_RPC
P2P_IP=$public_ip
P2P_PORT=40400
AZTEC_PORT=8080
AZTEC_ADMIN_PORT=8880
VALIDATOR_PRIVATE_KEY=$new_eth_key
COINBASE=$new_address
EOF

    # 生成 docker-compose.yml
    cat > "$AZTEC_DIR/docker-compose.yml" << EOF
version: '3.8'
services:
  aztec-sequencer:
    image: $AZTEC_IMAGE
    container_name: aztec-sequencer
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
      ETHEREUM_HOSTS: $ETH_RPC
      L1_CONSENSUS_HOST_URLS: $CONS_RPC
      P2P_IP: $public_ip
      P2P_PORT: 40400
      AZTEC_PORT: 8080
      AZTEC_ADMIN_PORT: 8880
      VALIDATOR_PRIVATE_KEY: $new_eth_key
      COINBASE: $new_address
    entrypoint: >-
      node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --node --archiver --sequencer --network testnet
    networks:
      - aztec
    restart: always
networks:
  aztec:
    name: aztec
EOF

    print_info "启动容器..."
    cd "$AZTEC_DIR"
    docker compose up -d || { print_error "docker 启动失败"; read -p "按任意键继续..."; return 1; }
    sleep 8
    docker logs aztec-sequencer --tail 20 || true

    if curl -s --max-time 5 http://localhost:8080/status >/dev/null 2>&1; then
        print_success "节点启动成功"
    else
        print_warning "节点可能仍在初始化，稍后检查日志"
    fi
    echo "查看实时日志: docker logs -f aztec-sequencer"
    read -p "按任意键返回主菜单..."
}

# ------------------ 查看日志与状态 ------------------
view_logs_and_status() {
    clear
    print_info "节点日志和状态"
    if is_container_running; then
        echo "✅ 容器运行中"
        docker logs aztec-sequencer --tail 50
        echo ""
        echo "API status:"
        curl -s --max-time 5 http://localhost:8080/status || echo "API 未响应"
    else
        echo "❌ 容器未运行"
    fi
    echo ""
    read -p "按回车返回主菜单..."
}

# ------------------ 更新并重启 ------------------
update_and_restart_node() {
    clear
    print_info "更新节点镜像并重启"
    if [[ ! -d "$AZTEC_DIR" ]]; then
        print_error "目录不存在: $AZTEC_DIR"
        read -p "按任意键继续..."
        return 1
    fi
    cd "$AZTEC_DIR"
    if ! docker compose pull; then
        print_warning "镜像 pull 失败，继续尝试重启"
    fi
    docker compose down || true
    if ! docker compose up -d; then
        print_error "重启失败"
        read -p "按任意键继续..."
        return 1
    fi
    print_success "更新并重启完成"
    sleep 5
    docker logs aztec-sequencer --tail 20 || true
    read -p "按任意键返回主菜单..."
}

# ------------------ 停止节点 ------------------
stop_node() {
    clear
    print_info "停止节点"
    if is_container_running; then
        cleanup_existing_containers
        print_success "节点已停止"
    else
        print_warning "节点未运行"
    fi
    read -p "按任意键返回主菜单..."
}

# ------------------ 性能监控 ------------------
monitor_performance() {
    clear
    print_info "性能监控"
    free -h
    echo ""
    df -h
    echo ""
    top -b -n 1 | head -20
    echo ""
    read -p "按回车返回主菜单..."
}

# ------------------ 手动注册验证者 ------------------
register_validator_direct() {
    clear
    print_info "验证者注册（手动）"
    if ! check_environment; then
        print_error "环境检查失败"
        read -p "按任意键继续..."
        return 1
    fi

    local DEFAULT_ETH_RPC_ENV=${DEFAULT_ETH_RPC:-}

    read -p "L1 RPC（回车使用环境变量 DEFAULT_ETH_RPC，如未设置则必须输入）: " ETH_RPC
    ETH_RPC=${ETH_RPC:-$DEFAULT_ETH_RPC_ENV}
    if [[ -z "$ETH_RPC" ]]; then
        print_error "L1 RPC 未提供"
        read -p "按任意键继续..."
        return 1
    fi

    read -sp "Funding 私钥 (0x...): " FUNDING_PRIVATE_KEY
    echo
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "Funding 私钥格式错误"
        read -p "按任意键继续..."
        return 1
    fi

    read -sp "BLS 私钥 (0x...): " BLS_SECRET_KEY
    echo
    if [[ -z "$BLS_SECRET_KEY" || ! "$BLS_SECRET_KEY" =~ ^0x[a-fA-F0-9]{64,128}$ ]]; then
        print_error "BLS 私钥格式错误"
        read -p "按任意键继续..."
        return 1
    fi

    local funding_address
    funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY") || {
        read -p "按任意键继续..."
        return 1
    }
    print_info "Funding 地址: $funding_address"

    # 如果 keystore 存在，从中读取 attester/withdrawer
    local ATTESTER WITHDRAWER keystore_path
    if [[ -f "$KEY_DIR/key1.json" ]]; then
        keystore_path="$KEY_DIR/key1.json"
        ATTESTER=$(generate_address_from_private_key "$(jq -r '.validators[0].attester.eth' "$keystore_path")") || ATTESTER="0x0000000000000000000000000000000000000000"
        WITHDRAWER="$ATTESTER"
        print_info "使用 keystore 中的 attester: $ATTESTER"
    else
        # 回退到硬编码（优化后可移除）
        ATTESTER="0x188df4682a70262bdb316b02c56b31eb53e7c0cb"
        WITHDRAWER="$ATTESTER"
        print_warning "keystore 未找到，使用默认 attester: $ATTESTER"
    fi

    print_info "检查 STK 授权..."
    local allowance_hex allowance_dec required_dec=200  # 简化：直接用 200 STK 单位
    allowance_hex=$(check_stk_allowance "$ETH_RPC" "$funding_address") || {
        read -p "按任意键继续..."
        return 1
    }
    allowance_dec=$((16#${allowance_hex#0x})) 2>/dev/null || allowance_dec=0
    allowance_stk=$(echo "scale=0; $allowance_dec / 1000000000000000000" | bc 2>/dev/null || echo "0")

    print_info "当前授权: $allowance_stk STK (需 200 STK)"

    if [ "$allowance_dec" -lt "$STAKE_AMOUNT" ]; then
        print_warning "授权不足，尝试发送 approve..."
        if ! send_stk_approve "$ETH_RPC" "$FUNDING_PRIVATE_KEY"; then
            print_error "approve 失败，请手动检查或重试"
            read -p "按任意键继续..."
            return 1
        fi
    else
        print_success "授权充足"
    fi

    print_info "注册参数："
    echo "  Attester: $ATTESTER"
    echo "  Withdrawer: $WITHDRAWER"
    echo "  Rollup: $ROLLUP_CONTRACT"
    read -p "确认执行注册？按 Enter 继续或 Ctrl+C 取消..."

    if aztec add-l1-validator \
        --l1-rpc-urls "$ETH_RPC" \
        --network testnet \
        --private-key "$FUNDING_PRIVATE_KEY" \
        --attester "$ATTESTER" \
        --withdrawer "$WITHDRAWER" \
        --bls-secret-key "$BLS_SECRET_KEY" \
        --rollup "$ROLLUP_CONTRACT"; then
        print_success "注册成功！可在 dashtec/区块浏览器查看"
        echo "Dashtec: $DASHTEC_URL/validator/$ATTESTER"
    else
        print_error "注册失败，请查看 aztec CLI 输出"
    fi
    read -p "按任意键返回主菜单..."
}

# ------------------ 主菜单 ------------------
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Aztec 节点管理 $SCRIPT_VERSION"
        echo "========================================"
        echo "1. 安装/启动节点"
        echo "2. 查看日志/状态"
        echo "3. 更新/重启"
        echo "4. 性能监控"
        echo "5. 停止节点"
        echo "6. 注册验证者 (手动)"
        echo "7. 退出"
        echo "========================================"
        echo "提示: RPC 默认值请通过环境变量设置 (export DEFAULT_ETH_RPC=...)"
        echo "========================================"
        read -p "选择 (1-7): " choice
        case $choice in
            1) install_and_start_node ;;
            2) view_logs_and_status ;;
            3) update_and_restart_node ;;
            4) monitor_performance ;;
            5) stop_node ;;
            6) register_validator_direct ;;
            7) print_info "退出脚本"; exit 0 ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

main_menu
