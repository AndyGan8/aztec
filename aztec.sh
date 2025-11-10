#!/usr/bin/env bash
set -euo pipefail

########################################
# 基础检查
########################################
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行"
  exit 1
fi

########################################
# 全局变量
########################################
AZTEC_DIR="/root/aztec-sequencer"
DATA_DIR="$AZTEC_DIR/data"
KEY_DIR="$AZTEC_DIR/keys"
AZTEC_IMAGE="aztecprotocol/aztec:latest"

ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
STAKE_AMOUNT=200000000000000000000     # 200 STK

DASHTEC_URL="https://dashtec.xyz"
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

########################################
# UI 输出
########################################
log_info()    { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
log_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
log_warn()    { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

########################################
# 环境检查
########################################
check_environment() {
    log_info "检查依赖环境..."

    export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"

    local required=(docker jq cast aztec bc)
    local missing=""

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null; then
            missing="$missing $cmd"
        fi
    done

    if [[ -n "$missing" ]]; then
        log_error "缺少依赖: $missing"
        return 1
    fi

    log_success "依赖检查通过"
    return 0
}

########################################
# 工具: 私钥生成地址
########################################
generate_address_from_private_key() {
    local key="${1#0x}"
    [[ ${#key} -ne 64 ]] && return 1
    cast wallet address --private-key "0x$key" 2>/dev/null || true
}

########################################
# 工具: 清理容器
########################################
cleanup_existing_containers() {
    log_info "清理旧容器..."

    if docker ps -a | grep -q aztec-sequencer; then
        docker stop aztec-sequencer >/dev/null 2>&1 || true
        docker rm aztec-sequencer >/dev/null 2>&1 || true
        log_success "已清理旧容器"
    fi

    docker network rm aztec >/dev/null 2>&1 || true
}

########################################
# 工具: 检查 STK 授权
########################################
check_stk_allowance() {
    local rpc="$1"
    local owner="$2"

    local data="0xdd62ed3e$(printf "%064x" 0x${owner#0x})$(printf "%064x" 0x${ROLLUP_CONTRACT#0x})"

    local result
    result=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$STAKE_TOKEN\",\"data\":\"$data\"},\"latest\"],\"id\":1}" \
        "$rpc" | jq -r '.result')

    echo "${result:-0x0}"
}

########################################
# 工具: 发送 STK Approve
########################################
send_stk_approve() {
    local rpc="$1"
    local key="$2"

    log_info "执行 STK 授权..."

    local tx_json
    tx_json=$(cast send "$STAKE_TOKEN" "approve(address,uint256)" \
        "$ROLLUP_CONTRACT" "$STAKE_AMOUNT" \
        --private-key "$key" \
        --rpc-url "$rpc" \
        --gas-limit 200000 \
        --json 2>/dev/null || true)

    if jq -e . >/dev/null 2>&1 <<<"$tx_json"; then
        local status tx
        status=$(jq -r '.status' <<<"$tx_json")
        tx=$(jq -r '.transactionHash' <<<"$tx_json")

        if [[ $status == "1" || $status == "0x1" ]]; then
            log_success "授权成功 Tx: $tx"
            sleep 25
            return 0
        fi
    fi

    log_error "授权失败"
    return 1
}

########################################
# 安装并启动节点
########################################
install_and_start_node() {
    clear
    check_environment || return 1

    log_info "Aztec 测试网节点安装"

    read -p "L1 RPC [默认 https://rpc.sepolia.org]: " ETH_RPC
    ETH_RPC=${ETH_RPC:-"https://rpc.sepolia.org"}

    read -p "Beacon RPC [默认 https://ethereum-sepolia-beacon-api.publicnode.com]: " CONS_RPC
    CONS_RPC=${CONS_RPC:-"https://ethereum-sepolia-beacon-api.publicnode.com"}

    read -sp "Funding 私钥 (0x...): " FUND_KEY
    echo
    [[ ! $FUND_KEY =~ ^0x[a-fA-F0-9]{64}$ ]] && log_error "私钥格式错误" && return 1

    local fund_address
    fund_address=$(generate_address_from_private_key "$FUND_KEY")

    log_info "Funding 地址: $fund_address"

    echo
    echo "密钥模式: 1. 新生成 2. 加载 Keystore"
    read -p "选择 (1/2): " mode

    local key_eth key_bls new_addr keystore_path

    case $mode in
        1)
            rm -rf "$HOME/.aztec/keystore"
            aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000 \
                || { log_error "生成失败"; return 1; }

            key_eth=$(jq -r '.validators[0].attester.eth' "$DEFAULT_KEYSTORE")
            key_bls=$(jq -r '.validators[0].attester.bls' "$DEFAULT_KEYSTORE")
            new_addr=$(generate_address_from_private_key "$key_eth")

            mkdir -p "$KEY_DIR"
            cp "$DEFAULT_KEYSTORE" "$KEY_DIR/key1.json"
            chmod 600 "$KEY_DIR/key1.json"

            log_success "生成成功: $new_addr"
            ;;
        2)
            read -p "Keystore 路径: " keystore_path
            [[ ! -f $keystore_path ]] && log_error "文件不存在" && return 1

            key_eth=$(jq -r '.validators[0].attester.eth' "$keystore_path")
            key_bls=$(jq -r '.validators[0].attester.bls' "$keystore_path")
            new_addr=$(generate_address_from_private_key "$key_eth")

            mkdir -p "$KEY_DIR"
            cp "$keystore_path" "$KEY_DIR/key1.json"
            chmod 600 "$KEY_DIR/key1.json"

            log_success "加载成功: $new_addr"
            ;;
        *)
            log_error "无效选择"
            return 1
            ;;
    esac

    cleanup_existing_containers
    mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"

    local public_ip
    public_ip=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

    ########################################
    # 写入 .env
    ########################################
    cat > "$AZTEC_DIR/.env" <<EOF
LOG_LEVEL=debug
ETHEREUM_HOSTS=$ETH_RPC
L1_CONSENSUS_HOST_URLS=$CONS_RPC
P2P_IP=$public_ip
P2P_PORT=40400
AZTEC_PORT=8080
AZTEC_ADMIN_PORT=8880
VALIDATOR_PRIVATE_KEY=$key_eth
COINBASE=$new_addr
EOF

    ########################################
    # 写入 docker-compose
    ########################################
    cat > "$AZTEC_DIR/docker-compose.yml" <<EOF
services:
  aztec-sequencer:
    image: "$AZTEC_IMAGE"
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
      ETHEREUM_HOSTS: $ETH_RPC
      L1_CONSENSUS_HOST_URLS: $CONS_RPC
      P2P_IP: $public_ip
      P2P_PORT: 40400
      AZTEC_PORT: 8080
      AZTEC_ADMIN_PORT: 8880
      VALIDATOR_PRIVATE_KEY: $key_eth
      COINBASE: $new_addr
    entrypoint: >
      node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start
      --node --archiver --sequencer --network testnet
    networks:
      - aztec
    restart: always

networks:
  aztec:
    name: aztec
EOF

    log_info "启动容器..."
    cd "$AZTEC_DIR"

    docker compose up -d
    sleep 8

    docker logs aztec-sequencer --tail 20 || true

    if curl -s http://localhost:8080/status >/dev/null; then
        log_success "节点启动成功"
    else
        log_warn "节点正在启动，请稍等"
    fi

    read -p "按任意键继续..."
}

########################################
# 日志
########################################
view_logs_and_status() {
    clear
    if docker ps | grep -q aztec-sequencer; then
        log_success "正在运行"
        docker logs aztec-sequencer --tail 50
        curl -s http://localhost:8080/status || echo "API 未响应"
    else
        log_error "服务未运行"
    fi
    read -p "按任意键继续..."
}

########################################
# 更新
########################################
update_and_restart_node() {
    clear
    cd "$AZTEC_DIR" || { log_error "目录不存在"; return; }
    docker compose pull
    docker compose down
    docker compose up -d
    log_success "更新完成"
    read -p "按任意键继续..."
}

########################################
# 性能监控
########################################
monitor_performance() {
    clear
    free -h
    echo
    df -h
    read -p "按任意键继续..."
}

########################################
# 验证者注册（手动）
########################################
register_validator_direct() {
    clear
    check_environment || return 1

    log_info "验证者注册 (手动版本)"

    read -p "L1 RPC [默认 http://94.72.112.218:8545]: " RPC
    RPC=${RPC:-"http://94.72.112.218:8545"}

    read -sp "Funding 私钥: " FUND_KEY
    echo
    read -sp "BLS 私钥: " BLS_KEY
    echo

    local fund_addr
    fund_addr=$(generate_address_from_private_key "$FUND_KEY")

    log_info "Funding 地址: $fund_addr"

    # 检查授权
    local allowance
    allowance=$(check_stk_allowance "$RPC" "$fund_addr")
    local allowance_dec
    allowance_dec=$((16#${allowance#0x}))

    if (( allowance_dec < STAKE_AMOUNT )); then
        log_warn "授权不足，执行 approve..."
        send_stk_approve "$RPC" "$FUND_KEY" || return 1
    else
        log_success "授权充足"
    fi

    local ATT_ADDR="0x188df4682a70262bdb316b02c56b31eb53e7c0cb"
    local WITH_ADDR="0x188df4682a70262bdb316b02c56b31eb53e7c0cb"

    read -p "按回车确认注册..."

    aztec add-l1-validator \
        --l1-rpc-urls "$RPC" \
        --network testnet \
        --private-key "$FUND_KEY" \
        --attester "$ATT_ADDR" \
        --withdrawer "$WITH_ADDR" \
        --bls-secret-key "$BLS_KEY" \
        --rollup "$ROLLUP_CONTRACT" \
        && log_success "注册成功: $DASHTEC_URL/validator/$ATT_ADDR"

    read -p "按任意键继续..."
}

########################################
# 主菜单
########################################
main_menu() {
    while true; do
        clear
        cat <<EOF
========================================
            Aztec 节点管理
========================================
1. 安装并启动节点
2. 查看日志/状态
3. 更新并重启
4. 性能监控
5. 注册验证者 (手动)
6. 退出
EOF
        read -p "选择 (1-6): " opt
        case "$opt" in
            1) install_and_start_node ;;
            2) view_logs_and_status ;;
            3) update_and_restart_node ;;
            4) monitor_performance ;;
            5) register_validator_direct ;;
            6) exit 0 ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

main_menu
