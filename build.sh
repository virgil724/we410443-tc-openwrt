#!/usr/bin/env bash
# Build OpenWrt for Arcadyan WE410443-TC (Chunghwa Telecom variant).
# Usage: ./build.sh [openwrt-tag]   (default: v25.12.6)
set -euo pipefail

TAG="${1:-v25.12.6}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/openwrt-we410443}"

# WSL: Windows PATH entries with spaces break OpenWrt's `find -execdir`
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/openwrt/openwrt.git "$SRC"
fi
cd "$SRC"
git am "$HERE"/patches/*.patch

./scripts/feeds update -a
./scripts/feeds install -a

cat > .config <<'EOF'
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7621=y
CONFIG_TARGET_ramips_mt7621_DEVICE_arcadyan_we410443-tc=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-mod-admin-full=y
CONFIG_PACKAGE_luci-mod-network=y
CONFIG_PACKAGE_luci-mod-status=y
CONFIG_PACKAGE_luci-mod-system=y
CONFIG_PACKAGE_luci-theme-bootstrap=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_uhttpd-mod-ubus=y
EOF
make defconfig
make download -j"$(nproc)"
make -j"$(($(nproc) + 1))"

ls -l bin/targets/ramips/mt7621/*we410443-tc*
