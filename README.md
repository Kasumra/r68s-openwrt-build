# R68S OpenWrt 固件定制编译
# 基于 coolsnowwolf/lede 源码 + Flippy 打包

# ============================================
# 项目概况
# ============================================
# 设备:      电犀牛 FastRhino R68S
# SoC:       Rockchip RK3568 (4核 Cortex-A55)
# RAM:       4GB LPDDR4X
# 存储:      32GB eMMC（固件烧录到 TF 卡启动）
# 网口:      eth0(千兆), eth1(千兆), eth2(2.5G), eth3(2.5G)
# 源码:      coolsnowwolf/lede (Lean's LEDE)
# 打包:      unifreq/openwrt_packit (Flippy)
# 编译环境:  Docker (Ubuntu 22.04)

# ============================================
# 目录结构
# ============================================
# r68s/
# ├── README.md          ← 本文件
# ├── config/
# │   └── .config        ← OpenWrt 编译配置
# ├── scripts/
# │   ├── docker-build.sh ← Docker 编译入口
# │   └── package.sh      ← Flippy 打包脚本
# ├── src/               ← LEDE 源码 (clone 后生成)
# └── output/            ← 编译产物/最终固件

# ============================================
# 快速开始
# ============================================
#
# 1. Clone 源码:
#    git clone https://github.com/coolsnowwolf/lede.git src/
#
# 2. 首次编译:
#    cd scripts && bash docker-build.sh
#
# 3. 后续编译:
#    cd scripts && bash docker-build.sh
#
# 4. 固件输出位置:
#    output/ 目录

# ============================================
# 集成功能清单
# ============================================
#
# 科学上网:
#   ✅ PassWall2 (双内核: Xray + sing-box)
#   ✅ Hysteria2 (sing-box)
#   ✅ VLESS + Reality + Vision (xray-core)
#   ✅ 自动更新规则
#
# 异地组网 VPN:
#   ✅ ZeroTier
#   ✅ Tailscale
#   ✅ WireGuard
#
# 网络/稳定性:
#   ✅ FullCone NAT
#   ✅ SQM QoS 流量整形
#   ✅ 流量监控/统计
#   ✅ DNS 加速 (SmartDNS / MosDNS)
#   ✅ IPv6 支持
#
# 系统/管理:
#   ✅ LuCI Web 界面 (Argon 主题)
#   ✅ Web 终端 (ttyd)
#   ✅ 文件管理 (luci-app-filebrowser)
#   ✅ 定时任务
#   ✅ DDNS 动态域名
#   ✅ UPnP
#   ✅ KMS 激活服务器
#
# 硬件加速:
#   ✅ RK3568 硬件 NAT 加速
#   ✅ CPU 性能调度优化

# ============================================
# 默认参数
# ============================================
# 管理 IP:   192.168.2.1
# 用户名:    root
# 密码:      password
# WiFi:      无（有线路由器）
