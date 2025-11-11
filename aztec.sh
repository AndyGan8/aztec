#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Aztec 节点管理脚本（改进版 v2）
# - 不在脚本中硬编码默认 RPC 地址给终端提示
# - 支持从环境变量读取 DEFAULT_ETH_RPC / DEFAULT_CONS_RPC
# - 更安全的交互提示与输入校验
# - 保持原有功能：安装/启动、查看日志、更新、监控、手动注册验证者
# ==================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行"
  exit 1
fi

# ------------------ 可配置项（不会用于提示默认值） ------------------
AZTEC_DIR="/root/aztec-sequencer"
DATA_DIR="$AZTEC_DIR/data"
KEY_DIR="$AZTEC_DIR/keys"
AZTEC_IMAGE="aztecprotocol/aztec:latest"

ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
STAKE_AMOUNT=200000000000000000000  # 200 STK (18 decimals)
DASHTEC_URL="https://dashtec.xyz"
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

# 说明：脚本不会在提示中直接显示默认 RPC 值，以免将它们泄露给运行脚本的用户界面。
# 如果你希望有默认值，请在运行脚本前在环境变量中导出：
#   export DEFAULT_ETH_RPC="https://rpc.sepolia.org"
#   export DEFAULT_CONS_RPC="https://ethereum-sepolia-beacon-api.publicnode.com"
# 只有在环境变量存在时，按回车将使用这些默认。

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
        print_error "缺少命令: ${missing[*]}"
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
        return 1
    fi
    cast wallet address --private-key "0x$private_key" 2>/dev/null || true
}

# ------------------ 检查 STK 授权 ------------------
# 返回 hex string（0x...）
check_stk_allowance() {
    local rpc_url=$1
    local funding_address=$2

    # owner: funding_address (left padded), spender: ROLLUP_CONTRACT
    local owner_padded=$(printf "%064s" "${funding_address#0x}" | tr ' ' '0')
    local spender_padded=$(printf "%064s" "${ROLLUP_CONTRACT#0x}" | tr ' ' '0')

    local data="0xdd62ed3e${owner_padded}${spender_padded}"

    local result
    result=$(curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$STAKE_TOKEN\",\"data\":\"$data\"},\"latest\"],\"id\":1}" "$rpc_url" | jq -r '.result // "0x0"')
    echo "$result"
}

# ------------------ 发送 STK Approve ------------------
send_stk_approve() {
    local rpc_url=$1
    local funding_private_key=$2

    print_info "发送 STK Approve（approve spender: $ROLLUP_CONTRACT）"

    local approve_tx
    approve_tx=$(cast send "$STAKE_TOKEN" "approve(address,uint256)" "$ROLLUP_CONTRACT" "$STAKE_AMOUNT" --private-key "$funding_private_key" --rpc-url "$rpc_url" --gas-limit 200000 --json 2>&1) || true

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
        # 尝试从文本中提取 tx hash/status
        local grep_status=$(echo "$approve_tx" | grep -i "status" | head -1 | sed -E 's/.*status[^0-9]*([0-9x]+).*/\1/' | tr -d ' ')
        local grep_hash=$(echo "$approve_tx" | grep -i "transactionHash" | head -1 | sed -E 's/.*transactionHash[^0-9a-f]*([0-9a-fx]+).*/\1/')
        if [[ "$grep_status" == "1" || "$grep_status" == "0x1" ]]; then
            print_success "Approve 成功！Tx: ${grep_hash:-unknown}"
            sleep 25
            return 0
        fi
        print_error "Approve 发送失败：$approve_tx"
        return 1
    fi
}

# ------------------ 容器清理 ------------------
cleanup_existing_containers() {
    print_info "清理现有容器..."
    if docker ps -a --format '{{.Names}}' | grep -q '^aztec-sequencer$'; then
        docker stop aztec-sequencer 2>/dev/null || true
        sleep 2
        docker rm aztec-sequencer 2>/dev/null || true
        print_success "容器清理完成"
    fi
    docker network rm aztec 2>/dev/null || true
}

# ------------------ 安装并启动节点 ------------------
install_and_start_node() {
    clear
    print_info "Aztec 节点安装/启动"
    if ! check_environment; then
        print_error "环境检查失败"
        read -p "按任意键继续..."
        return 1
    fi

    # 重要：默认值来自环境变量（如果存在），脚本提示中不会显示默认具体值
    local DEFAULT_ETH_RPC_ENV=${DEFAULT_ETH_RPC:-}
    local DEFAULT_CONS_RPC_ENV=${DEFAULT_CONS_RPC:-}

    read -p "L1 RPC（回车使用环境变量 DEFAULT_ETH_RPC，如未设置则必须输入）: " ETH_RPC
    ETH_RPC=${ETH_RPC:-$DEFAULT_ETH_RPC_ENV}
    if [[ -z "$ETH_RPC" ]]; then
        print_error "L1 RPC 未提供。请设置环境变量 DEFAULT_ETH_RPC 或在提示中输入。"
        return 1
    fi

    read -p "Beacon/Consensus RPC（回车使用环境变量 DEFAULT_CONS_RPC，如未设置则必须输入）: " CONS_RPC
    CONS_RPC=${CONS_RPC:-$DEFAULT_CONS_RPC_ENV}
    if [[ -z "$CONS_RPC" ]]; then
        print_error "Consensus RPC 未提供。请设置环境变量 DEFAULT_CONS_RPC 或在提示中输入。"
        return 1
    fi

    read -sp "Funding 私钥 (以 0x 开头): " FUNDING_PRIVATE_KEY
    echo
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "Funding 私钥格式无效"
        return 1
    fi

    local funding_address
    funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY") || funding_address=""
    print_info "Funding 地址: ${funding_address:-(无法解析)}"

    echo
    echo "密钥模式：1. 新生成  2. 加载 keystore"
    read -p "选择 (1-2): " mode_choice

    local new_eth_key new_bls_key new_address
    case $mode_choice in
        1)
            rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
            aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000 || { print_error "生成键失败"; return 1; }
            if [[ ! -f "$DEFAULT_KEYSTORE" ]]; then
                print_error "新生成后未找到 keystore: $DEFAULT_KEYSTORE"
                return 1
            fi
            new_eth_key=$(jq -r '.validators[0].attester.eth' "$DEFAULT_KEYSTORE")
            new_bls_key=$(jq -r '.validators[0].attester.bls' "$DEFAULT_KEYSTORE")
            new_address=$(generate_address_from_private_key "$new_eth_key") || new_address=""
            mkdir -p "$KEY_DIR"
            cp "$DEFAULT_KEYSTORE" "$KEY_DIR/key1.json"
            chmod 600 "$KEY_DIR/key1.json"
            print_success "新地址: ${new_address:-(无法解析)} (keystore 已保存到 $KEY_DIR/key1.json)"
            ;;
        2)
            read -p "keystore 路径 (回车使用 $DEFAULT_KEYSTORE): " keystore_path
            keystore_path=${keystore_path:-$DEFAULT_KEYSTORE}
            if [[ ! -f "$keystore_path" ]]; then
                print_error "keystore 文件不存在: $keystore_path"
                return 1
            fi
            new_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path")
            new_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path")
            new_address=$(generate_address_from_private_key "$new_eth_key") || new_address=""
            mkdir -p "$KEY_DIR"
            cp "$keystore_path" "$KEY_DIR/key1.json"
            chmod 600 "$KEY_DIR/key1.json"
            print_success "加载 keystore 成功: ${new_address:-(无法解析)}"
            ;;
        *) print_error "无效选择"; return 1 ;;
    esac

    cleanup_existing_containers
    mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"

    local public_ip
    public_ip=$(curl -s --connect-timeout 5 ipv4.icanhazip.com || echo "127.0.0.1")

    # 写 .env（文件内含配置，但脚本中不会把默认 RPC 明文提示给操作者）
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

    # docker-compose
    cat > "$AZTEC_DIR/docker-compose.yml" <<EOF
version: '3.8'
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

    print_info "启动容器..."
    cd "$AZTEC_DIR"
    docker compose up -d || { print_error "docker 启动失败"; return 1; }
    sleep 8
    docker logs aztec-sequencer --tail 20 || true

    if curl -s http://localhost:8080/status >/dev/null 2>&1; then
        print_success "节点启动成功"
    else
        print_warning "节点可能仍在初始化，稍后检查日志"
    fi
    echo "查看日志: docker logs -f aztec-sequencer"
}

# ------------------ 查看日志与状态 ------------------
view_logs_and_status() {
    clear
    print_info "节点日志和状态"
    if docker ps | grep -q aztec-sequencer; then
        echo "✅ 运行中"
        docker logs aztec-sequencer --tail 50
        echo ""
        curl -s http://localhost:8080/status || echo "API 未响应"
    else
        echo "❌ 未运行"
    fi
    echo ""
    read -p "按回车返回主菜单..." _
}}' | grep -q '^aztec-sequencer$'; then
        echo "✅ 容器运行中"
        docker logs aztec-sequencer --tail 80
        echo "\nAPI status:"
        curl -s http://localhost:8080/status || echo "API 未响应"
    else
        echo "❌ 容器未运行"
    fi
}

# ------------------ 更新并重启 ------------------
update_and_restart_node() {
    clear
    print_info "更新节点镜像并重启"
    if [[ ! -d "$AZTEC_DIR" ]]; then
        print_error "目录不存在: $AZTEC_DIR"
        return 1
    fi
    cd "$AZTEC_DIR"
    docker compose pull || print_warning "pull 失败，继续尝试 restart"
    docker compose down || true
    docker compose up -d || { print_error "重启失败"; return 1; }
    print_success "更新并重启完成"
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
    read -p "按回车返回主菜单..." _
}

# ------------------ 手动注册验证者 ------------------
register_validator_direct() {
    clear
    print_info "验证者注册（手动）"
    if ! check_environment; then
        print_error "环境检查失败"
        return 1
    fi

    # 使用环境变量作为“隐式默认”，提示中不显示默认具体地址
    local DEFAULT_ETH_RPC_ENV=${DEFAULT_ETH_RPC:-}

    read -p "L1 RPC（回车使用环境变量 DEFAULT_ETH_RPC，如未设置则必须输入）: " ETH_RPC
    ETH_RPC=${ETH_RPC:-$DEFAULT_ETH_RPC_ENV}
    if [[ -z "$ETH_RPC" ]]; then
        print_error "L1 RPC 未提供"
        return 1
    fi

    read -sp "Funding 私钥 (0x...): " FUNDING_PRIVATE_KEY
    echo
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "Funding 私钥格式错误"
        return 1
    fi

    read -sp "BLS 私钥 (0x...): " BLS_SECRET_KEY
    echo
    if [[ -z "$BLS_SECRET_KEY" || ! "$BLS_SECRET_KEY" =~ ^0x[a-fA-F0-9]{64,128}$ ]]; then
        print_error "BLS 私钥格式错误"
        return 1
    fi

    local funding_address
    funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY") || funding_address=""
    print_info "Funding 地址: ${funding_address:-(无法解析)}"

    print_info "检查 STK 授权..."
    local allowance_hex
    allowance_hex=$(check_stk_allowance "$ETH_RPC" "$funding_address")
    local allowance_dec
    allowance_dec=$((16#${allowance_hex#0x})) 2>/dev/null || allowance_dec=0
    local required_dec=$STAKE_AMOUNT

    # 转换为 STK 单位用于展示（整数部分）
    local allowance_stk
    allowance_stk=$(echo "$allowance_dec / 1000000000000000000" | bc 2>/dev/null || echo "0")
    print_info "当前授权: $allowance_stk STK"

    if [ "$allowance_dec" -lt "$required_dec" ]; then
        print_warning "授权不足，尝试发送 approve..."
        if ! send_stk_approve "$ETH_RPC" "$FUNDING_PRIVATE_KEY"; then
            print_error "approve 失败，请手动检查或重试"
            return 1
        fi
    else
        print_success "授权充足"
    fi

    # 这里使用固定 attester/withdrawer（如需自定义可修改）
    local ATTESTER="0x188df4682a70262bdb316b02c56b31eb53e7c0cb"
    local WITHDRAWER="$ATTESTER"

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
}

# ------------------ 主菜单 ------------------
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
        echo "6. 注册验证者 (手动)"
        echo ""
        read -p "选择 (1-6): " choice
        case $choice in
            1) install_and_start_node ;;
            2) view_logs_and_status ;;
            3) update_and_restart_node ;;
            4) monitor_performance ;;
            5) exit 0 ;;
            6) register_validator_direct ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

main_menu
