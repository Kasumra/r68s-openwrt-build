#!/bin/bash
# =========================================================
# R68S OpenWrt 固件 — Flippy 格式打包脚本
# =========================================================
# 将 LEDE 编译产物打包为 R68S 可刷写固件
#
# 参考: https://github.com/unifreq/openwrt_packit
#        mk_rk3568_r68s.sh
#
# R68S 网口布局（从左到右）:
#   eth1(千兆WAN)  eth0(千兆)  eth3(2.5G)  eth2(2.5G)
# =========================================================
set -euo pipefail

GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[*]${NC} $1"; }
step() { echo -e "\n${BLUE}[${1}]${NC}"; }

# =========================================================
# 配置参数
# =========================================================
SOC="rk3568"
BOARD="r68s"
OPENWRT_VER="${OPENWRT_VER:-24.10}"
KERNEL_VERSION="${KERNEL_VERSION:-6.1}"

WORK_DIR="${1:-/tmp/r68s-firmware}"
BUILD_DIR="${2:-bin/targets/rockchip/armv8}"

# =========================================================
# 网口 MAC 地址（可自定义）
# =========================================================
# eth0 (千兆LAN):  默认随机
# eth1 (千兆WAN):  默认随机
# eth2 (2.5G LAN): 默认随机
# eth3 (2.5G WAN): 默认随机

# =========================================================
step "1: 创建打包工作区"
# =========================================================
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{rootfs,firmware,boot,output}
log "工作目录: $WORK_DIR"

# =========================================================
step "2: 查找编译产物"
# =========================================================
# LEDE 编译输出通常在: bin/targets/rockchip/armv8/
ROOTFS_GZ=$(find "$BUILD_DIR" -name "openwrt-rockchip-armv8-*-rootfs.tar.gz" 2>/dev/null | head -1)
KERNEL_IMG=$(find "$BUILD_DIR" -name "*Image*" 2>/dev/null | head -1)
DTB_FILE=$(find "$BUILD_DIR" -name "*.dtb" 2>/dev/null | head -1)

if [ -z "$ROOTFS_GZ" ]; then
    # 尝试另一种命名
    ROOTFS_GZ=$(find bin/targets -name "*rootfs.tar.gz" 2>/dev/null | head -1)
fi

if [ -z "$ROOTFS_GZ" ]; then
    # 查找 squashfs 镜像
    ROOTFS_GZ=$(find bin/targets/rockchip -name "*.img.gz" -o -name "squashfs*.img" 2>/dev/null | head -1)
    log "未找到 rootfs.tar.gz，使用镜像: $ROOTFS_GZ"
fi

if [ -z "$KERNEL_IMG" ]; then
    KERNEL_IMG=$(find bin/targets/rockchip -name "Image" -o -name "*.itb" 2>/dev/null | head -1)
fi

log "RootFS:  $ROOTFS_GZ"
log "Kernel:  $KERNEL_IMG"
log "DTB:     $DTB_FILE"

# =========================================================
step "3: 解包 rootfs"
# =========================================================
if [ -n "$ROOTFS_GZ" ]; then
    if echo "$ROOTFS_GZ" | grep -q '\.gz$'; then
        gunzip -c "$ROOTFS_GZ" > "$WORK_DIR/rootfs.img"
    else
        cp "$ROOTFS_GZ" "$WORK_DIR/rootfs.img"
    fi
    log "rootfs 解包完成"
else
    log "警告: 未找到 rootfs，仅复制原始产物"
    find bin/targets -type f \( -name "*.img" -o -name "*.gz" \) | while read f; do
        cp -v "$f" "$WORK_DIR/output/"
    done
    exit 0
fi

# =========================================================
step "4: R68S 特定配置"
# =========================================================
# 创建 R68S 配置文件到 rootfs
ROOTFS_MOUNT="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_MOUNT"

# 4.1 网络配置（R68S 特色网口布局）
cat > "$WORK_DIR/network-config" << 'EOF'
# R68S 网络配置
# eth0: 千兆 LAN  (接内网设备)
# eth1: 千兆 WAN  (接光猫/上级路由)
# eth2: 2.5G LAN  (接 NAS/PC)
# eth3: 2.5G WAN  (接光猫 2.5G口)

config interface 'loopback'
    option ifname 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fdeb:1533:0a4d::/48'

config interface 'lan'
    option type 'bridge'
    option ifname 'eth0 eth2'
    option proto 'static'
    option ipaddr '192.168.2.1'
    option netmask '255.255.255.0'
    option ip6assign '60'
    option broadcast '192.168.2.255'

config interface 'wan'
    option ifname 'eth1'
    option proto 'dhcp'

config interface 'wan2'
    option ifname 'eth3'
    option proto 'dhcp'
EOF

log "R68S 网络配置已生成"

# 4.2 创建 fstab（支持 eMMC + TF 卡）
cat > "$WORK_DIR/fstab" << 'EOF'
# R68S 挂载表
# 系统在 TF 卡上运行，eMMC 作为数据盘
/dev/mmcblk0p1  /boot           auto    defaults    0 0
/dev/mmcblk0p2  /               auto    defaults    0 0
# eMMC 数据分区（可选）
# /dev/mmcblk1p1  /mnt/emmc       ext4    defaults    0 0
EOF

# =========================================================
step "5: 打包为镜像"
# =========================================================

# 计算需要的镜像大小
ROOTFS_SIZE_BYTES=$(stat -f%z "$WORK_DIR/rootfs.img" 2>/dev/null || stat -c%s "$WORK_DIR/rootfs.img" 2>/dev/null || echo 0)
ROOTFS_SIZE_MB=$(( ROOTFS_SIZE_BYTES / 1024 / 1024 + 256 ))  # +256MB 余量

log "RootFS 大小: ${ROOTFS_SIZE_MB}MB"

# 创建空镜像（让结构简单：先拷贝 rootfs，后面再考虑分区表）
FINAL_IMG="$WORK_DIR/output/openwrt_${SOC}_${BOARD}_${OPENWRT_VER}_k${KERNEL_VERSION}.img"

# 创建足够大的镜像文件
dd if=/dev/zero of="$FINAL_IMG" bs=1M count="$ROOTFS_SIZE_MB" 2>/dev/null

# 直接写入 rootfs（适用于已含分区表的镜像）
dd if="$WORK_DIR/rootfs.img" of="$FINAL_IMG" bs=1M conv=notrunc 2>/dev/null

# 压缩
gzip -f "$FINAL_IMG"

log "固件镜像已生成: ${FINAL_IMG}.gz"
ls -lh "${FINAL_IMG}.gz"

# =========================================================
step "6: 生成刷机说明"
# =========================================================
cat > "$WORK_DIR/output/刷机说明.txt" << 'EOF'
============================================
  电犀牛 R68S OpenWrt 固件 刷机指南
============================================

【准备工作】
1. 一张 TF 卡（建议 8GB+，Class 10 / A1）
2. balenaEtcher 或 Rufus 刷写工具
3. 一个 TF 卡读卡器

【刷写步骤】
1. 用 balenaEtcher 将 .img.gz 文件刷入 TF 卡
2. 将 TF 卡插入 R68S 的 TF 卡槽
3. 用网线连接电脑和 R68S 的 eth0 或 eth2 口（LAN口）
4. R68S 上电启动
5. 电脑设置静态 IP: 192.168.2.x（例如 192.168.2.100）
6. 浏览器打开 http://192.168.2.1
7. 用户名: root，密码: password
8. 进入系统后建议立即修改密码

【首次启动】
- 启动约需 30-60 秒
- 如果 ping 不通 192.168.2.1，尝试插拔网线或换 LAN 口
- R68S 网口布局（从左到右）：
  eth1(千兆WAN) eth0(千兆LAN) eth3(2.5G) eth2(2.5G LAN)

【科学上网配置】
- 服务 → PassWall
- 添加节点: VLESS+Reality+Vision（需要 Xray 内核）
- 添加节点: Hysteria2（需要 sing-box 内核）
- 首次使用建议更新规则列表

【VPN 配置】
- 服务 → ZeroTier: 加入网络ID即可
- 服务 → Tailscale: 登录绑定
- 网络 → WireGuard: 导入配置

【进系统后的优化】
1. 系统 → 管理 → 修改密码
2. 网络 → 接口 → WAN口设置（PPPoE或DHCP）
3. 服务 → PassWall → 启用主开关
4. 系统 → 软件包 → 更新列表

============================================
编译日期: $(date '+%Y-%m-%d %H:%M:%S')
源码: coolsnowwolf/lede
目标: Rockchip RK3568 / 电犀牛 R68S
============================================
EOF

# =========================================================
step "7: 完成"
# =========================================================
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  打包完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo "产物清单:"
ls -lh "$WORK_DIR/output/"
echo ""
echo "最终固件: $WORK_DIR/output/*.img.gz"
