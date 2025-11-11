#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Aztec 节点管理脚本（优化版 v3.7）
# 优化点：
# - 全局配置输入移到选项1（安装节点）和选项6（注册）开始时（如果未设），主菜单不强制
# - 私钥输入不隐藏（read -p）
# - 其他兼容2.1.2，手动注册模板
# ==================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi

SCRIPT_VERSION="v3.7 (2025-11-11, 兼容2.1.2)"

# ------------------ 可配置项 ------------------
AZTEC_DIR="/root/aztec-sequencer"
DATA_DIR="$AZTEC_DIR/data"
KEY_DIR="$AZTEC_DIR/keys"
AZTEC_IMAGE="aztecprotocol/aztec:latest"

ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
STAKE_AMOUNT=200000000000000000000  # 200k STK (18 decimals)
DASHTEC_URL="https://dashtec.xyz"
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"
ZERO_AZTEC_ADDR="0x0000000000000000000000000000000000000000000000000000000000000000"
PUBLISHER_GUIDE="https://docs.aztec.network/the_aztec_network/setup/sequencer_management#setting-up-a-publisher"

# 全局变量（从环境变量或输入）
GLOBAL_ETH_RPC="${DEFAULT_ETH_RPC:-}"
GLOBAL_CONS_RPC="${DEFAULT_CONS_RPC:-}"
GLOBAL_FUNDING_PRIVATE_KEY=""

# ------------------ 输出样式 ------------------
print_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ------------------ 全局输入配置 ------------------
get_global_config() {
    if [[ -z "$GLOBAL_ETH_RPC" ]]; then
        read -p "L1 RPC（回车使用环境变量 DEFAULT_ETH_RPC，如未设置则必须输入）: " input_eth_rpc
        GLOBAL_ETH_RPC=${input_eth_rpc:-${DEFAULT_ETH_RPC:-}}
        if [[ -z "$GLOBAL_ETH_RPC" ]]; then
            print_error "L1 RPC 未提供。请设置环境变量或输入。"
            exit 1
        fi
    fi
    if [[ -z "$GLOBAL_CONS_RPC" ]]; then
        read -p "Beacon/Consensus RPC（回车使用环境变量 DEFAULT_CONS_RPC，如未设置则必须输入）: " input_cons_rpc
        GLOBAL_CONS_RPC=${input_cons_rpc:-${DEFAULT_CONS_RPC:-}}
        if [[ -z "$GLOBAL_CONS_RPC" ]]; then
            print_error "Consensus RPC 未提供。请设置环境变量或输入。"
            exit 1
        fi
    fi
    if [[ -z "$GLOBAL_FUNDING_PRIVATE_KEY" ]]; then
        read -p "Funding 私钥 (以 0x 开头): " input_funding_pk  # 不隐藏输入
        if [[ -z "$input_funding_pk" || ! "$input_funding_pk" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
            print_error "Funding 私钥格式无效（需 0x + 64 位 hex）"
            exit 1
        fi
        GLOBAL_FUNDING_PRIVATE_KEY="$input_funding_pk"
    fi
    print_success "全局配置加载: RPC=$GLOBAL_ETH_RPC, Funding PK=OK"
}

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

# ------------------ 验证 Aztec 地址格式 (0x + 64 hex) ------------------
validate_aztec_address() {
    local address=$1
    if [[ ! "$address" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "无效 Aztec 地址格式（需 0x + 64 位 hex，如零地址）"
        return 1
    fi
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

    print_info "发送 STK Approve（spender: $ROLLUP_CONTRACT，200k STAKE）"

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
    print_info "Aztec 节点安装/启动 (v$SCRIPT_VERSION, 兼容2.1.2)"
    print_warning "注意：2.1.2更新需重新注册验证者（选项6）"
    if ! check_environment; then
        print_error "环境检查失败"
        read -p "按任意键继续..."
        return 1
    fi

    # 在这里获取全局配置（如果未设）
    get_global_config

    echo
    echo "密钥模式：1. 新生成  2. 加载 keystore"
    read -p "选择 (1-2): " mode_choice

    local new_eth_key new_bls_key new_address keystore_path FEE_RECIPIENT MNEMONIC_CMD=""
    case $mode_choice in
        1)
            rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
            read -p "Fee Recipient Aztec 地址（回车使用零地址 $ZERO_AZTEC_ADDR；需 0x + 64 hex）: " FEE_RECIPIENT_INPUT
            FEE_RECIPIENT=${FEE_RECIPIENT_INPUT:-$ZERO_AZTEC_ADDR}
            if ! validate_aztec_address "$FEE_RECIPIENT"; then
                print_error "Fee Recipient 无效，回退到零地址"
                FEE_RECIPIENT="$ZERO_AZTEC_ADDR"
                print_warning "使用零地址: $FEE_RECIPIENT (占位符)"
            fi
            print_info "使用 Fee Recipient: $FEE_RECIPIENT"
            read -p "助记词 (12/24词，BIP39；回车随机生成，用于重现BLS/ETH keys): " MNEMONIC_INPUT
            if [[ -n "$MNEMONIC_INPUT" ]]; then
                MNEMONIC_CMD="--mnemonic \"$MNEMONIC_INPUT\""
                print_warning "使用助记词生成（保存好以防丢失！）"
            fi
            aztec validator-keys new --fee-recipient "$FEE_RECIPIENT" $MNEMONIC_CMD || { print_error "生成键失败"; read -p "按任意键继续..."; return 1; }
            if [[ ! -f "$DEFAULT_KEYSTORE" ]]; then
                print_error "新生成后未找到 keystore: $DEFAULT_KEYSTORE"
                read -p "按任意键继续..."
                return 1
            fi
            keystore_path="$DEFAULT_KEYSTORE"
            print_warning "提示：后续编辑 keystore 的 'feeRecipient' 为自定义 Aztec 地址"
            echo "命令: jq '.validators[0].feeRecipient = \"你的Aztec地址\"' $DEFAULT_KEYSTORE > temp.json && mv temp.json $DEFAULT_KEYSTORE"
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
ETHEREUM_HOSTS=$GLOBAL_ETH_RPC
L1_CONSENSUS_HOST_URLS=$GLOBAL_CONS_RPC
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
      ETHEREUM_HOSTS: $GLOBAL_ETH_RPC
      L1_CONSENSUS_HOST_URLS: $GLOBAL_CONS_RPC
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
    sleep 10
    docker logs aztec-sequencer --tail 20 || true

    if curl -s --max-time 5 http://localhost:8080/status >/dev/null 2>&1; then
        print_success "节点启动成功 (2.1.2)"
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
    print_info "更新节点镜像并重启 (拉取2.1.2)"
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
    print_success "更新并重启完成 (2.1.2)"
    sleep 10
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
    print_info "验证者注册（手动模式，兼容2.1.2 rejoin）"
    if ! check_environment; then
        print_error "环境检查失败"
        read -p "按任意键继续..."
        return 1
    fi

    # 在这里获取全局配置（如果未设）
    get_global_config

    local eth_rpc="$GLOBAL_ETH_RPC"
    local funding_private_key="$GLOBAL_FUNDING_PRIVATE_KEY"
    local funding_address
    funding_address=$(generate_address_from_private_key "$funding_private_key") || {
        read -p "按任意键继续..."
        return 1
    }
    print_info "Funding 地址: $funding_address"

    # 检查 keystore 和提取值
    if [[ ! -f "$KEY_DIR/key1.json" ]]; then
        print_error "keystore 未找到 ($KEY_DIR/key1.json)，请先运行选项1生成"
        read -p "按任意键继续..."
        return 1
    fi
    local attester_eth_pk bls_secret_key attester_addr
    attester_eth_pk=$(jq -r '.validators[0].attester.eth' "$KEY_DIR/key1.json") || { print_error "无法读取 ETH 私钥"; return 1; }
    bls_secret_key=$(jq -r '.validators[0].attester.bls' "$KEY_DIR/key1.json") || { print_error "无法读取 BLS 私钥"; return 1; }
    attester_addr=$(generate_address_from_private_key "$attester_eth_pk") || { print_error "无法生成 attester 地址"; return 1; }
    local withdrawer_addr="$attester_addr"  # 默认相同

    print_info "从 keystore 提取: Attester=$attester_addr, BLS PK=OK"

    # 检查授权
    print_info "检查 STK 授权..."
    local allowance_hex allowance_dec
    allowance_hex=$(check_stk_allowance "$eth_rpc" "$funding_address") || {
        read -p "按任意键继续..."
        return 1
    }
    allowance_dec=$((16#${allowance_hex#0x})) 2>/dev/null || allowance_dec=0
    allowance_stk=$(echo "scale=0; $allowance_dec / 1000000000000000000" | bc 2>/dev/null || echo "0")

    print_info "当前授权: $allowance_stk STK (需 200k STK)"

    if [ "$allowance_dec" -lt "$STAKE_AMOUNT" ]; then
        print_warning "授权不足，尝试发送 approve..."
        if ! send_stk_approve "$eth_rpc" "$funding_private_key"; then
            print_error "approve 失败，请手动检查或重试"
            read -p "按任意键继续..."
            return 1
        fi
    else
        print_success "授权充足"
    fi

    # 显示手动命令模板
    print_info "复制以下命令运行（替换为你的值，如果需要自定义 withdrawer）："
    echo ""
    echo "aztec add-l1-validator \\"
    echo "  --l1-rpc-urls \"$eth_rpc\" \\"
    echo "  --network testnet \\"
    echo "  --private-key \"$funding_private_key\" \\"
    echo "  --attester \"$attester_addr\" \\"
    echo "  --withdrawer \"$withdrawer_addr\" \\"
    echo "  --bls-secret-key \"$bls_secret_key\" \\"
    echo "  --rollup $ROLLUP_CONTRACT"
    echo ""
    print_warning "运行前确认：Funding PK 用于支付 stake，新 attester 用于验证。"
    read -p "运行命令后，按 Enter 继续（检查 Tx）..."

    print_success "注册命令已生成！可在 dashtec 查看: $DASHTEC_URL/validator/$attester_addr"
    echo ""
    print_warning "2.1.2新要求：设置Publisher或为Attester ($attester_addr) fund sepETH！"
    print_info "指南: $PUBLISHER_GUIDE"
    echo "转ETH命令: cast send $attester_addr --value 0.1ether --private-key $funding_private_key --rpc-url $eth_rpc"
    read -p "按任意键返回主菜单..."
}

# ------------------ 主菜单 ------------------
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Aztec 节点管理 $SCRIPT_VERSION"
        echo "========================================"
        echo "1. 安装/启动节点 (兼容2.1.2) - 会提示输入 RPC/PK"
        echo "2. 查看日志/状态"
        echo "3. 更新/重启 (pull 2.1.2)"
        echo "4. 性能监控"
        echo "5. 停止节点"
        echo "6. 注册验证者 (手动模板) - 会提示输入 RPC/PK"
        echo "7. 退出"
        echo "========================================"
        echo "提示: 2.1.2需rejoin！已airdrop 200k STAKE。"
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
