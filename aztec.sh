# ------------------ 自动安装依赖（针对 Ubuntu/Debian） ------------------
install_missing_deps() {
    local missing=("$@")
    print_warning "检测到缺失命令: ${missing[*]}。开始自动安装（Ubuntu/Debian）..."

    # 更新 apt
    apt update -qq || print_error "apt update 失败"

    # 安装基本工具（jq, bc, curl）
    if [[ " ${missing[*]} " =~ " jq " ]] || [[ " ${missing[*]} " =~ " bc " ]] || [[ " ${missing[*]} " =~ " curl " ]]; then
        print_info "安装 jq/bc/curl..."
        apt install -y jq bc curl || print_error "apt install jq/bc/curl 失败"
    fi

    # 安装 Docker（如果缺失）
    if [[ " ${missing[*]} " =~ " docker " ]]; then
        print_info "安装 Docker..."
        apt install -y ca-certificates curl gnupg lsb-release || print_error "Docker 依赖安装失败"
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update -qq
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Docker 安装失败"
        systemctl start docker
        systemctl enable docker
        print_success "Docker 安装完成"
    fi

    # 安装 Foundry（包括 cast）
    if [[ " ${missing[*]} " =~ " cast " ]]; then
        print_info "安装 Foundry（包括 cast）..."
        
        # 先准备环境，避免安装器 source .bashrc 时 unbound 错误
        set +u
        export debian_chroot=""
        export PS1="\u@\h:\w\$ "  # 可选：稳定 PS1
        
        # 安装 foundryup
        curl -L https://foundry.paradigm.xyz | bash || print_error "Foundry 下载失败"
        
        # Source 更新 PATH（安装器修改了 .bashrc）
        source ~/.bashrc || true
        
        # 恢复 unbound
        set -u
        
        # 在 subshell 运行 foundryup（避免主 shell 污染）
        (foundryup) || print_error "foundryup 失败"
        
        # 确保 PATH
        export PATH="$HOME/.foundry/bin:$PATH"
        
        print_success "Foundry 安装完成（cast 已可用）"
    fi

    # Aztec CLI（需 Node.js，先检查/安装 Node；使用官方 curl 安装器）
    if [[ " ${missing[*]} " =~ " aztec " ]]; then
        print_info "安装 Node.js 和 Aztec CLI..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || print_error "NodeSource setup 失败"
        apt install -y nodejs || print_error "Node.js 安装失败"
        
        # 官方 Aztec CLI 安装（替换 npm）
        curl -s https://install.aztec.network | bash || print_error "Aztec CLI 下载失败"
        export PATH="$HOME/.aztec/bin:$PATH"
        source ~/.bashrc || true
        
        print_success "Aztec CLI 安装完成"
    fi

    # 重新加载 PATH
    export PATH="$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"
    print_success "依赖安装完成！"
}
