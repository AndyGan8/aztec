#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行"
  exit 1
fi

# ==================== 常量 ====================
AZTEC_DIR="/root/aztec-sequencer"
ROLLUP_CONTRACT="0xebd99ff0ff6677205509ae73f93d0ca52ac85d67"
DASHTEC_URL="https://dashtec.xyz"
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

# ==================== 直接注册验证者函数 ====================
register_validator_direct() {
    clear
    print_info "Aztec 验证者注册 (直接注册版)"
    echo "=========================================="
    
    if ! check_environment; then
        print_error "环境检查失败"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    echo ""
    echo "🚀 直接注册验证者 - 跳过余额检查"
    echo "⚠️  请确保你有："
    echo "   - 200k STAKE 在 Funding 地址"
    echo "   - 足够的 ETH 支付 gas 费用"
    echo ""
    
    echo "请提供注册信息："
    
    read -p "L1 RPC URL (推荐: https://rpc.sepolia.org): " ETH_RPC
    ETH_RPC=${ETH_RPC:-"https://rpc.sepolia.org"}
    echo
    
    read -sp "Funding 私钥 (必须有 200k STAKE): " FUNDING_PRIVATE_KEY
    echo
    echo
    
    if [[ -z "$FUNDING_PRIVATE_KEY" || ! "$FUNDING_PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        print_error "私钥格式错误 (需 0x + 64 hex)"
        read -p "按任意键返回菜单..."
        return 1
    fi
    
    # 生成 funding 地址
    local funding_address
    funding_address=$(generate_address_from_private_key "$FUNDING_PRIVATE_KEY")
    print_info "Funding 地址: $funding_address"
    
    # 直接跳过余额检查
    echo ""
    print_warning "⚠️  跳过余额检查，直接进行注册"
    print_info "请确认以下地址有足够余额："
    echo "  - Funding 地址: $funding_address"
    echo "  - 需要: 200k STAKE + 0.2 ETH (用于 gas)"
    echo ""
    
    read -p "确认余额充足后按 [Enter] 继续..."
    
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
            keystore_path=${keystore_path:-$DEFAULT_KEYSTORE}
            if [[ -f "$keystore_path" ]]; then
                validator_eth_key=$(jq -r '.validators[0].attester.eth' "$keystore_path")
                validator_bls_key=$(jq -r '.validators[0].attester.bls' "$keystore_path")
                validator_address=$(generate_address_from_private_key "$validator_eth_key")
                print_success "加载成功！地址: $validator_address"
            else
                print_error "keystore 文件不存在: $keystore_path"
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
    
    # 直接执行注册
    echo ""
    print_info "执行验证者注册..."
    print_info "注册信息:"
    echo "  - 验证者地址: $validator_address"
    echo "  - Funding 地址: $funding_address"
    echo "  - RPC: $ETH_RPC"
    echo ""
    
    read -p "确认注册信息正确后按 [Enter] 开始注册..."
    
    # 直接执行 aztec 注册命令
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
        echo "  2. STAKE 余额不足"
        echo "  3. 参数错误"
        echo "  4. 网络连接问题"
        echo ""
        echo "💡 解决方案:"
        echo "  1. 确认 Funding 地址有 200k STAKE"
        echo "  2. 确认有足够的 ETH 支付 gas"
        echo "  3. 检查 RPC 连接"
        echo "  4. 重试注册"
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

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Aztec 验证者直接注册脚本"
        echo "========================================"
        echo "1. 直接注册验证者 (跳过余额检查)"
        echo "2. 查看节点日志和状态"
        echo "3. 退出"
        echo ""
        read -p "请选择 (1-3): " choice
        
        case $choice in
            1) register_validator_direct ;;
            2) view_logs_and_status ;;
            3) echo "再见！"; exit 0 ;;
            *) echo "无效选择，请重新输入"; sleep 1 ;;
        esac
    done
}

# 启动脚本
main_menu
