#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行"
  exit 1
fi

# ==================== 关键修复：预先设置环境变量和定义命令路径 ====================
# 确保 PATH 包含必要的目录
export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"

# ==================== 常量 ====================
AZTEC_DIR="/root/aztec-sequencer"
DATA_DIR="/root/aztec-sequencer/data"
KEY_DIR="/root/aztec-sequencer/keys"
AZTEC_IMAGE="aztecprotocol/aztec:latest"
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
STAKE_TOKEN="0x139d2a7a0881e16332d7D1F8DB383A4507E1Ea7A"
DASHTEC_URL="https://dashtec.xyz"
STAKE_AMOUNT=200000000000000000000000  # 200k wei (18 decimals)
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

# ==================== 打印函数 ====================
print_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ==================== 重试函数 ====================
retry_cmd() {
  local max_attempts=$1; shift
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if "$@"; then return 0; fi
    print_warning "命令失败 (尝试 $attempt/$max_attempts)，重试..."
    sleep $((attempt * 2))
    ((attempt++))
  done
  print_error "命令失败 $max_attempts 次"
  return 1
}

# ==================== 清理现有容器 ====================
cleanup_existing_containers() {
    print_info "检查并清理现有容器..."
    
    # 检查是否有正在运行的 aztec-sequencer 容器
    if docker ps -a | grep -q aztec-sequencer; then
        print_warning "发现现有的 aztec-sequencer 容器，正在清理..."
        
        # 停止容器
        if docker ps | grep -q aztec-sequencer; then
            docker stop aztec-sequencer
            sleep 3
        fi
        
        # 删除容器
        docker rm aztec-sequencer 2>/dev/null || true
        print_success "现有容器已清理"
    else
        print_info "没有找到现有的 aztec-sequencer 容器"
    fi
    
    # 清理网络（如果存在）
    if docker network ls | grep -q aztec; then
        print_info "清理现有网络..."
        docker network rm aztec 2>/dev/null || true
    fi
}

# ==================== 修复的 Aztec CLI 安装 ====================
install_aztec_cli() {
    print_info "安装 Aztec CLI..."
    
    # 清理可能存在的旧安装
    rm -rf "$HOME/.aztec" 2>/dev/null || true
    rm -rf /tmp/aztec_install 2>/dev/null || true
    mkdir -p /tmp/aztec_install
    
    # 方法1: 使用官方安装脚本（修复版）
    print_info "方法1: 使用官方安装脚本..."
    if ! curl -fsSL https://install.aztec.network | bash -s -- -y; then
        print_warning "官方安装脚本失败，尝试方法2..."
        
        # 方法2: 手动安装
        print_info "方法2: 手动安装..."
        local aztec_version="2.1.2"
        
        # 检测系统架构
        local arch
        case $(uname -m) in
            x86_64) arch="x64" ;;
            aarch64) arch="arm64" ;;
            *) arch="x64" ;;
        esac
        
        local os
        case $(uname -s) in
            Linux) os="linux" ;;
            Darwin) os="darwin" ;;
            *) os="linux" ;;
        esac
        
        # 下载特定版本的 Aztec
        local download_url="https://aztec-sequencer-releases.s3.amazonaws.com/aztec-${aztec_version}-${os}-${arch}.tar.gz"
        print_info "下载 Aztec CLI: $download_url"
        
        if curl -fsSL -o /tmp/aztec_install/aztec.tar.gz "$download_url"; then
            # 解压并安装
            tar -xzf /tmp/aztec_install/aztec.tar.gz -C /tmp/aztec_install/
            
            # 创建目录并移动文件
            mkdir -p "$HOME/.aztec/bin"
            mv /tmp/aztec_install/aztec "$HOME/.aztec/bin/"
            chmod +x "$HOME/.aztec/bin/aztec"
            
            # 设置环境变量
            export PATH="$HOME/.aztec/bin:$PATH"
            echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
            echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.profile
            
            # 验证安装
            if "$HOME/.aztec/bin/aztec" --version >/dev/null 2>&1; then
                print_success "Aztec CLI 手动安装成功"
                return 0
            fi
        else
            print_warning "方法2失败，尝试方法3..."
        fi
    else
        # 官方安装脚本成功，设置环境变量
        export PATH="$HOME/.aztec/bin:$PATH"
        echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
        echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.profile
        
        # 验证安装
        if command -v aztec >/dev/null 2>&1; then
            print_success "Aztec CLI 官方安装成功"
            return 0
        fi
    fi
    
    # 方法3: 使用 npm 安装（如果可用）
    print_info "方法3: 尝试使用 npm 安装..."
    if command -v npm >/dev/null 2>&1; then
        npm install -g @aztec/cli@2.1.2
        if command -v aztec >/dev/null 2>&1; then
            print_success "Aztec CLI npm 安装成功"
            return 0
        fi
    fi
    
    # 方法4: 从 GitHub 发布页面下载
    print_info "方法4: 从 GitHub 下载..."
    local github_url="https://github.com/AztecProtocol/aztec-packages/releases/download/aztec-cli-v2.1.2/aztec-2.1.2-linux-x64.tar.gz"
    if curl -fsSL -L -o /tmp/aztec_install/aztec_github.tar.gz "$github_url"; then
        tar -xzf /tmp/aztec_install/aztec_github.tar.gz -C /tmp/aztec_install/
        mkdir -p "$HOME/.aztec/bin"
        find /tmp/aztec_install -name "aztec" -type f -exec mv {} "$HOME/.aztec/bin/" \;
        chmod +x "$HOME/.aztec/bin/aztec"
        
        export PATH="$HOME/.aztec/bin:$PATH"
        echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
        echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.profile
        
        if "$HOME/.aztec/bin/aztec" --version >/dev/null 2>&1; then
            print_success "Aztec CLI GitHub 安装成功"
            return 0
        fi
    fi
    
    print_error "所有 Aztec CLI 安装方法都失败了"
    echo "请手动安装:"
    echo "1. 访问: https://docs.aztec.network/dev_docs/cli/install"
    echo "2. 运行: curl -fsSL https://install.aztec.network | bash"
    echo "3. 或者: npm install -g @aztec/cli@2.1.2"
    return 1
}

# ==================== 安装 Foundry ====================
install_foundry() {
    print_info "安装 Foundry..."
    
    # 清理可能存在的旧安装
    rm -rf "$HOME/.foundry" 2>/dev/null || true
    
    # 安装 Foundry
    curl -L --retry 3 --connect-timeout 30 https://foundry.paradigm.xyz | bash
    
    # 确保路径存在
    export PATH="$HOME/.foundry/bin:$PATH"
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.profile
    
    # 等待一下确保安装完成
    sleep 3
    
    # 运行 foundryup
    if [[ -f "$HOME/.foundry/bin/foundryup" ]]; then
        "$HOME/.foundry/bin/foundryup"
    elif command -v foundryup >/dev/null 2>&1; then
        foundryup
    else
        print_error "Foundry 安装后 foundryup 命令仍不可用"
        return 1
    fi
    
    if ! command -v cast >/dev/null 2>&1; then
        print_error "Foundry 安装后 cast 命令仍不可用"
        return 1
    fi
    
    print_success "Foundry 安装完成: $(cast --version 2>/dev/null || echo '未知版本')"
    return 0
}

# ==================== 安装系统依赖 ====================
install_dependencies() {
    print_info "安装系统依赖..."
    
    print_info "更新系统包..."
    retry_cmd 3 apt update -y && apt upgrade -y
    
    print_info "安装基础工具..."
    apt install -y curl jq iptables build-essential git wget lz4 make gcc nano \
        automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev \
        libleveldb-dev tar clang bsdmainutils ncdu unzip ca-certificates \
        gnupg lsb-release bc
    
    # 安装 Docker
    if ! command -v docker >/dev/null 2>&1; then
        print_info "安装 Docker..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable docker
        systemctl start docker
        usermod -aG docker root
        sleep 5
        docker run --rm hello-world >/dev/null 2>&1 || print_warning "Docker 测试失败，请手动检查"
        print_success "Docker 安装完成"
    else
        print_info "Docker 已存在"
    fi
}

# ==================== 环境检查 ====================
check_environment() {
    print_info "检查环境..."
    
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
        print_warning "缺少命令: ${missing[*]}，开始安装..."
        install_dependencies
        
        # 安装 Foundry 如果需要
        if [[ " ${missing[*]} " == *"cast"* ]]; then
            if ! install_foundry; then
                print_error "Foundry 安装失败"
                return 1
            fi
        fi
        
        # 安装 Aztec CLI 如果需要
        if [[ " ${missing[*]} " == *"aztec"* ]]; then
            if ! install_aztec_cli; then
                print_error "Aztec CLI 安装失败"
                return 1
            fi
        fi
    fi
    
    # 最终验证
    print_info "最终环境验证..."
    echo "Docker: $(command -v docker || echo '未找到')"
    echo "jq: $(command -v jq || echo '未找到')"
    echo "cast: $(command -v cast || echo '未找到')"
    echo "aztec: $(command -v aztec || echo '未找到')"
    
    # 检查 Aztec CLI 版本和功能
    if command -v aztec >/dev/null 2>&1; then
        local aztec_version=$(aztec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
        print_info "当前 Aztec CLI 版本: $aztec_version"
        
        if [[ "$aztec_version" < "2.1.2" ]] || ! aztec validator-keys --help >/dev/null 2>&1; then
            print_warning "Aztec CLI 版本过旧或功能不全，重新安装..."
            if ! install_aztec_cli; then
                print_error "Aztec CLI 重新安装失败"
                return 1
            fi
        fi
    fi
    
    # 重新加载环境变量
    source ~/.bashrc 2>/dev/null || true
    source ~/.profile 2>/dev/null || true
    
    print_success "环境检查通过"
    return 0
}

# ==================== 从私钥生成地址 ====================
generate_address_from_private_key() {
    local private_key=$1
    local address
    
    # 清理私钥: 移除空格/前导0x多余
    private_key=$(echo "$private_key" | tr -d ' ' | sed 's/^0x//')
    if [[ ${#private_key} -ne 64 ]]; then
        print_error "私钥长度错误 (需64 hex): ${#private_key}"
        return 1
    fi
    private_key="0x$private_key"  # 恢复0x
    
    address=$(cast wallet address --private-key "$private_key" 2>/dev/null || echo "")
    
    if [[ -z "$address" || ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        print_warning "cast 失败，尝试 SHA3-256 fallback..."
        local stripped_key="${private_key#0x}"
        address=$(echo -n "$stripped_key" | xxd -r -p | openssl dgst -sha3-256 -binary | xxd -p -c 40 | sed 's/^/0x/' || echo "")
    fi
    
    if [[ ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        print_error "地址生成失败: $address"
        return 1
    fi
    
    echo "$address"
}

# ==================== 加载现有 keystore ====================
load_existing_keystore() {
    local keystore_path=$1
    if [ ! -f "$keystore_path" ]; then
        print_error "keystore 文件不存在: $keystore_path"
        return 1
    fi
    
    local new_eth_key new_bls_key new_address
    new_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path")
    new_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path")
    
    if [[ -z "$new_eth_key" || "$new_eth_key" == "null" ]]; then
        print_error "ETH 私钥读取失败"
        return 1
    fi
    
    if [[ -z "$new_bls_key" || "$new_bls_key" == "null" ]]; then
        print_error "BLS 私钥读取失败"
        return 1
    fi
    
    new_address=$(generate_address_from_private_key "$new_eth_key")
    if [[ -z "$new_address" || ! "$new_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        print_error "地址生成失败"
        return 1
    fi
    
    print_success "加载成功！地址: $new_address"
    echo "ETH 私钥: $new_eth_key"
    echo "BLS 私钥: $new_bls_key"
    echo "请立即备份这些密钥！参考: https://docs.aztec.network/dev_docs/cli/validator_keys"
    read -p "确认已保存后按 [Enter] 继续..."
    
    read -p "输入预期地址确认 (e.g., 0x345...): " expected_address
    if [[ "$new_address" != "$expected_address" ]]; then
        print_warning "地址不匹配！预期: $expected_address, 实际: $new_address "
        read -p "是否继续? (y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 1
    fi
    
    export LOADED_ETH_KEY="$new_eth_key"
    export LOADED_BLS_KEY="$new_bls_key"
    export LOADED_ADDRESS="$new_address"
    export LOADED_KEYSTORE="$keystore_path"
    return 0
}

# ==================== 优化的注册验证者函数（基于官方脚本） ====================
register_validator_optimized() {
    clear
    print_info "Aztec 验证者注册 (优化版) - v2.1.2 兼容"
    echo "=========================================="
    
    if ! check_environment; then
        return 1
    fi
    
    echo ""
    echo "请提供原有验证者信息："
    read -sp "   输入原有 Funding 私钥 (不显示): " OLD_PRIVATE_KEY && echo
    read -p "   输入 Sepolia RPC URL (推荐 https://rpc.sepolia.org): " ETH_RPC
    echo "开始处理..." && echo ""

    # 验证私钥格式
    OLD_PRIVATE_KEY=$(echo "$OLD_PRIVATE_KEY" | tr -d ' ')
    if [[ ! "$OLD_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "私钥格式错误 (需 0x + 64 hex)"
        return 1
    fi

    # 生成 funding 地址
    local funding_address
    funding_address=$(generate_address_from_private_key "$OLD_PRIVATE_KEY")
    if [[ -z "$funding_address" ]]; then
        print_error "Funding 地址生成失败"
        return 1
    fi
    print_info "Funding 地址: $funding_address"

    # 检查 funding 地址余额
    print_info "检查 Funding 地址余额..."
    if ! check_eth_balance "$ETH_RPC" "$funding_address"; then
        print_warning "Funding 地址 ETH 不足，请补充 0.2 ETH"
        read -p "确认后继续..."
    fi

    # 清理旧密钥并生成新密钥
    print_info "准备生成新密钥..."
    rm -rf ~/.aztec/keystore 2>/dev/null
    echo "请准备好记录新的私钥和地址！"
    read -p "   按 [Enter] 生成新密钥..."
    
    aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000
    echo ""

    # 读取新生成的密钥
    KEYSTORE_FILE=~/.aztec/keystore/key1.json
    NEW_ETH_PRIVATE_KEY=$(jq -r '.validators[0].attester.eth' "$KEYSTORE_FILE")
    NEW_BLS_PRIVATE_KEY=$(jq -r '.validators[0].attester.bls' "$KEYSTORE_FILE")
    NEW_PUBLIC_ADDRESS=$(cast wallet address --private-key "$NEW_ETH_PRIVATE_KEY")

    echo "✅ 新密钥生成成功！请安全保存以下信息："
    echo "   - ETH 私钥: $NEW_ETH_PRIVATE_KEY"
    echo "   - BLS 私钥: $NEW_BLS_PRIVATE_KEY"
    echo "   - 地址: $NEW_PUBLIC_ADDRESS"
    echo ""

    # 检查新地址余额
    print_info "检查新地址余额..."
    BALANCE=$(cast balance "$NEW_PUBLIC_ADDRESS" --rpc-url "$ETH_RPC")
    BALANCE_ETH=$(echo "scale=4; $BALANCE / 1000000000000000000" | bc)

    if (( $(echo "$BALANCE_ETH < 0.3" | bc -l) )); then
        echo "⚠️  余额不足: $BALANCE_ETH ETH"
        echo "请转账 0.3-0.5 ETH 到地址:"
        echo "   $NEW_PUBLIC_ADDRESS"
        echo "转账后继续..."
        read -p "   确认已转账后按 [Enter] 继续..." && echo ""
    else
        echo "✅ 余额充足: $BALANCE_ETH ETH"
    fi

    # 检查 STAKE 余额
    print_info "检查 STAKE 余额..."
    local stake_balance_hex
    stake_balance_hex=$(cast call "$STAKE_TOKEN" "balanceOf(address)(uint256)" "$funding_address" --rpc-url "$ETH_RPC" 2>/dev/null || echo "0x0")
    local stake_balance=$(printf "%d" "$stake_balance_hex" 2>/dev/null || echo "0")
    local formatted_stake=$(echo "scale=0; $stake_balance / 1000000000000000000" | bc 2>/dev/null || echo "0")
    
    if [[ "$stake_balance" -lt "$STAKE_AMOUNT" ]]; then
        print_error "STAKE 余额不足！需要 200k STAKE，当前 $formatted_stake STAKE"
        print_warning "请从 Faucet 获取: https://testnet.aztec.network/faucet"
        read -p "确认补充后按 [Enter] 继续..."
        return 1
    else
        print_success "STAKE 余额充足: $formatted_stake STAKE"
    fi

    # STAKE 授权
    print_info "执行 STAKE 授权..."
    if cast send "$STAKE_TOKEN" \
        "approve(address,uint256)" \
        "$ROLLUP_CONTRACT" \
        "200000000000000000000000" \
        --private-key "$OLD_PRIVATE_KEY" \
        --rpc-url "$ETH_RPC" \
        --gas-price 2gwei; then
        print_success "✅ 授权成功"
    else
        print_error "授权失败"
        return 1
    fi

    # 注册验证者
    echo ""
    print_info "注册验证者到测试网..."
    if aztec add-l1-validator \
        --l1-rpc-urls "$ETH_RPC" \
        --network testnet \
        --private-key "$OLD_PRIVATE_KEY" \
        --attester "$NEW_PUBLIC_ADDRESS" \
        --withdrawer "$NEW_PUBLIC_ADDRESS" \
        --bls-secret-key "$NEW_BLS_PRIVATE_KEY" \
        --rollup "$ROLLUP_CONTRACT"; then
        
        echo ""
        print_success "🎉 注册完成！"
        echo "✅ 验证者已成功注册到测试网"
        echo "📝 请使用新密钥更新你的节点配置："
        echo "   - ETH 私钥: $NEW_ETH_PRIVATE_KEY"
        echo "   - 地址: $NEW_PUBLIC_ADDRESS"
        echo ""
        echo "队列检查: $DASHTEC_URL/validator/$NEW_PUBLIC_ADDRESS"
        echo "重新启动节点以使用新密钥运行"
    else
        print_error "注册失败"
        return 1
    fi
    
    read -p "按任意键继续..."
    return 0
}

# ==================== 检查 ETH 余额 ====================
check_eth_balance() {
    local eth_rpc=$1
    local address=$2
    local min_eth=0.2
    local balance_eth
    
    balance_eth=$(cast balance "$address" --rpc-url "$eth_rpc" | sed 's/.* \([0-9.]*\) eth.*/\1/' || echo "0")
    
    if [[ $(echo "$balance_eth >= $min_eth" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
        print_success "ETH 充足 ($balance_eth ETH)"
        return 0
    else
        print_warning "ETH 不足 ($balance_eth ETH)，需至少 0.2 ETH 用于 gas"
        return 1
    fi
}

# ==================== 主安装流程 ====================
install_and_start_node() {
    clear
    print_info "Aztec 测试网节点安装 (修复版) - v2.1.2 兼容"
    echo "=========================================="
    
    if ! check_environment; then
        return 1
    fi
    
    echo ""
    echo "请输入基础信息："
    read -p "L1 执行 RPC URL (推荐稳定: https://rpc.sepolia.org): " ETH_RPC
    echo
    read -p "L1 共识 Beacon RPC URL (e.g., https://ethereum-sepolia-beacon-api.publicnode.com): " CONS_RPC
    echo
    read -p "Funding 私钥 (用于后续注册，必须有 200k STAKE 和 0.2 ETH): " FUNDING_PRIVATE_KEY
    echo ""
    
    if [[ -n "$FUNDING_PRIVATE_KEY" && ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "私钥格式错误 (需 0x + 64 hex)"
        return 1
    fi
    
    local funding_address
    if [[ -n "$FUNDING_PRIVATE_KEY" ]]; then
        funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY")
        if [[ -z "$funding_address" ]]; then return 1; fi
        print_info "Funding 地址: $funding_address"
        print_warning "确认此地址有 200k STK (Etherscan: https://sepolia.etherscan.io/token/$STAKE_TOKEN?a=$funding_address)"
        read -p "地址匹配你的 OKX? (y/N): " addr_confirm
        [[ "$addr_confirm" != "y" && "$addr_confirm" != "Y" ]] && { print_error "地址不匹配，请修正私钥"; return 1; }
        
        if ! check_eth_balance "$ETH_RPC" "$funding_address"; then
            print_warning "Funding 地址 ETH 不足，请补充 0.2 ETH"
            read -p "确认后继续..."
        fi
    fi
    
    echo ""
    print_info "选择模式："
    echo "1. 生成新地址 (安装后使用选项6注册)"
    echo "2. 加载现有 keystore.json (安装后使用选项6注册)"
    read -p "请选择 (1-2): " mode_choice
    
    local new_eth_key new_bls_key new_address
    case $mode_choice in
        1)
            print_info "生成新密钥..."
            rm -rf "$HOME/.aztec/keystore" 2>/dev/null || true
            aztec validator-keys new --fee-recipient 0x0000000000000000000000000000000000000000000000000000000000000000
            new_eth_key=$(jq -r '.validators[0].attester.eth' "$DEFAULT_KEYSTORE")
            new_bls_key=$(jq -r '.validators[0].attester.bls' "$DEFAULT_KEYSTORE")
            new_address=$(generate_address_from_private_key "$new_eth_key")
            print_success "新地址: $new_address"
            echo ""
            print_warning "=== 保存密钥！ ==="
            echo "ETH 私钥: $new_eth_key"
            echo "BLS 私钥: $new_bls_key"
            echo "地址: $new_address"
            read -p "确认保存后继续..."
            ;;
        2)
            echo "输入 keystore.json 路径 (默认 $DEFAULT_KEYSTORE): "
            read -p "路径: " keystore_path
            keystore_path=${keystore_path:-$DEFAULT_KEYSTORE}
            if ! load_existing_keystore "$keystore_path"; then return 1; fi
            new_eth_key="$LOADED_ETH_KEY"
            new_bls_key="$LOADED_BLS_KEY"
            new_address="$LOADED_ADDRESS"
            mkdir -p "$KEY_DIR"
            cp "$LOADED_KEYSTORE" "$KEY_DIR/keystore.json"
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac

    # ==================== 清理现有容器 ====================
    cleanup_existing_containers

    # ==================== 安装和启动节点 ====================
    print_info "设置节点环境（使用密钥: $new_address）..."
    mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$KEY_DIR"
    local public_ip=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")
    
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
    docker compose up -d
    sleep 10  # 等待启动
    print_info "启动后日志（最近20行）："
    docker logs aztec-sequencer --tail 20
    echo ""
    
    local api_status=$(curl -s http://localhost:8080/status 2>/dev/null || echo "")
    if [[ -n "$api_status" && $(jq -e '.error == null' <<< "$api_status" 2>/dev/null) == "true" ]]; then
        print_success "节点启动成功！API 响应正常。"
    else
        print_warning "节点启动中... API 暂无响应（正常，等待同步）。日志: $api_status"
    fi
    
    print_success "节点安装和启动完成！地址: $new_address"
    echo "注册请使用菜单选项6。队列: $DASHTEC_URL/validator/$new_address"

    echo ""
    print_success "部署完成！"
    echo "日志: docker logs -f aztec-sequencer"
    echo "状态: curl http://localhost:8080/status"
    read -p "按任意键继续..."
}

# ==================== 查看日志和状态 ====================
view_logs_and_status() {
    if docker ps | grep -q aztec-sequencer; then
        echo "节点运行中"
        docker logs --tail 100 aztec-sequencer
        echo ""
        local api_status=$(curl -s http://localhost:8080/status 2>/dev/null || echo "")
        if [[ -n "$api_status" && $(jq -e '.error == null' <<< "$api_status" 2>/dev/null) == "true" ]]; then
            echo "$api_status"
            print_success "API 响应正常！"
        else
            echo "$api_status"
            print_error "API 响应异常或无响应！"
        fi
        local error_logs=$(docker logs --tail 100 aztec-sequencer 2>/dev/null | grep -E "(ERROR|WARN|FATAL|failed to|connection refused|timeout|sync failed|RPC error|P2P error|disconnected.*failed)" | grep -v -E "(no blocks|too far into slot|rate limit exceeded|yamux error)")
        local error_count=$(echo "$error_logs" | wc -l)
        if [[ "$error_count" -eq 0 ]]; then
            print_success "日志正常，无明显错误！（P2P活跃，同步稳定）"
        else
            print_warning "日志中发现 $error_count 条潜在问题 (如连接/同步失败)，详情："
            echo "$error_logs"
        fi
        echo ""
        print_info "是否查看实时日志？(y/N): "
        read -r realtime_choice
        if [[ "$realtime_choice" == "y" || "$realtime_choice" == "Y" ]]; then
            print_info "实时日志（按 Ctrl+C 停止）..."
            docker logs -f aztec-sequencer
        fi
    else
        print_error "节点未运行！"
    fi
    read -p "按 [Enter] 继续..."
}

# ==================== 更新并重启节点 ====================
update_and_restart_node() {
    if [ ! -d "$AZTEC_DIR" ]; then
        print_error "节点目录不存在，请先安装节点！"
        read -p "按 [Enter] 继续..."
        return 1
    fi
    
    # 清理现有容器
    cleanup_existing_containers
    
    print_info "检查并拉取最新 Aztec 镜像..."
    cd "$AZTEC_DIR"
    local old_image=$(docker inspect aztec-sequencer --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
    print_info "当前镜像: $old_image"
    docker compose pull aztec-sequencer --quiet
    print_success "镜像拉取完成！"
    print_warning "重启节点（可能有短暂中断）..."
    docker compose up -d
    sleep 10
    local new_image=$(docker inspect aztec-sequencer --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
    if [[ "$old_image" != "$new_image" ]]; then
        print_success "更新成功！新镜像: $new_image"
    else
        print_info "无新版本可用。"
    fi
    print_info "重启后日志（最近20行）："
    docker logs aztec-sequencer --tail 20
    echo ""
    print_success "更新和重启完成！"
    read -p "按 [Enter] 继续..."
}

# ==================== 性能监控 ====================
monitor_performance() {
    if [ ! -d "$AZTEC_DIR" ]; then
        print_error "节点目录不存在，请先安装节点！"
        read -p "按 [Enter] 继续..."
        return 1
    fi
    print_info "=== 系统性能监控 ==="
    echo "VPS 整体资源："
    free -h | grep -E "^Mem:" | awk '{printf "内存: 总 %s | 已用 %s | 可用 %s (%.1f%% 已用)\n", $2, $3, $7, ($3/$2)*100}'
    echo "CPU 使用率: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | awk '{printf "%.1f%%\n", $1}')"
    echo "磁盘使用: $(df -h / | awk 'NR==2 {printf "%.1f%% 已用 (%s 可用)", $5, $4}')"
    echo "网络 I/O (最近1min): $(cat /proc/net/dev | grep eth0 | awk '{print "接收: " $2/1024/1024 "MB, 发送: " $10/1024/1024 "MB"}' 2>/dev/null || echo "网络接口未找到")"
    if docker ps | grep -q aztec-sequencer; then
        print_info "=== Aztec 容器性能 ==="
        docker stats aztec-sequencer --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" | tail -n1
        print_info "Aztec API 响应时间 (ms): $(curl -s -w "%{time_total}" -o /dev/null http://localhost:8080/status 2>/dev/null || echo "N/A")"
        local peers=$(curl -s http://localhost:8080/status 2>/dev/null | jq -r '.peers // empty' || echo "N/A")
        echo "P2P 连接数: $peers"
    else
        print_warning "Aztec 容器未运行，无法监控容器指标。"
    fi
    echo ""
    print_info "监控刷新间隔 (s): "
    read -r interval
    interval=${interval:-5}
    print_warning "实时监控（按 Ctrl+C 停止）... (每 $interval s 更新)"
    while true; do
        clear
        monitor_performance
        sleep "$interval"
    done
}

# ==================== 菜单 ====================
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Aztec 节点安装 (修复版) - v2.1.2"
        echo "========================================"
        echo "1. 安装/启动节点 (先安装节点)"
        echo "2. 查看日志和状态"
        echo "3. 更新并重启节点"
        echo "4. 性能监控"
        echo "5. 退出"
        echo "6. 注册验证者 (单独选项)"
        echo "7. 快速注册验证者 (优化版)"
        read -p "选择: " choice
        case $choice in
            1) install_and_start_node ;;
            2) view_logs_and_status ;;
            3) update_and_restart_node ;;
            4) monitor_performance ;;
            5) exit 0 ;;
            6) register_validator ;;
            7) register_validator_optimized ;;
            *) echo "无效"; read -p "继续...";;
        esac
    done
}

# 启动主菜单
main_menu
