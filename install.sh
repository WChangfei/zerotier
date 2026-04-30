#!/bin/bash
# ==============================================================================
# ZeroTier + ztncui 一键安装脚本
# 功能: 提供菜单驱动的 ZeroTier 安装配置工具
# 作者: 借鉴自 dajiangfu，经优化改进
# 版本: 2.0
# 使用方式: sudo bash install.sh
# ==============================================================================

# 获取脚本所在目录 (POSIX兼容方式)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ZT_DIR="${SCRIPT_DIR}/zt"

# 获取服务器公网IP地址
SERVER_IP=$(curl -s ipv4.icanhazip.com)

# ==================== 颜色输出函数 ====================
blue() {
  echo -e "\033[34m\033[01m$1\033[0m"
}

green() {
  echo -e "\033[32m\033[01m$1\033[0m"
}

red() {
  echo -e "\033[31m\033[01m$1\033[0m"
}

# ==================== 系统检测 ====================
release_os=""
systemPackage_os=""

detect_system() {
  blue "[系统检测] 正在识别操作系统类型..."
  if [[ -f /etc/redhat-release ]]; then
    release_os="centos"
  elif cat /etc/issue | grep -Eqi "debian"; then
    release_os="debian"
  elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release_os="ubuntu"
  elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release_os="centos"
  elif cat /proc/version | grep -Eqi "debian"; then
    release_os="debian"
  elif cat /proc/version | grep -Eqi "ubuntu"; then
    release_os="ubuntu"
  elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release_os="centos"
  fi

  if [ "$release_os" = "centos" ]; then
    systemPackage_os="yum"
  elif [ "$release_os" = "ubuntu" ] || [ "$release_os" = "debian" ]; then
    systemPackage_os="apt"
  fi

  green "[系统检测] 当前系统: ${release_os}, 包管理器: ${systemPackage_os}"
}

# ==================== 功能函数 ====================

# 选项1: 清理
cleanup() {
  blue "[清理] 开始卸载旧版本并清理相关文件..."
  
  # 停止服务
  blue "[清理] 停止相关服务..."
  sudo systemctl stop zerotier-one 2>/dev/null || true
  sudo systemctl stop ztncui 2>/dev/null || true
  sudo systemctl stop tinyhttpd 2>/dev/null || true
  
  # 卸载软件包
  blue "[清理] 卸载 zerotier-one、ztncui 和 nginx..."
  if [ "$release_os" = "centos" ]; then
    sudo yum remove zerotier-one ztncui nginx -y 2>/dev/null || true
  elif [ "$release_os" = "ubuntu" ] || [ "$release_os" = "debian" ]; then
    sudo apt-get remove zerotier-one ztncui nginx -y 2>/dev/null || true
    sudo apt-get purge zerotier-one ztncui nginx -y 2>/dev/null || true
  fi
  
  # 删除相关目录
  blue "[清理] 删除相关目录..."
  sudo rm -rf /var/lib/zerotier-one 2>/dev/null || true
  sudo rm -rf /opt/key-networks 2>/dev/null || true
  sudo rm -rf /etc/zerotier 2>/dev/null || true
  sudo rm -rf /etc/nginx/conf.d/zt-download.conf 2>/dev/null || true
  
  # 删除脚本所在目录下的 zt 目录
  if [ -d "$ZT_DIR" ]; then
    rm -rf "$ZT_DIR" 2>/dev/null || true
  fi
  
  green "[清理] 清理完成!"
}

# 选项2: 安装 ZeroTier 和 ztncui
install_zt_ui() {
  # 安装 ZeroTier
  blue "[安装] 正在安装 ZeroTier..."
  curl -s https://install.zerotier.com/ | sudo bash
  
  # 配置 local.conf
  blue "[安装] 配置 ZeroTier 端口为 8080..."
  local ZT_CONFIG_DIR="/var/lib/zerotier-one"
  local ZT_LOCAL_CONF="$ZT_CONFIG_DIR/local.conf"
  
  # 完全停止服务并清理缓存
  sudo systemctl stop zerotier-one.service 2>/dev/null || true
  sudo killall -9 zerotier-one 2>/dev/null || true
  sleep 3
  
  # 确保目录存在
  sudo mkdir -p "$ZT_CONFIG_DIR"
  
  # 写入配置文件
  sudo bash -c "cat > '$ZT_LOCAL_CONF' << 'EOF'
{
  \"settings\": {
    \"primaryPort\": 8080,
    \"portMappingEnabled\": true
  }
}
EOF"
  
  # 设置正确权限
  sudo chown zerotier-one:zerotier-one "$ZT_LOCAL_CONF"
  sudo chmod 600 "$ZT_LOCAL_CONF"
  
  # 启动服务
  sudo systemctl daemon-reload
  sudo systemctl start zerotier-one.service
  sudo systemctl enable zerotier-one.service
  
  # 等待服务启动
  blue "[安装] 等待 ZeroTier 服务启动..."
  sleep 5
  
  # 检查服务状态
  if sudo systemctl is-active --quiet zerotier-one; then
    green "[安装] ZeroTier 安装完成"
  else
    red "[安装] ZeroTier 服务启动失败"
    return
  fi
  
  # 安装 ztncui
  blue "[安装] 正在安装 ztncui..."
  local ZTNCUI_DEB="ztncui_0.8.6_amd64.deb"
  
  if [ -f "$ZTNCUI_DEB" ]; then
    green "[安装] 检测到本地安装包，直接使用"
  else
    green "[安装] 本地无安装包，从网络下载..."
    curl -O https://s3-us-west-1.amazonaws.com/key-networks/deb/ztncui/1/x86_64/"$ZTNCUI_DEB"
  fi
  
  sudo apt-get install ./"$ZTNCUI_DEB" -y
  
  # 配置 .env
  blue "[安装] 配置 ztncui..."
  sudo systemctl stop ztncui 2>/dev/null || true
  sleep 2
  
  sudo mkdir -p /opt/key-networks/ztncui
  sudo bash -c "cat > /opt/key-networks/ztncui/.env << 'EOF'
NODE_ENV=production
HTTPS_PORT=3443
ZT_TOKEN=
ZT_ADDR=127.0.0.1:8080
EOF"
  
  # 开放端口
  if [ "$release_os" = "centos" ]; then
    sudo firewall-cmd --zone=public --add-port=3443/tcp --permanent
    sudo firewall-cmd --reload
  elif [ "$release_os" = "ubuntu" ] || [ "$release_os" = "debian" ]; then
    sudo ufw allow 3443/tcp
    sudo ufw reload
  fi
  
  sudo systemctl daemon-reload
  sudo systemctl start ztncui
  
  green "[安装] ztncui 安装完成"
  green "[安装] 请访问 https://${SERVER_IP}:3443 登录"
  green "[安装] 账户: admin | 密码: password"
}

# 选项3: 配置 Moon 节点
install_moon() {
  # 检查 ZeroTier 是否安装（检查服务状态或命令）
  if ! command -v zerotier-cli &> /dev/null && ! systemctl is-active --quiet zerotier-one 2>/dev/null; then
    red "[Moon] ZeroTier 未安装或未运行，请先执行选项2"
    return
  fi
  
  # 加入虚拟局域网
  read -p "[Moon] 请输入你的 ztncui 虚拟局域网 ID: " you_net_ID
  sudo zerotier-cli join "$you_net_ID" | grep OK
  
  if [ $? -eq 0 ]; then
    green "[Moon] 成功加入网络: $you_net_ID"
    read -s -n1 -p "[Moon] 请在 ztncui 管理页面确认设备后按任意键继续..."
    
    # 创建 Moon 配置
    cd /var/lib/zerotier-one/
    local ip_addr=$(curl -s ipv4.icanhazip.com)
    blue "[Moon] 检测到公网 IP: $ip_addr"
    
    sudo zerotier-idtool initmoon identity.public > moon.json
    
    if sudo sed -i "s/\[\]/\[ \"$ip_addr\/8080\" \]/" moon.json >/dev/null 2>/dev/null; then
      green "[Moon] moon.json 配置完成"
    else
      red "[Moon] moon.json 配置失败"
      return
    fi
    
    # 开放防火墙端口
    if [ "$release_os" = "centos" ]; then
      sudo firewall-cmd --zone=public --add-port=8080/udp --permanent
      sudo firewall-cmd --reload
    elif [ "$release_os" = "ubuntu" ] || [ "$release_os" = "debian" ]; then
      sudo ufw allow 8080/udp
      sudo ufw reload
    fi
    
    # 生成签名文件
    mkdir -p "$ZT_DIR"
    sudo mv moon.json "$ZT_DIR/"
    
    cd "$ZT_DIR"
    sudo zerotier-idtool genmoon "$ZT_DIR/moon.json"
    
    if ls *.moon 1>/dev/null 2>&1; then
      green "[Moon] Moon 签名文件生成成功"
    else
      red "[Moon] Moon 签名文件生成失败!"
      return
    fi
    
    # 创建符号链接
    sudo mkdir -p /var/lib/zerotier-one/moons.d
    cd /var/lib/zerotier-one/moons.d
    sudo cp -f "$ZT_DIR"/*.moon . 2>/dev/null || true
    sudo cp -f "$ZT_DIR/moon.json" /var/lib/zerotier-one/moon.json 2>/dev/null || true
    
    # 配置 ztncui
    local token=$(sudo cat /var/lib/zerotier-one/authtoken.secret)
    sudo sed -i "s/ZT_TOKEN=/ZT_TOKEN=$token/" /opt/key-networks/ztncui/.env
    
    # 重启服务
    sudo systemctl restart zerotier-one
    sudo systemctl restart ztncui
    
    green "[Moon] Moon 节点配置完成"
  else
    red "[Moon] 加入网络失败，请检查网络 ID"
  fi
}

# 选项4: 迁移控制器生成 planet
migrate_planet() {
  # 检查 zt 目录
  if [ ! -d "$ZT_DIR" ]; then
    red "[Planet] zt 目录不存在，请先执行选项3"
    return
  fi
  
  # 下载 mkmoonworld
  cd "$ZT_DIR"
  blue "[Planet] 准备 mkmoonworld 工具..."
  
  if [ -f "$SCRIPT_DIR/mkmoonworld-x86" ]; then
    green "[Planet] 检测到本地 mkmoonworld-x86，复制到工作目录"
    cp "$SCRIPT_DIR/mkmoonworld-x86" .
  elif [ -f "mkmoonworld-x86" ]; then
    green "[Planet] 检测到本地 mkmoonworld-x86，直接使用"
  else
    green "[Planet] 本地无 mkmoonworld-x86，从网络下载..."
    wget -q https://github.com/kaaass/ZeroTierOne/releases/download/mkmoonworld-1.0/mkmoonworld-x86
  fi
  
  chmod 777 mkmoonworld-x86
  
  # 生成 planet 文件
  blue "[Planet] 生成 planet 文件..."
  ./mkmoonworld-x86 "$ZT_DIR/moon.json"
  mv world.bin "$ZT_DIR/planet"
  
  # 直接复制文件
  sudo cp -f "$ZT_DIR/planet" /var/lib/zerotier-one/planet
  
  # 重启服务
  sudo systemctl restart zerotier-one
  
  # 清理临时文件
  rm -f mkmoonworld-x86 moon.json 2>/dev/null || true
  
  green "[Planet] 控制器迁移完成，planet 文件已生成"
  green "[Planet] planet 文件路径: $ZT_DIR/planet"
}

# 选项5: 安装 HTTP 服务（使用 lighttpd）
install_http() {
  blue "[HTTP] 安装 lighttpd HTTP 服务..."
  
  # 先完全卸载旧版本
  blue "[HTTP] 完全卸载 lighttpd..."
  sudo systemctl stop lighttpd 2>/dev/null || true
  sudo systemctl disable lighttpd 2>/dev/null || true
  
  # 卸载软件包
  if [ "$release_os" = "centos" ]; then
    sudo yum remove -y lighttpd 2>/dev/null || true
  elif [ "$release_os" = "ubuntu" ] || [ "$release_os" = "debian" ]; then
    sudo apt-get remove -y --purge lighttpd 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true
  fi
  
  # 删除软件目录和所有配置
  sudo rm -rf /etc/lighttpd 2>/dev/null || true
  sudo rm -rf /var/log/lighttpd 2>/dev/null || true
  
  # 安装 lighttpd
  if [ "$release_os" = "centos" ]; then
    sudo yum install -y lighttpd 2>/dev/null || true
  elif [ "$release_os" = "ubuntu" ] || [ "$release_os" = "debian" ]; then
    sudo apt-get install -y lighttpd 2>/dev/null || true
  fi
  
  # 检查 lighttpd 是否安装成功
  if ! command -v lighttpd &> /dev/null && [ ! -f /usr/sbin/lighttpd ]; then
    red "[HTTP] lighttpd 安装失败，请手动安装"
    return
  fi
  
  # 备份原配置
  sudo cp /etc/lighttpd/lighttpd.conf /etc/lighttpd/lighttpd.conf.bak 2>/dev/null || true
  
  # 检查端口是否被占用，如果是则杀死占用进程
  blue "[HTTP] 检查端口 8000 是否被占用..."
  PORT_PID=$(sudo ss -tlnp | grep ":8000" | awk '{print $7}' | cut -d',' -f1 | cut -d'=' -f2)
  if [ -n "$PORT_PID" ]; then
    blue "[HTTP] 端口 8000 被进程 $PORT_PID 占用，正在终止..."
    sudo kill -9 "$PORT_PID" 2>/dev/null || true
    sleep 2
  fi
  
  # 设置 zt 目录权限（确保 lighttpd 可以访问）
  sudo chown -R www-data:www-data "$SCRIPT_DIR/zt" 2>/dev/null || true
  sudo chmod -R 755 "$SCRIPT_DIR/zt" 2>/dev/null || true
  
  # 修复可能被误识别为目录的文件（移除末尾斜杠问题）
  for file in "$SCRIPT_DIR/zt"/*; do
    if [ -f "$file" ] && [ ! -d "$file" ]; then
      # 确保是文件而不是目录
      sudo chmod 644 "$file" 2>/dev/null || true
    fi
  done
  
  # 确保 zt 目录存在
  if [ ! -d "$SCRIPT_DIR/zt" ]; then
    sudo mkdir -p "$SCRIPT_DIR/zt"
    sudo chown www-data:www-data "$SCRIPT_DIR/zt"
    sudo chmod 755 "$SCRIPT_DIR/zt"
  fi
  
  # 修改主配置文件（使用sed替换变量）
  sudo bash -c "cat > /etc/lighttpd/lighttpd.conf << 'EOF'
server.modules = (
    \"mod_indexfile\",
    \"mod_access\",
    \"mod_alias\",
    \"mod_redirect\",
)

server.document-root        = \"__SCRIPT_DIR__/zt\"
server.errorlog             = \"/var/log/lighttpd/error.log\"
server.pid-file             = \"/run/lighttpd.pid\"
server.port                 = 8000
server.bind                 = \"0.0.0.0\"
dir-listing.activate        = \"enable\"
EOF"
  
  # 替换变量
  sudo sed -i "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" /etc/lighttpd/lighttpd.conf
  
  # 重启服务
  sudo systemctl restart lighttpd
  
  # 开放防火墙端口
  if [ "$release_os" = "centos" ]; then
    sudo firewall-cmd --zone=public --add-port=8000/tcp --permanent
    sudo firewall-cmd --reload
  elif [ "$release_os" = "ubuntu" ] || [ "$release_os" = "debian" ]; then
    sudo ufw allow 8000/tcp
    sudo ufw reload
  fi
  
  # 检查服务是否启动
  if sudo ss -tlnp | grep -q ":8000"; then
    green "[HTTP] HTTP 服务安装完成"
    green "[HTTP] 下载地址: http://${SERVER_IP}:8000/"
  else
    red "[HTTP] HTTP 服务启动失败"
    sudo systemctl status lighttpd 2>&1 || true
  fi
}

# ==================== 菜单函数 ====================
show_menu() {
  clear
  echo ""
  green "╔══════════════════════════════════════════════════════════════╗"
  green "║            ZeroTier + ztncui 管理工具 v2.0                  ║"
  green "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  blue "  服务器 IP: ${SERVER_IP}"
  blue "  脚本目录: ${SCRIPT_DIR}"
  echo ""
  echo "  1. 🔧 清理旧版本"
  echo "  2. 🚀 安装 ZeroTier + ztncui"
  echo "  3. 🌙 配置 Moon 节点"
  echo "  4. 🪐 迁移控制器生成 planet"
  echo "  5. 🌐 安装 HTTP 下载服务"
  echo "  6. ✅ 一键完成全部操作"
  echo "  0. 🚪 退出"
  echo ""
  read -p "  请输入选择 [0-6]: " choice
  echo ""
}

# 选项6: 一键完成全部操作
run_all() {
  cleanup
  echo ""
  install_zt_ui
  echo ""
  read -s -n1 -p "按任意键继续配置 Moon 节点..."
  echo ""
  install_moon
  echo ""
  read -s -n1 -p "按任意键继续迁移控制器..."
  echo ""
  migrate_planet
  echo ""
  install_http
  echo ""
  
  green "╔══════════════════════════════════════════════════════════════╗"
  green "║                      全部操作完成!                           ║"
  green "╠══════════════════════════════════════════════════════════════╣"
  green "║  🌐 ztncui 管理地址: https://${SERVER_IP}:3443              ║"
  green "║     账户: admin | 密码: password                            ║"
  green "║                                                              ║"
  green "║  📁 planet 文件: http://${SERVER_IP}/zt/planet              ║"
  green "║                                                              ║"
  green "║  客户端替换 planet 文件后重启 ZeroTier 即可连接到私有网络     ║"
  green "╚══════════════════════════════════════════════════════════════╝"
}

# ==================== 主函数 ====================
main() {
  detect_system
  
  while true; do
    show_menu
    
    case $choice in
      1)
        cleanup
        ;;
      2)
        install_zt_ui
        ;;
      3)
        install_moon
        ;;
      4)
        migrate_planet
        ;;
      5)
        install_http
        ;;
      6)
        run_all
        ;;
      0)
        green "感谢使用！再见~"
        exit 0
        ;;
      *)
        red "无效选择，请输入 0-6"
        ;;
    esac
    
    echo ""
    read -s -n1 -p "按任意键继续..."
  done
}

# 执行主函数
main
