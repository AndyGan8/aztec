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
STAKE_AMOUNT=200000000000000000000000  # 200k wei (18 decimals)
AZTEC_CLI_VERSION="2.0.2"  # 更新为当前稳定版本 (基于2025年文档)

# ==================== 环境变量修复 ====================
fix_environment() {
  print_info "修复环境变量..."
  
  # 确保 Foundry 路径在 PATH 中
  if [ -d "$HOME/.foundry/bin" ] && [[ ":$PATH:" != *":$HOME/.foundry/bin:"* ]]; then
    export PATH="$HOME/.foundry/bin:$PATH"
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
  fi
  
  # 确保 Aztec 路径在 PATH 中
  if [ -d "$HOME/.aztec/bin" ] && [[ ":$PATH:" != *":$HOME/.aztec/bin:"* ]]; then
    export PATH="$HOME/.aztec/bin:$PATH"
    echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
  fi
  
  # 重新加载 bashrc
  source ~/.bashrc 2>/dev/null || true
  
  # 验证关键命令
  local missing_cmds=()
  for cmd in docker jq cast aztec; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    fi
  done
  
  if [ ${#missing_cmds[@]} -gt 0 ]; then
    print_error "缺少命令: ${missing_cmds[*]}，正在自动安装..."
    install_dependencies  # 新增：自动安装缺失依赖
    
    # 重新验证安装后状态
    missing_cmds=()
    for cmd in docker jq cast aztec; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_cmds+=("$cmd")
      fi
    done
    
    if [ ${#missing_cmds[@]} -gt 0 ]; then
      print_error "安装后仍缺少: ${missing_cmds[*]}，请手动检查网络/权限"
      return 1
    fi
  fi
  
  print_success "环境变量修复完成"
  return 0
}

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

# ==================== 清理并重新安装 Aztec CLI ====================
reinstall_aztec_cli() {
  print_warning "Aztec CLI 版本过旧 (需 >=$AZTEC_CLI_VERSION)，正在删除并重新安装最新版 $AZTEC_CLI_VERSION..."
  rm -rf "$HOME/.aztec"
  print_info "删除旧版完成"
  retry_cmd 3 bash -i <(curl -s --progress https://install.aztec.network)
  export PATH="$HOME/.aztec/bin:$PATH"
  print_info "基础安装完成"
  print_info "更新到 $AZTEC_CLI_VERSION..."
  aztec-up "$AZTEC_CLI_VERSION"
  sleep 5
  local new_version=$(aztec --version 2>/dev/null || echo "未知")
  print_success "重新安装完成 (新版本: $new_version)"
  if ! aztec validator-keys --help >/dev/null 2>&1; then
    print_error "$AZTEC_CLI_VERSION 安装后 validator-keys 仍不可用！检查网络或手动 aztec-up $AZTEC_CLI_VERSION"
    read -p "按 Enter 继续 (或 Ctrl+C 退出)..."
  fi
}

# ==================== 安装依赖 ====================
install_dependencies() {
  print_info "检测到缺失依赖，正在自动安装..."
  print_info "更新系统包..."
  retry_cmd 3 apt update -y -qq && apt upgrade -y -qq
  print_info "安装基础工具 (jq, curl 等)..."
  apt install -y -qq curl jq iptables build-essential git wget lz4 make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip ca-certificates gnupg lsb-release bc
  if ! command -v docker >/dev/null 2>&1; then
    print_info "安装 Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    usermod -aG docker root
    sleep 5
    docker run hello-world >/dev/null 2>&1 || print_warning "Docker 测试失败，请手动检查"
    print_success "Docker 安装完成"
  else
    print_info "Docker 已存在，跳过"
  fi
  if ! command -v cast >/dev/null 2>&1; then
    print_info "安装 Foundry (包含 cast)..."
    curl -L https://foundry.paradigm.xyz | bash
    export PATH="$HOME/.foundry/bin:$PATH"
    foundryup
    sleep 2
    if command -v cast >/dev/null 2>&1; then
      print_success "Foundry 安装完成 (cast 可用)"
    else
      print_error "Foundry 安装失败，请手动运行 'export PATH=\"$HOME/.foundry/bin:\$PATH\"; foundryup'"
      read -p "按 Enter 继续 (或 Ctrl+C 退出)..."
    fi
  else
    print_info "Foundry 已存在，跳过"
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! command -v aztec >/dev/null 2>&1; then
    print_info "安装 Aztec CLI..."
    reinstall_aztec_cli
  else
    print_info "Aztec CLI 已存在，检查更新..."
    aztec-up "$AZTEC_CLI_VERSION"
    sleep 5
    if [[ $(aztec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0") < "$AZTEC_CLI_VERSION" ]] || ! aztec validator-keys --help >/dev/null 2>&1; then
      print_warning "版本 <$AZTEC_CLI_VERSION 或 validator-keys 不可用，正在重新安装 $AZTEC_CLI_VERSION..."
      reinstall_aztec_cli
    fi
  fi
  print_success "Aztec CLI 更新完成 (版本: $(aztec --version))"
  echo 'export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
  export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"
  print_info "验证安装..."
  for cmd in docker jq cast aztec; do
    if command -v "$cmd" >/dev/null 2>&1; then
      print_success "$cmd: OK ($(command -v $cmd))"
    else
      print_warning "$cmd: 仍不可用，手动检查"
    fi
  done
  print_success "所有依赖安装完成！"
}

# ==================== 环境检查 ====================
check_environment() {
  print_info "检查环境..."
  
  # 先修复环境变量
  if ! fix_environment; then
    print_error "环境变量修复失败"
    return 1
  fi
  
  export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"
  local missing=()
  for cmd in docker jq cast aztec; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    print_error "缺少命令: ${missing[*]}"
    install_dependencies
    missing=()
    for cmd in docker jq cast aztec; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
      fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
      print_error "安装后仍缺少: ${missing[*]}，请手动修复"
      return 1
    fi
  fi
  print_info "检查 Aztec CLI 版本和功能..."
  local aztec_version=$(aztec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
  print_info "当前 Aztec CLI 版本: $aztec_version"
  if [[ "$aztec_version" < "$AZTEC_CLI_VERSION" ]] || ! aztec validator-keys --help >/dev/null 2>&1; then
    print_error "Aztec CLI 版本 $aztec_version 过旧或不支持 'validator-keys' (需 >=$AZTEC_CLI_VERSION)。正在自动删除并重装..."
    reinstall_aztec_cli
    if [[ $(aztec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0") < "$AZTEC_CLI_VERSION" ]] || ! aztec validator-keys --help >/dev/null 2>&1; then
      print_error "重装失败！手动: rm -rf ~/.aztec && bash -i <(curl -s https://install.aztec.network) && aztec-up $AZTEC_CLI_VERSION"
      return 1
    fi
  fi
  print_success "Aztec CLI 功能检查通过 (validator-keys 可用)"
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

# ==================== 可靠的余额检查 ====================
reliable_stake_balance_check() {
  local eth_rpc=$1
  local address=$2
  
  print_info "使用可靠 RPC 检查 STAKE 余额..."
  
  # 尝试多个可靠的公共 RPC
  local reliable_rpcs=(
    "https://rpc.sepolia.org"
    "https://ethereum-sepolia-rpc.publicnode.com"
    "https://sepolia.drpc.org"
  )
  
  local balance_hex="0x0"
  local balance=0
  local formatted_balance=0
  
  for rpc in "${reliable_rpcs[@]}"; do
    print_info "尝试 RPC: $rpc"
    balance_hex=$(cast call "$STAKE_TOKEN" "balanceOf(address)(uint256)" "$address" --rpc-url "$rpc" 2>/dev/null || echo "0x0")
    
    if [[ "$balance_hex" != "0x0" && "$balance_hex" != "0x" ]]; then
      balance=$(printf "%d" "$balance_hex" 2>/dev/null || echo "0")
      formatted_balance=$(echo "scale=0; $balance / 1000000000000000000" | bc 2>/dev/null || echo "0")
      
      if [[ "$balance" -gt 0 ]]; then
        print_success "从 $rpc 获取到余额: $formatted_balance STAKE"
        
        # 验证余额是否合理
        if [[ "$balance" -ge "$STAKE_AMOUNT" ]]; then
          print_success "STAKE 余额充足: $formatted_balance STAKE"
          return 0
        else
          print_warning "STAKE 余额不足: $formatted_balance STAKE (需要 200k)"
          return 1
        fi
      fi
    fi
    sleep 1
  done
  
  # 如果所有 RPC 都失败，使用原始 RPC 作为后备
  print_warning "所有可靠 RPC 失败，使用原始 RPC 作为后备..."
  balance_hex=$(cast call "$STAKE_TOKEN" "balanceOf(address)(uint256)" "$address" --rpc-url "$eth_rpc" 2>/dev/null || echo "0x0")
  balance=$(printf "%d" "$balance_hex" 2>/dev/null || echo "0")
  formatted_balance=$(echo "scale=0; $balance / 1000000000000000000" | bc 2>/dev/null || echo "0")
  
  print_info "后备 RPC 余额: $formatted_balance STAKE"
  
  if [[ "$balance" -ge "$STAKE_AMOUNT" ]]; then
    print_success "STAKE 余额充足: $formatted_balance STAKE"
    return 0
  else
    print_error "STAKE 余额不足: $formatted_balance STAKE (需要 200k)"
    return 1
  fi
}

# ==================== 检查 STAKE 授权和余额 ====================
check_stake_balance_and_approve() {
  local eth_rpc=$1
  local funding_private_key=$2
  local funding_address=$3
  
  print_info "检查 STAKE 余额和授权..."
  
  # 使用可靠的余额检查
  if ! reliable_stake_balance_check "$eth_rpc" "$funding_address"; then
    print_error "STAKE 余额不足！需要 200k STAKE"
    print_warning "请从 Faucet 获取: https://testnet.aztec.network/faucet"
    print_warning "升级提醒: 需要 ZKPassport 证明 (下载 App 并连接 Discord)"
    read -p "确认补充后按 [Enter] 继续 (或输入 'skip' 手动跳过)..."
    if [[ "$REPLY" == "skip" ]]; then
      print_warning "跳过余额检查，继续授权..."
    else
      # 重新检查
      if ! reliable_stake_balance_check "$eth_rpc" "$funding_address"; then
        print_error "补充后仍不足，退出"
        return 1
      fi
    fi
  fi
  
  print_info "检查 STAKE 授权..."
  local allowance_hex
  allowance_hex=$(cast call "$STAKE_TOKEN" "allowance(address,address)(uint256)" "$funding_address" "$ROLLUP_CONTRACT" --rpc-url "$eth_rpc" 2>/dev/null || echo "0x0")
  local allowance=$(printf "%d" "$allowance_hex" 2>/dev/null || echo "0")
  local formatted_allowance=$(echo "scale=0; $allowance / 1000000000000000000" | bc 2>/dev/null || echo "0")
  
  if [[ "$allowance" -ge "$STAKE_AMOUNT" ]]; then
    print_success "STAKE 已授权 (额度: $formatted_allowance STAKE)"
    return 0
  fi
  
  print_warning "执行 STAKE 授权 (额度: 200k STAKE)..."
  for attempt in 1 2 3; do
    local tx_hash
    tx_hash=$(cast send "$STAKE_TOKEN" "approve(address,uint256)" \
      "$ROLLUP_CONTRACT" "200000ether" \
      --private-key "$funding_private_key" --rpc-url "$eth_rpc" --gas-price 2gwei 2>&1 | grep -o '0x[a-fA-F0-9]\{66\}' || echo "")
    
    if [[ -n "$tx_hash" ]]; then
      print_info "TX 发送: $tx_hash (查: https://sepolia.etherscan.io/tx/$tx_hash)"
      sleep 10
      
      allowance_hex=$(cast call "$STAKE_TOKEN" "allowance(address,address)(uint256)" "$funding_address" "$ROLLUP_CONTRACT" --rpc-url "$eth_rpc" 2>/dev/null || echo "0x0")
      allowance=$(printf "%d" "$allowance_hex" 2>/dev/null || echo "0")
      formatted_allowance=$(echo "scale=0; $allowance / 1000000000000000000" | bc 2>/dev/null || echo "0")
      
      if [[ "$allowance" -ge "$STAKE_AMOUNT" ]]; then
        print_success "授权成功 (尝试 $attempt)！额度: $formatted_allowance STAKE"
        return 0
      fi
    fi
    print_warning "授权失败 (尝试 $attempt)，重试中..."
    sleep 5
  done
  
  print_error "授权失败 3 次，请手动检查 gas/STAKE 余额或 RPC"
  return 1
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

# ==================== 更新并重启节点 ====================
update_and_restart_node() {
  if [ ! -d "$AZTEC_DIR" ]; then
    print_error "节点目录不存在，请先安装节点！"
    read -p "按 [Enter] 继续..."
    return 1
  fi
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

# ==================== 查看日志和状态 ====================
view_logs_and_status() {
  if docker ps | grep -q aztec-sequencer; then
    echo "节点运行中"
    docker logs --tail 100 aztec-sequencer
    echo ""
    local api_status=$(curl -s http://localhost:8080/status 2>/dev/null || echo "")
    if [[ -n "$api_status" && $(echo "$api_status" | jq -e '.error == null' 2>/dev/null) == "true" ]]; then
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

# ==================== 主安装流程 ====================
install_and_start_node() {
  clear
  print_info "Aztec 测试网节点安装 (修复版) - v$AZTEC_CLI_VERSION 兼容 (2025 更新)"
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
      cp "$LOADED_KEYSTORE" "$KEY_DIR/keystore.json"
      ;;
    *)
      print_error "无效选择"
      return 1
      ;;
  esac

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
      - "${AZTEC_PORT}:${AZTEC_PORT}"
      - "${AZTEC_ADMIN_PORT}:${AZTEC_ADMIN_PORT}"
      - "${P2P_PORT}:${P2P_PORT}"
      - "${P2P_PORT}:${P2P_PORT}/udp"
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
      VALIDATOR_PRIVATE_KEY: ${VALIDATOR_PRIVATE_KEY}
      COINBASE: ${COINBASE}
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
  if [[ -n "$api_status" && $(echo "$api_status" | jq -e '.error == null' 2>/dev/null) == "true" ]]; then
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

# ==================== 单独注册验证者函数 ====================
register_validator() {
  clear
  print_info "单独注册验证者 - v$AZTEC_CLI_VERSION 兼容"
  echo "=========================================="
  
  if ! check_environment; then
    return 1
  fi
  
  echo ""
  echo "请输入注册信息："
  read -p "L1 执行 RPC URL (推荐: https://rpc.sepolia.org): " ETH_RPC
  echo
  read -p "Funding 私钥 (必须有 200k STAKE 和 0.2 ETH): " FUNDING_PRIVATE_KEY
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
    
    if ! check_eth_balance "$ETH_RPC" "$funding_address"; then
      print_warning "Funding 地址 ETH 不足，请补充 0.2 ETH"
      read -p "确认后继续..."
    fi
  fi
  
  echo ""
  print_info "选择密钥来源："
  echo "1. 从现有 keystore.json 加载 (推荐)"
  echo "2. 手动输入 ETH 私钥和 BLS 私钥"
  read -p "请选择 (1-2): " key_choice
  
  local new_eth_key new_bls_key new_address
  case $key_choice in
    1)
      echo "输入 keystore.json 路径 (默认 $DEFAULT_KEYSTORE): "
      read -p "路径: " keystore_path
      keystore_path=${keystore_path:-$DEFAULT_KEYSTORE}
      if ! load_existing_keystore "$keystore_path"; then return 1; fi
      new_eth_key="$LOADED_ETH_KEY"
      new_bls_key="$LOADED_BLS_KEY"
      new_address="$LOADED_ADDRESS"
      ;;
    2)
      read -p "ETH 私钥 (0x + 64 hex): " new_eth_key
      read -p "BLS 私钥: " new_bls_key
      new_address=$(generate_address_from_private_key "$new_eth_key")
      if [[ -z "$new_address" ]]; then return 1; fi
      print_success "地址: $new_address"
      print_warning "确认保存密钥！"
      read -p "按 Enter 继续..."
      ;;
    *)
      print_error "无效选择"
      return 1
      ;;
  esac
  
  echo ""
  print_info "检查验证者地址 ETH 余额..."
  if ! check_eth_balance "$ETH_RPC" "$new_address"; then
    print_warning "验证者地址 ETH 不足，请转 0.3 ETH 到 $new_address"
    read -p "确认后继续..."
  fi
  
  echo ""
  print_info "检查 STAKE 余额和授权..."
  if ! check_stake_balance_and_approve "$ETH_RPC" "$FUNDING_PRIVATE_KEY" "$funding_address"; then
    print_error "授权失败，请修复后重试此选项。"
    return 1
  fi
  
  echo ""
  print_info "执行注册验证者..."
  aztec add-l1-validator --l1-rpc-urls "$ETH_RPC" --network testnet --private-key "$FUNDING_PRIVATE_KEY" --attester "$new_address" --withdrawer "$new_address" --bls-secret-key "$new_bls_key" --rollup "$ROLLUP_CONTRACT"
  
  print_success "注册成功！"
  echo "队列检查: $DASHTEC_URL/validator/$new_address"
  read -p "按任意键继续..."
}

# ==================== 菜单 ====================
main_menu() {
  while true; do
    clear
    echo "========================================"
    echo " Aztec 节点安装 (修复版) - v$AZTEC_CLI_VERSION (2025)"
    echo "========================================"
    echo "1. 安装/启动节点 (先安装节点)"
    echo "2. 查看日志和状态"
    echo "3. 更新并重启节点"
    echo "4. 性能监控"
    echo "5. 退出"
    echo "6. 注册验证者 (单独选项)"
    read -p "选择: " choice
    case $choice in
      1) install_and_start_node ;;
      2) view_logs_and_status ;;
      3) update_and_restart_node ;;
      4) monitor_performance ;;
      5) exit 0 ;;
      6) register_validator ;;
      *) echo "无效"; read -p "继续...";;
    esac
  done
}

# 设置默认 keystore 路径
DEFAULT_KEYSTORE="$HOME/.aztec/keystore/key1.json"

# 启动主菜单
main_menu
