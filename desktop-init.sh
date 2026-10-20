#!/bin/bash
# ==============================================================================
# 移动云电脑 Ubuntu 全版本通用 GNOME 桌面一键配置脚本
# 功能：动态内核匹配、QXL驱动冲突修复、用户授权、中文字库补全、4GB Swap
# ==============================================================================

set -e

# 1. 检查 root 运行权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m[错误] 请以 root 权限运行此脚本！\033[0m"
    exit 1
fi

echo -e "\033[32m>>> [1/9] 检查与配置普通用户权限...\033[0m"
# 过滤系统中的普通用户（UID 在 1000 到 59999 之间，排除 nobody）
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1}' /etc/passwd)

if [ -n "$EXISTING_USERS" ]; then
    echo "检测到现有用户: $EXISTING_USERS"
    for u in $EXISTING_USERS; do
        echo "正在为 [$u] 补齐主目录并配置 sudoers..."
        mkhomedir_helper "$u" 2>/dev/null || true
        usermod -aG sudo -s /bin/bash "$u"
        echo "$u ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$u"
        chmod 440 "/etc/sudoers.d/$u"
        chown -R "$u:$u" "/home/$u" 2>/dev/null || true
    done
else
    echo "未检测到普通用户，开始交互创建..."
    # 兼容 curl | bash 管道运行时的交互输入
    INPUT_DEV="/dev/tty"
    if [ ! -c "$INPUT_DEV" ]; then
        INPUT_DEV="/dev/stdin"
    fi

    TARGET_USER=""
    while [ -z "$TARGET_USER" ]; do
        read -rp "请输入要新建的普通用户名: " TARGET_USER < "$INPUT_DEV"
    done

    TARGET_PASS=""
    while [ -z "$TARGET_PASS" ]; do
        read -rsp "请输入该用户的登录密码: " TARGET_PASS < "$INPUT_DEV"
        echo ""
    done

    useradd -m -s /bin/bash "$TARGET_USER"
    echo "$TARGET_USER:$TARGET_PASS" | chpasswd
    usermod -aG sudo "$TARGET_USER"
    echo "$TARGET_USER ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$TARGET_USER"
    chmod 440 "/etc/sudoers.d/$TARGET_USER"
    echo "用户 [$TARGET_USER] 创建并授权完成。"
fi

echo -e "\033[32m>>> [2/9] 配置非交互式 apt 源更新...\033[0m"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

echo -e "\033[32m>>> [3/9] 预配置 LightDM 默认选择（防止弹窗阻断）...\033[0m"
apt-get install -y debconf-utils
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections

echo -e "\033[32m>>> [4/9] 动态匹配版本并安装全量内核与 GNOME 基础组件...\033[0m"
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

echo -e "\033[32m>>> [5/9] 剔除 QXL 显存冲突驱动并清理引导参数...\033[0m"
# 卸载旧式 QXL 驱动，强制走 modesetting 规避 16MB 显存溢出
apt-get purge -y xserver-xorg-video-qxl || true
# 清除 nomodeset，防止系统卡死在 tty1
rm -f /etc/default/grub.d/*nomodeset*.cfg /etc/xprofile
sed -i 's/ nomodeset//g' /etc/default/grub
update-grub

# 清理可能残留的 XFCE 会话文件，锁定 GNOME
rm -f /usr/share/xsessions/xfce.desktop
update-alternatives --set x-session-manager /usr/bin/gnome-session 2>/dev/null || true

echo -e "\033[32m>>> [6/9] 安装中文语言包、开源中文字库与拼音输入法...\033[0m"
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

echo -e "\033[32m>>> [7/9] 配置 LightDM 原生暗色风格（移除老鼠壁纸残留）...\033[0m"
if [ -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
    sed -i 's|^#\?background =.*|background = /usr/share/backgrounds/warty-final-ubuntu.png|' /etc/lightdm/lightdm-gtk-greeter.conf
    sed -i 's|^#\?theme-name =.*|theme-name = Yaru-dark|' /etc/lightdm/lightdm-gtk-greeter.conf
    sed -i 's|^#\?icon-theme-name =.*|icon-theme-name = Yaru|' /etc/lightdm/lightdm-gtk-greeter.conf
fi

echo -e "\033[32m>>> [8/9] 解决 Snap 版 Firefox 方块乱码...\033[0m"
if command -v snap &>/dev/null; then
    snap remove --purge firefox || true
    snap install firefox || true
fi

echo -e "\033[32m>>> [9/9] 创建并持久化配置 4GB 虚拟内存 (Swap)...\033[0m"
if [ -f /swapfile ]; then
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
fi

# 分配 4G 空间（优先 fallocate，失败降级 dd）
if ! fallocate -l 4G /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
fi

chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# 写入 fstab 开机自动挂载
if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 设置系统更倾向使用物理内存（swappiness=10）
sysctl vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf

# 设置默认启动到图形桌面
systemctl set-default graphical.target

echo -e "\033[32m====================================================\033[0m"
echo -e "\033[32m 安装优化完成！4GB 虚拟内存已挂载，显存保护已启用。 \033[0m"
echo -e "\033[32m 系统将在 5 秒后自动重启并进入图形桌面...          \033[0m"
echo -e "\033[32m====================================================\033[0m"

sleep 5
reboot
