#!/bin/bash
# ==============================================================================
# 移动云电脑 Ubuntu 22.04 GNOME 桌面一键配置脚本
# 适用环境：通过 reinstall.bat / DD 脚本重装后的精简 Ubuntu 22.04 Server
# 功能：修复内核驱动、卸载 QXL 避开显存溢出、安装 GNOME+LightDM、中文环境及字库
# ==============================================================================

set -e

# 自定义配置参数（可通过环境变量传入，未传入则使用默认值）
NEW_USER="${NEW_USER:-dodo}"
NEW_PASS="${NEW_PASS:-dodo1234}"

# 必须以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m[错误] 请使用 root 用户或 sudo 执行此脚本！\033[0m"
    exit 1
fi

echo -e "\033[32m>>> 1. 更新软件源并配置非交互模式...\033[0m"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

echo -e "\033[32m>>> 2. 预设 LightDM 为默认显示管理器（跳过交互弹窗）...\033[0m"
apt-get install -y debconf-utils
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections

echo -e "\033[32m>>> 3. 安装完整通用内核、Xorg 核心服务与精简 GNOME 桌面...\033[0m"
apt-get install -y \
    linux-image-generic-hwe-22.04 \
    xserver-xorg-core \
    spice-vdagent \
    ubuntu-desktop-minimal \
    lightdm \
    lightdm-gtk-greeter \
    ubuntu-wallpapers

echo -e "\033[32m>>> 4. 彻底卸载 QXL 驱动，回退 modesetting（根治 16MB 显存溢出报错）...\033[0m"
apt-get purge -y xserver-xorg-video-qxl
rm -f /etc/default/grub.d/*nomodeset*.cfg
sed -i 's/ nomodeset//g' /etc/default/grub
update-grub

echo -e "\033[32m>>> 5. 安装中文语言支持与开源中文字库...\033[0m"
apt-get install -y \
    language-pack-zh-hans \
    language-pack-gnome-zh-hans \
    fonts-noto-cjk \
    fonts-wqy-microhei \
    fonts-wqy-zenhei \
    ibus-libpinyin

# 配置全局中文区域设置与优先级
locale-gen zh_CN.UTF-8
localectl set-locale LANG=zh_CN.UTF-8
update-locale LANG=zh_CN.UTF-8 LANGUAGE="zh_CN:zh"
fc-cache -fv

echo -e "\033[32m>>> 6. 美化 LightDM 登录界面（避免 XFCE 老鼠壁纸）...\033[0m"
if [ -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
    sed -i 's|^#\?background =.*|background = /usr/share/backgrounds/warty-final-ubuntu.png|' /etc/lightdm/lightdm-gtk-greeter.conf
    sed -i 's|^#\?theme-name =.*|theme-name = Yaru-dark|' /etc/lightdm/lightdm-gtk-greeter.conf
    sed -i 's|^#\?icon-theme-name =.*|icon-theme-name = Yaru|' /etc/lightdm/lightdm-gtk-greeter.conf
fi

echo -e "\033[32m>>> 7. 配置普通用户及无限制 sudo 权限...\033[0m"
if id "$NEW_USER" &>/dev/null; then
    echo "用户 $NEW_USER 已存在，跳过创建。"
else
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_PASS" | chpasswd
    echo "已创建用户: $NEW_USER ，默认密码为: $NEW_PASS"
fi

usermod -aG sudo "$NEW_USER"
echo "$NEW_USER ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$NEW_USER"
chmod 440 "/etc/sudoers.d/$NEW_USER"

echo -e "\033[32m>>> 8. 重置 Snap 版 Firefox 以支持中文字体...\033[0m"
if command -v snap &>/dev/null; then
    snap remove --purge firefox || true
    snap install firefox || true
fi

echo -e "\033[32m>>> 9. 设置开机默认进入图形界面...\033[0m"
systemctl set-default graphical.target

echo -e "\033[32m====================================================\033[0m"
echo -e "\033[32m 部署完成！系统即将在 5 秒后自动重启进入图形桌面... \033[0m"
echo -e "\033[32m 登录用户名: $NEW_USER\033[0m"
echo -e "\033[32m 登录密码:   $NEW_PASS\033[0m"
echo -e "\033[32m====================================================\033[0m"

sleep 5
reboot
