#!/bin/bash
# ==============================================================================
# ZeroTier + ztncui 一键安装脚本
# 功能: 自动完成 ztncui 节点安装、Moon 节点配置、控制器迁移
# 作者: 借鉴自 dajiangfu，经优化改进
# 版本: 1.0
# ==============================================================================

# 获取脚本所在目录
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ZT_DIR="${SCRIPT_DIR}/zt"


# ==================== 颜色输出函数 ====================
function blue() {
  echo -e "\033[34m\033[01m$1\033[0m"
}

function green() {
  echo -e "\033[32m\033[01m$1\033[0m"
}

function red() {
  echo -e "\033[31m\033[01m$1\033[0m"
}

function version_lt() {
  test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1";
}


# ==================== 系统检测 ====================
# 检测操作系统类型 (CentOS / Debian / Ubuntu)
# 代码来源: 秋水逸冰 SS 脚本
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

# 设置系统包管理器
if [ "$release_os" == "centos" ]; then
  systemPackage_os="yum"
elif [ "$release_os" == "ubuntu" ] || [ "$release_os" == "debian" ]; then
  systemPackage_os="apt"
fi

green "[系统检测] 当前系统: ${release_os}, 包管理器: ${systemPackage_os}"


# ==================== 安装函数 ====================

# 安装 ZeroTier 服务
function install_zerotier() {
  blue "[步骤1/3] 正在安装 ZeroTier 软件..."
  curl -s https://install.zerotier.com/ | sudo bash
  
  # 配置 local.conf 支持多个端口
  blue "[步骤1/3] 配置 ZeroTier local.conf 多端口支持..."
  local ZT_CONFIG_DIR="/var/lib/zerotier-one"
  local ZT_LOCAL_CONF="$ZT_CONFIG_DIR/local.conf"
  
  # 停止服务以便修改配置
  systemctl stop zerotier-one.service 2>/dev/null || true
  
  # 创建 local.conf 配置文件，支持端口 8080, 9993, 19995
  cat > "$ZT_LOCAL_CONF" << EOF
{
  "settings": {
    "primaryPort": 9993,
    "secondaryPort": 8080,
    "tertiaryPort": 19995,
    "portMappingEnabled": true
  }
}
EOF
  
  # 设置正确的权限
  chown zerotier-one:zerotier-one "$ZT_LOCAL_CONF"
  chmod 600 "$ZT_LOCAL_CONF"
  
  blue "[步骤1/3] 正在启动 ZeroTier 服务..."
  systemctl start zerotier-one.service
  systemctl enable zerotier-one.service
  
  green "[步骤1/3] ZeroTier 安装并启动完成"
  green "[步骤1/3] 已配置端口映射: 8080, 9993, 19995"
}

# 安装 ztncui 管理界面
function install_ztncui() {
  blue "[步骤1/3] 正在安装 ztncui 管理界面..."
  
  local ZTNCUI_DEB="ztncui_0.8.6_amd64.deb"
  
  # 优先使用本地安装包
  if [ -f "$ZTNCUI_DEB" ]; then
    green "[步骤1/3] 检测到本地安装包，直接使用"
  else
    green "[步骤1/3] 本地无安装包，从网络下载..."
    curl -O https://s3-us-west-1.amazonaws.com/key-networks/deb/ztncui/1/x86_64/"$ZTNCUI_DEB"
  fi
  
  # 安装软件包
  sudo apt-get install ./"$ZTNCUI_DEB" -y
  
  # 配置 HTTPS 端口 - 使用符号链接方式
  blue "[步骤1/3] 配置 ztncui HTTPS 端口..."
  mkdir -p /zt
  echo "HTTPS_PORT = 3443" > $ZT_DIR/env
  
  # 创建符号链接
  ln -sf $ZT_DIR/env /opt/key-networks/ztncui/.env
  
  # 重启服务使配置生效
  blue "[步骤1/3] 重启 ztncui 服务..."
  sudo systemctl restart ztncui
  
  green "[步骤1/3] ztncui 安装完成"
}

# 创建 ztncui 节点 (调用上述两个安装函数)
function create_ztncui() {
  install_zerotier
  install_ztncui
}


# ==================== Moon 节点配置 ====================

function create_moon() {
  blue "[步骤2/3] 开始配置 Moon 节点..."
  
  # 加入虚拟局域网
  read -p "[步骤2/3] 请输入你的 ztncui 虚拟局域网 ID: " you_net_ID
  zerotier-cli join "$you_net_ID" | grep OK
  
  if [ $? -eq 0 ]; then
    green "[步骤2/3] 成功加入网络: $you_net_ID"
    read -s -n1 -p "[步骤2/3] 请在 ztncui 管理页面确认设备后按任意键继续..."
    
    # 创建 Moon 配置
    blue "[步骤2/3] 生成 Moon 配置文件..."
    cd /var/lib/zerotier-one/
    
    # 获取公网 IP 并生成 moon.json
    local ip_addr=$(curl -s ipv4.icanhazip.com)
    blue "[步骤2/3] 检测到公网 IP: $ip_addr"
    
    zerotier-idtool initmoon identity.public > moon.json
    
    # 修改 moon.json 配置，支持三个端口
    if sed -i "s/\[\]/\[ \"$ip_addr\/9993\", \"$ip_addr\/8080\", \"$ip_addr\/19995\" \]/" moon.json >/dev/null 2>/dev/null; then
      green "[步骤2/3] moon.json 配置完成"
      green "[步骤2/3] moon.json 已配置端口: 9993, 8080, 19995"
    else
      red "[步骤2/3] moon.json 配置失败"
      exit 1
    fi
    
    # 防火墙配置 - 开放三个端口
    if [ "$release_os" == "centos" ]; then
      blue "[步骤2/3] 配置 CentOS 防火墙..."
      firewall-cmd --zone=public --add-port=9993/udp --permanent
      firewall-cmd --zone=public --add-port=8080/udp --permanent
      firewall-cmd --zone=public --add-port=19995/udp --permanent
      firewall-cmd --reload
    elif [ "$release_os" == "ubuntu" ] || [ "$release_os" == "debian" ]; then
      blue "[步骤2/3] 配置 Ubuntu/Debian 防火墙..."
      ufw allow 9993/udp
      ufw allow 8080/udp
      ufw allow 19995/udp
      ufw reload
    fi
    
    # 生成签名文件
    blue "[步骤2/3] 生成 Moon 签名文件..."
    zerotier-idtool genmoon moon.json
    
    # 创建 zt 目录用于存储配置文件
    blue "[步骤2/3] 创建配置文件存储目录 $ZT_DIR/..."
    mkdir -p $ZT_DIR/moons.d
    
    # 将 moon.json 移动到 $ZT_DIR/ 目录
    mv moon.json $ZT_DIR/
    
    # 生成签名文件到 $ZT_DIR/moons.d/
    blue "[步骤2/3] 生成 Moon 签名文件..."
    zerotier-idtool genmoon $ZT_DIR/moon.json
    
    # 移动 .moon 文件到 $ZT_DIR/moons.d/
    mv /var/lib/zerotier-one/*.moon $ZT_DIR/moons.d/ 2>/dev/null || true
    
    # 创建符号链接
    blue "[步骤2/3] 创建符号链接..."
    ln -sf $ZT_DIR/moon.json /var/lib/zerotier-one/moon.json
    ln -sf $ZT_DIR/moons.d /var/lib/zerotier-one/moons.d
    
    # 重启服务
    blue "[步骤2/3] 重启 ZeroTier 服务..."
    systemctl restart zerotier-one
    
    # 配置 ztncui 连接
    blue "[步骤2/3] 配置 ztncui 与 ZeroTier 连接..."
    local token=$(cat /var/lib/zerotier-one/authtoken.secret)
    echo "ZT_TOKEN=$token" >> $ZT_DIR/env
    echo "ZT_ADDR=127.0.0.1:9993" >> $ZT_DIR/env
    echo "NODE_ENV=production" >> $ZT_DIR/env
    
    green "[步骤2/3] Moon 节点配置完成"
    green "[步骤2/3] moons.d 目录已生成，路径: /var/lib/zerotier-one/"
    
  else
    red "[步骤2/3] 加入网络失败，请检查网络 ID 是否正确"
    exit 1
  fi
}


# ==================== 控制器迁移 ====================

function migrate_controller() {
  blue "[步骤3/3] 开始迁移控制器..."
  
  # 确保 $ZT_DIR/ 目录存在
  mkdir -p /zt
  
  # 下载 mkmoonworld 工具到 $ZT_DIR/ 目录
  cd /zt
  blue "[步骤3/3] 下载 mkmoonworld 工具..."
  wget -q https://github.com/kaaass/ZeroTierOne/releases/download/mkmoonworld-1.0/mkmoonworld-x86
  chmod 777 mkmoonworld-x86
  
  # 生成 planet 文件到 $ZT_DIR/ 目录
  blue "[步骤3/3] 生成 planet 文件..."
  ./mkmoonworld-x86 $ZT_DIR/moon.json
  
  # 重命名并移动到 $ZT_DIR/
  mv world.bin $ZT_DIR/planet
  
  # 创建符号链接到 ZeroTier 目录
  blue "[步骤3/3] 创建 planet 符号链接..."
  ln -sf $ZT_DIR/planet /var/lib/zerotier-one/planet
  
  # 重启服务
  blue "[步骤3/3] 重启 ZeroTier 服务..."
  systemctl restart zerotier-one
  
  green "[步骤3/3] 控制器迁移完成"
}


# ==================== 主执行函数 ====================

function main() {
  # 脚本介绍
  clear
  echo ""
  green "╔══════════════════════════════════════════════════════════════╗"
  green "║              ZeroTier + ztncui 一键安装脚本                   ║"
  green "╠══════════════════════════════════════════════════════════════╣"
  green "║  本脚本将自动完成以下步骤:                                    ║"
  green "║  1. 安装 ZeroTier 和 ztncui 管理界面                          ║"
  green "║  2. 配置 Moon 中转节点                                        ║"
  green "║  3. 迁移控制器并生成 planet 文件                              ║"
  green "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  
  # 步骤1: 安装基础软件
  create_ztncui
  echo ""
  red "⚠️  步骤1完成!"
  red "请访问 https://服务器IP:3443 登录 ztncui 控制台"
  red "账户: admin  | 密码: password"
  red "创建一个新的虚拟局域网并记录网络 ID"
  read -s -n1 -p "完成后按任意键继续步骤2..."
  echo ""
  
  # 步骤2: 配置 Moon 节点
  create_moon
  echo ""
  read -s -n1 -p "步骤2完成，按任意键继续步骤3..."
  echo ""
  
  # 步骤3: 迁移控制器
  migrate_controller
  echo ""
  
  # 完成提示
  green "╔══════════════════════════════════════════════════════════════╗"
  green "║                      安装完成!                               ║"
  green "╠══════════════════════════════════════════════════════════════╣"
  green "║  1. 已安装 ZeroTier 和 ztncui                                ║"
  green "║  2. Moon 节点配置完成                                        ║"
  green "║  3. 控制器迁移完成，生成了 planet 文件                        ║"
  green "║                                                              ║"
  green "║  📁 moons.d 目录路径: /var/lib/zerotier-one/moons.d/         ║"
  green "║  📁 planet 文件路径: /home/planet                            ║"
  green "║                                                              ║"
  green "║  请将 planet 文件下载到客户端并替换                            ║"
  green "╚══════════════════════════════════════════════════════════════╝"
}


# 执行主函数
main
