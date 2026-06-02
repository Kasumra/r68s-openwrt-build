#!/bin/bash
# =========================================================
# R68S OpenWrt 固件 — Docker 编译入口
# =========================================================
# 用法:
#   bash scripts/docker-build.sh            # 首次: 完整编译
#   bash scripts/docker-build.sh --quick    # 增量编译(仅打包)
#   bash scripts/docker-build.sh --clean    # 清理重编
#
# 环境: macOS Apple Silicon (ARM64) → 编译 ARM64 固件
#       本机 ARM64 交叉编译 ARM64，无需 QEMU 模拟，效率最高
# =========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$PROJECT_DIR/src"
CONFIG_DIR="$PROJECT_DIR/config"
OUTPUT_DIR="$PROJECT_DIR/output"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

# LEDE 源码仓库
LEDE_REPO="https://github.com/coolsnowwolf/lede.git"
LEDE_BRANCH="master"

# Docker 配置
DOCKER_IMAGE="ubuntu:24.04"
CONTAINER_NAME="r68s-builder"

# 颜色
GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# =========================================================
# Step 0: 校验环境
# =========================================================
check_env() {
    step "第0步: 环境检查"

    if ! command -v docker &>/dev/null; then
        err "Docker 未安装，请先安装 Docker Desktop"
        exit 1
    fi

    local arch=$(uname -m)
    log "本机架构: $arch (编译目标: aarch64)"

    # 创建必要目录
    mkdir -p "$SRC_DIR" "$OUTPUT_DIR"

    log "Docker 可用 ✓"
}

# =========================================================
# Step 1: Clone / 更新源码
# =========================================================
clone_source() {
    step "第1步: 准备 LEDE 源码"

    if [ ! -d "$SRC_DIR/.git" ]; then
        log "首次运行，克隆 LEDE 源码..."
        log "仓库: $LEDE_REPO"
        log "目标: $SRC_DIR"
        echo ""
        git clone --depth=1 "$LEDE_REPO" "$SRC_DIR"
        log "源码克隆完成 ✓"
    else
        log "源码已存在，跳过 clone"
        log "如需更新: cd src && git pull"
    fi
}

# =========================================================
# Step 2: 复制配置文件
# =========================================================
copy_config() {
    step "第2步: 应用定制配置"

    local config_file="$SRC_DIR/.config"
    local seed_config="$CONFIG_DIR/r68s.config"

    if [ ! -f "$seed_config" ]; then
        err "种子配置文件不存在: $seed_config"
        exit 1
    fi

    cp "$seed_config" "$config_file"
    log "配置已复制: r68s.config → src/.config"

    # 同时复制 Flippy 打包脚本到 src
    cp "$SCRIPTS_DIR/package-r68s.sh" "$SRC_DIR/"
    chmod +x "$SRC_DIR/package-r68s.sh"
    log "打包脚本已复制: package-r68s.sh → src/"
}

# =========================================================
# Step 3: Docker 编译
# =========================================================
docker_build() {
    step "第3步: Docker 容器编译"

    local mode="${1:-full}"

    # 清理旧容器
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    log "启动编译容器: $DOCKER_IMAGE"
    log "模式: $mode"
    echo ""

    # 编译脚本（在容器内执行）
    local build_script='
set -e

echo "=== 安装编译依赖 ==="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential gcc-multilib g++-multilib \
    file wget curl git unzip bzip2 xz-utils zstd \
    python3 python3-distutils python3-setuptools \
    libncurses5-dev libncursesw5-dev \
    zlib1g-dev gawk gettext \
    libssl-dev xsltproc rsync \
    libelf-dev dwarves \
    flex bison bc time \
    perl-base perl-modules \
    libc6-dev-i386 || true

echo ""
echo "=== 应用种子配置 ==="
cp /home/build/r68s.config /home/build/lede/.config
cd /home/build/lede

# 展开完整配置
make defconfig

echo ""
echo "=== 下载所有源码包（预缓存） ==="
make download -j$(nproc) V=s || true

echo ""
echo "=== 开始编译 ==="
make -j$(nproc) V=s || {
    echo ""
    echo "!!! 编译出错，尝试单线程编译以排查问题..."
    make -j1 V=s
}

echo ""
echo "=== 编译完成 ==="
find bin/targets -type f \( -name "*.img.gz" -o -name "*.img" -o -name "squashfs*" -o -name "ext4*" \) | sort
'

    docker run \
        --name "$CONTAINER_NAME" \
        --platform linux/arm64 \
        -v "$SRC_DIR:/home/build/lede" \
        -v "$CONFIG_DIR/r68s.config:/home/build/r68s.config:ro" \
        -v "$OUTPUT_DIR:/home/build/output" \
        -w /home/build/lede \
        "$DOCKER_IMAGE" \
        bash -c "$build_script" 2>&1 | tee "$PROJECT_DIR/build.log"

    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        log "编译成功 ✓"
    else
        err "编译失败 (exit code: $exit_code)，查看 build.log"
        exit $exit_code
    fi
}

# =========================================================
# Step 4: Flippy 打包
# =========================================================
package_firmware() {
    step "第4步: Flippy 格式打包 (R68S)"

    docker run \
        --name "${CONTAINER_NAME}-pkg" \
        --platform linux/arm64 \
        -v "$SRC_DIR:/home/build/lede" \
        -v "$OUTPUT_DIR:/home/build/output" \
        -w /home/build/lede \
        "$DOCKER_IMAGE" \
        bash -c '
set -e

cd /home/build/lede

# 查找编译产物
BUILD_DIR=$(find bin/targets/rockchip/armv8 -maxdepth 1 -type d -name "*-*-*" | head -1)
if [ -z "$BUILD_DIR" ]; then
    echo "错误: 找不到编译产物目录"
    find bin/targets -type f 2>/dev/null | sort
    exit 1
fi

echo "编译产物目录: $BUILD_DIR"
ls -lh "$BUILD_DIR"/

# 运行 Flippy 打包
bash package-r68s.sh "$BUILD_DIR"
'

    # 收集最终产物
    log "收集编译产物..."
    find "$SRC_DIR/bin" -name "*-r68s*" -o -name "*R68S*" | while read f; do
        cp -v "$f" "$OUTPUT_DIR/"
    done

    # 如果没有 R68S 特定的，复制所有产物
    if [ -z "$(ls "$OUTPUT_DIR"/*r68s* 2>/dev/null)" ]; then
        find "$SRC_DIR/bin/targets/rockchip/armv8" -type f \( -name "*.img.gz" -o -name "*.img" \) | while read f; do
            cp -v "$f" "$OUTPUT_DIR/"
        done
    fi

    echo ""
    log "最终固件在: $OUTPUT_DIR/"
    ls -lh "$OUTPUT_DIR/"
}

# =========================================================
# Main
# =========================================================
echo -e "${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║    R68S OpenWrt 固件编译工具              ║"
echo "║    电犀牛 FastRhino R68S                 ║"
echo "║    RK3568 + LEDE + PassWall2             ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

MODE="${1:-full}"

case "$MODE" in
    --quick|--package)
        check_env
        package_firmware
        ;;
    --clean)
        check_env
        rm -rf "$SRC_DIR/.config" "$SRC_DIR/bin" "$SRC_DIR/build_dir" "$SRC_DIR/tmp" "$SRC_DIR/staging_dir"
        log "清理完成，重新编译"
        clone_source
        copy_config
        docker_build "clean"
        package_firmware
        ;;
    *)
        check_env
        clone_source
        copy_config
        docker_build "full"
        package_firmware
        ;;
esac

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  全部完成!         ${NC}"
echo -e "${GREEN}  固件目录: $OUTPUT_DIR/${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
