#!/bin/bash
# ==============================================================================
# 移动云电脑 Ubuntu 全版本通用桌面部署脚本
# ==============================================================================

set -e

# 1. 检查 root 运行权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m[错误] 请以 root 权限执行此脚本！\033[0m"
    exit 1
fi

# 2. 静默安装与反阻断配置
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# 3. 等待后台 apt-daily 锁释放，防止刚开机冲突闪退
echo "正在检测后台 APT 锁状态..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "后台正在执行系统初始化任务，等待锁释放中 (5秒)..."
    sleep 5
done

echo -e "\033[32m>>> [1/8] 检测并配置 DD 预设的普通用户权限...\033[0m"
# 自动抓取系统中 UID >= 1000 的普通用户（如 cc），排除 nobody
DD_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1; exit}' /etc/passwd)

if [ -n "$DD_USER" ]; then
    echo -e "检测到 DD 阶段创建的用户: \033[33m$DD_USER\033[0m"
    echo "保留原密码不变，正在为其补齐环境与 sudoers 授权..."
    mkhomedir_helper "$DD_USER" 2>/dev/null || true
    usermod -aG sudo -s /bin/bash "$DD_USER"
    echo "$DD_USER ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$DD_USER"
    chmod 440 "/etc/sudoers.d/$DD_USER"
    chown -R "$DD_USER:$DD_USER" "/home/$DD_USER" 2>/dev/null || true
    LOGIN_USER="$DD_USER"
else
    echo "未检测到 DD 普通用户，正在自动创建默认用户 cc..."
    LOGIN_USER="cc"
    useradd -m -s /bin/bash "$LOGIN_USER"
    echo "$LOGIN_USER:123456" | chpasswd
    usermod -aG sudo "$LOGIN_USER"
    echo "$LOGIN_USER ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$LOGIN_USER"
    chmod 440 "/etc/sudoers.d/$LOGIN_USER"
fi

echo -e "\033[32m>>> [2/8] 更新系统源并预设 LightDM...\033[0m"
apt-get update -y
apt-get install -y debconf-utils
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections

echo -e "\033[32m>>> [3/8] 动态匹配版本并安装通用内核与 GNOME 基础组件...\033[0m"
UBUNTU_VER=$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release 2>/dev/null || lsb_release -rs 2>/dev/null || echo "")

if [ -n "$UBUNTU_VER" ] && apt-cache show "linux-image-generic-hwe-${UBUNTU_VER}" &>/dev/null; then
    KERNEL_PKG="linux-image-generic-hwe-${UBUNTU_VER}"
elif [ -n "$UBUNTU_VER" ] && apt-cache show "linux-generic-hwe-${UBUNTU_VER}" &>/dev/null; then
    KERNEL_PKG="linux-generic-hwe-${UBUNTU_VER}"
else
    KERNEL_PKG="linux-image-generic"
fi
echo "当前匹配安装的内核包为: $KERNEL_PKG"

apt-get install -y \
    "$KERNEL_PKG" \
    xserver-xorg-core \
    spice-vdagent \
    ubuntu-desktop-minimal \
    lightdm \
    lightdm-gtk-greeter \
    ubuntu-wallpapers

echo -e "\033[32m>>> [4/8] 剔除 QXL 显存冲突驱动并恢复 modesetting 内存渲染...\033[0m"
# 卸载旧式驱动规避 16MB 显存溢出
apt-get purge -y xserver-xorg-video-qxl || true
# 清理可能导致卡死在 tty1 的 nomodeset 参数
rm -f /etc/default/grub.d/*nomodeset*.cfg /etc/xprofile
sed -i -E 's/\bnomodeset\b//g' /etc/default/grub
update-grub

# 清理残留桌面入口，锁定 GNOME
rm -f /usr/share/xsessions/xfce.desktop
update-alternatives --set x-session-manager /usr/bin/gnome-session 2>/dev/null || true

echo -e "\033[32m>>> [5/8] 安装中文环境、思源/文泉驿字库与拼音输入法...\033[0m"
apt-get install -y \
    language-pack-zh-hans \
    language-pack-gnome-zh-hans \
    fonts-noto-cjk \
    fonts-wqy-microhei \
    fonts-wqy-zenhei \
    ibus-libpinyin

locale-gen zh_CN.UTF-8
localectl set-locale LANG=zh_CN.UTF-8
update-locale LANG=zh_CN.UTF-8 LANGUAGE="zh_CN:zh"
fc-cache -fv

echo -e "\033[32m>>> [6/8] 美化 LightDM 界面（切换 Ubuntu 原生暗色风格）...\033[0m"
if [ -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
    sed -i 's|^#\?background =.*|background = /usr/share/backgrounds/warty-final-ubuntu.png|' /etc/lightdm/lightdm-gtk-greeter.conf
    sed -i 's|^#\?theme-name =.*|theme-name = Yaru-dark|' /etc/lightdm/lightdm-gtk-greeter.conf
    sed -i 's|^#\?icon-theme-name =.*|icon-theme-name = Yaru|' /etc/lightdm/lightdm-gtk-greeter.conf
fi

echo -e "\033[32m>>> [7/8] 同步重置 Firefox 沙盒字库（加设 60 秒网络超时防挂起）...\033[0m"
if command -v snap &>/dev/null; then
    timeout 60 snap remove --purge firefox || true
    timeout 60 snap install firefox || echo "Snap 网络较慢，已跳过 Firefox 重装（不影响桌面正常运行）"
fi

echo -e "\033[32m>>> [8/8] 创建并持久化配置 4GB 虚拟内存 (Swap)...\033[0m"
if ! grep -q '/swapfile' /proc/swaps; then
    [ -f /swapfile ] && rm -f /swapfile
    if ! fallocate -l 4G /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
fi

if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 优化内存调度阈值（swappiness=10）
sysctl vm.swappiness=10 >/dev/null
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf

# 设为默认图形模式自启
systemctl set-default graphical.target

echo -e "\033[32m====================================================\033[0m"
echo -e "\033[32m 安装成功！系统将在 5 秒后自动重启...                \033[0m"
echo -e "\033[32m 登录用户名: \033[33m$LOGIN_USER\033[0m"
echo -e "\033[32m 登录密码:   使用您在 DD 重装时自己设定的密码即可     \033[0m"
echo -e "\033[32m====================================================\033[0m"

sleep 5
reboot
