#!/usr/bin/env bash
#
# 为京东云雅典娜 AX6600（JDCloud RE-CS-02）编一版定制 ImmortalWrt：
#
#   源码  VIKINGYFY/immortalwrt @ owrt   —— 上游 PPE/DSA 新栈
#   改动 1  kmod-nft-queue          （open-box 需要；原固件里是 =n 编不进去）
#   改动 2  argon 主题 + 配置页
#   改动 3  2.5G WAN                （靠源码 DTS 的 2500base-x，不是 config 开关）
#
# 应用包分三档（APPS）：
#   none      只编系统 + 上面三处改动            —— 最快，用来先验证 2.5G
#   official  再加官方 feed 的应用包（约 60 项）  —— 默认，稳定性可控
#   full      再加第三方（OpenClash/PassWall2/partexp/iStore/SSR）
#                                                 —— 最接近原固件，但兼容性未验证
#
# 运行环境：GNU/Linux（GitHub Actions 的 ubuntu runner，或本机 Docker 容器）。
#   macOS 原生不能编 OpenWrt（构建系统要求大小写敏感文件系统）。
#
# 用法：
#   ./build-immortalwrt.sh
#   APPS=full ./build-immortalwrt.sh
#   APPS=none BRANCH=owrt WORK=$HOME/immortalwrt ./build-immortalwrt.sh
#   PROXY=http://host.docker.internal:2080 ./build-immortalwrt.sh
#   V=s ./build-immortalwrt.sh
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HOME/immortalwrt}"
BRANCH="${BRANCH:-owrt}"
APPS="${APPS:-official}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
PROXY="${PROXY:-}"
V="${V:-}"
REPO="${REPO:-https://github.com/VIKINGYFY/immortalwrt.git}"

DEV="jdcloud_re-cs-02"
DTS="target/linux/qualcommax/dts/ipq6010-re-cs-02.dts"
OUTDIR="bin/targets/qualcommax/ipq60xx"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

run_to() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

run_retry() {
  local n="$1" to="$2"; shift 2
  local i=1
  while true; do
    if run_to "$to" "$@"; then return 0; fi
    if [ "$i" -ge "$n" ]; then die "重试 $n 次仍失败: $*"; fi
    echo "  第 $i 次失败，5 秒后重试: $*"
    sleep 5; i=$((i+1))
  done
}

case "$APPS" in
  none|official|full) ;;
  *) die "APPS 只能是 none / official / full，收到：$APPS" ;;
esac

[ -f "$ASSETS/config/seed.config" ] || die "找不到 $ASSETS/config/seed.config"
[ "$APPS" = none ] || [ -f "$ASSETS/config/apps-official.config" ] || die "找不到 apps-official.config"
[ "$APPS" != full ] || [ -f "$ASSETS/config/apps-thirdparty.config" ] || die "找不到 apps-thirdparty.config"

if [ -n "$PROXY" ]; then
  export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
  export no_proxy="${no_proxy:-localhost,127.0.0.1}"
  echo "已为构建过程设置代理: $PROXY"
fi

log "1/8 获取源码 $REPO ($BRANCH) -> $WORK"

# ⚠️ 缓存陷阱：Actions 的 dl/ 缓存恢复时会先把 $WORK 建出来（里面只有 dl/），
#    于是 git clone 直接报 "destination path already exists"。
STASH=""
if [ -d "$WORK" ] && [ ! -d "$WORK/.git" ]; then
  STASH="$(dirname "$WORK")/.stash-$(basename "$WORK").$$"
  mv "$WORK" "$STASH"
  echo "  $WORK 已存在但不是源码树（多半是缓存恢复出来的 dl/），先挪到 $STASH"
fi

if [ -d "$WORK/.git" ]; then
  echo "目录已存在，跳过 clone（如需重来请手动删除 ${WORK}）"
else
  mkdir -p "$(dirname "$WORK")"
  run_retry 3 1800 git \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=120 \
    clone --depth 1 --single-branch -b "$BRANCH" "$REPO" "$WORK"
fi

if [ -n "$STASH" ] && [ -d "$STASH/dl" ]; then
  mkdir -p "$WORK/dl"
  mv "$STASH"/dl/* "$WORK/dl/" 2>/dev/null || true
  mv "$STASH"/dl/.[!.]* "$WORK/dl/" 2>/dev/null || true
  echo "  dl/ 缓存已归位：$(ls "$WORK/dl" | wc -l) 个条目"
fi
if [ -n "$STASH" ]; then
  rmdir "$STASH/dl" 2>/dev/null || true
  rmdir "$STASH" 2>/dev/null || echo "  保留 ${STASH}"
fi
cd "$WORK"

echo "  源码版本：$(git log -1 --oneline 2>/dev/null || echo unknown)"

log "2/8 校验源码：WAN 口是不是真的 2500base-x"

[ -f "$DTS" ] || die "$DTS 不存在 —— 这个分支可能没带 RE-CS-02 支持，先确认分支选对了"
python3 - "$DTS" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()

m = re.search(r'(swport5:\s*port@5\s*\{)', src)
if not m:
    sys.exit("!! DTS 里找不到 swport5/port@5 —— 端口定义被改过，停下")
i = m.end() - 1
depth, j = 0, i
while j < len(src):
    if src[j] == '{':
        depth += 1
    elif src[j] == '}':
        depth -= 1
        if depth == 0:
            break
    j += 1
block = src[i:j + 1]

checks = {
    'label = "wan"': 'WAN 标签',
    'phy-mode = "2500base-x"': '2.5G 速率模式',
    'pcs-handle = <&uniphy1': 'PCS 句柄',
}
bad = [name for key, name in checks.items() if key not in block]
print(block.rstrip())
if bad:
    sys.exit("!! WAN 端口缺少：" + "、".join(bad))
print("  ✓ WAN = 2500base-x + uniphy1 PCS")
PY

log "3/8 拉取第三方包（APPS=$APPS）"

# 从一个仓库里挑出某个子目录，放进 package/
take_pkg() {
  local tmp="$1" name="$2" src
  src=$(find "$tmp" -maxdepth 4 -type d -name "$name" -not -path "*/.git/*" -print -quit 2>/dev/null || true)
  if [ -n "$src" ]; then
    rm -rf "package/$name"
    cp -rf "$src" package/
    echo "  + package/$name"
  else
    echo "  ! 在 $tmp 里没找到 $name，跳过"
  fi
}

fetch_repo() {   # <repo-url> <tmp-dir> [要取的包名...]
  local url="$1" tmp="$2"; shift 2
  rm -rf "$tmp"
  if ! run_retry 2 600 git clone --depth 1 --single-branch "$url" "$tmp"; then
    echo "  ! 拉取失败，跳过整组：$url"
    return 0
  fi
  local n
  for n in "$@"; do take_pkg "$tmp" "$n"; done
}

if [ "$APPS" = full ]; then
  # 一个 feed 都不加，全部 clone 后按包名挑子目录 —— 避免同名包双重定义
  fetch_repo "https://github.com/vernesong/OpenClash.git" /tmp/tp-openclash luci-app-openclash
  fetch_repo "https://github.com/Openwrt-Passwall/openwrt-passwall2.git" /tmp/tp-passwall2 luci-app-passwall2
  fetch_repo "https://github.com/sirpdboy/luci-app-partexp.git" /tmp/tp-partexp luci-app-partexp
  fetch_repo "https://github.com/istoreos/istore.git" /tmp/tp-istore luci-app-store luci-lib-taskd luci-lib-xterm taskd
  fetch_repo "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git" /tmp/tp-pw-pkgs shadowsocksr-libev
else
  echo "  跳过"
fi

log "4/8 更新 feeds"
run_retry 3 1200 ./scripts/feeds update -a
run_retry 3 1200 ./scripts/feeds install -a

log "5/8 生成 .config（seed + APPS=$APPS）"
cp -f "$ASSETS/config/seed.config" .config
if [ "$APPS" != none ]; then
  cat "$ASSETS/config/apps-official.config" >> .config
fi
if [ "$APPS" = full ]; then
  cat "$ASSETS/config/apps-thirdparty.config" >> .config
fi
make defconfig

log "6/8 校验 .config"
sel() { grep -q "^$1=y$" .config && echo y || echo n; }

DEV_A=$(sel "CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_${DEV}")
DEV_B=$(sel "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_${DEV}")
echo "  设备选中：$DEV_A / $DEV_B"
[ "$DEV_A" = y ] || [ "$DEV_B" = y ] || die "设备没被选上：jdcloud_re-cs-02"

# 基础三件：硬校验（缺了这次就白编了）
for pkg in kmod-nft-queue luci-theme-argon luci-app-argon-config kmod-tun kmod-nft-tproxy; do
  s=$(sel "CONFIG_PACKAGE_${pkg}")
  echo "  必需 ${pkg}: ${s}"
  [ "$s" = y ] || die "必需包没被选上：${pkg}"
done

# 应用包：软校验，只报告不中断（包名在分支间偶有差异）
missing_report() {
  local f="$1" pkg miss=0 total=0
  while IFS= read -r line; do
    pkg=$(printf '%s' "$line" | sed -n 's/^CONFIG_PACKAGE_\(.*\)=y$/\1/p')
    [ -n "$pkg" ] || continue
    total=$((total+1))
    if ! grep -qF "CONFIG_PACKAGE_${pkg}=y" .config; then
      echo "    ✗ $pkg"
      miss=$((miss+1))
    fi
  done < "$f"
  echo "  点了 $total 个，没进 .config 的 $miss 个"
}

if [ "$APPS" != none ]; then
  echo "  官方应用包："
  missing_report "$ASSETS/config/apps-official.config"
fi
if [ "$APPS" = full ]; then
  echo "  第三方包："
  missing_report "$ASSETS/config/apps-thirdparty.config"
fi

log "7/8 下载源码包（国内网络容易卡，失败重试）"
run_retry 3 3600 make -j"$JOBS" download

log "8/8 编译（首次 2~4 小时，取决于 APPS 档位）"
run_to 12600 make -j"$JOBS" ${V:+"V=$V"}

log "收集并校验产物"
mkdir -p "$ASSETS/out"
find "$OUTDIR" -maxdepth 1 -type f \
  \( -name "*${DEV}*" -o -name "profiles.json" -o -name "sha256sums" -o -name "*.manifest" \) \
  -exec cp -f {} "$ASSETS/out/" \; 2>/dev/null || true

[ "$(ls -1 "$ASSETS/out" | wc -l)" -gt 0 ] || die "out/ 是空的 —— 编译可能没跑到产生产物这一步，检查 $OUTDIR"

SU=$(ls "$ASSETS/out/"*"${DEV}"*sysupgrade.bin 2>/dev/null | head -1)
[ -n "$SU" ] || die "没找到 sysupgrade 镜像（检查 $OUTDIR 里的实际文件名）"

# 关键校验：sysupgrade 包里必须同时有 kernel 和 rootfs。
# 跨栈升级（NSS→PPE）如果只换 rootfs 不换内核，刷完直接起不来。
echo "  sysupgrade 包内容："
if tar tf "$SU" >/tmp/su.list 2>/dev/null || tar tzf "$SU" >/tmp/su.list 2>/dev/null; then
  sed 's/^/    /' /tmp/su.list | head -10
  grep -qE '(^|/)kernel$' /tmp/su.list || die "sysupgrade 包里没有 kernel —— 别刷，只换 rootfs 会变砖"
  grep -qE '(^|/)(root|rootfs)$' /tmp/su.list || die "sysupgrade 包里没有 rootfs"
  echo "  ✓ 同时含 kernel + rootfs"
else
  echo "  ! 无法读取包内容（tar 列不出），请人工确认"
fi

ls -lh "$SU"

(cd "$ASSETS/out" && [ -f sha256sums ] && sha256sum -c sha256sums 2>/dev/null | tail -3) || true
ls -lh "$ASSETS/out"

cat <<'EOF'

完成。产物在 out/：
  *-squashfs-sysupgrade.bin   ← 在 OpenWrt 里 sysupgrade（保留配置）
  *-factory.bin               ← 只在救砖/U-Boot 恢复时用

刷机前必做（见 README「刷机前 10 分钟」）：
  1. 设备上备份配置：  sysupgrade -b /opt/config-before-owrt.tar.gz
  2. 备份 U-Boot 环境：fw_printenv > /opt/uboot-env.txt
  3. 确认 /opt/openbox-rootfs-parts.tar.gz 在（open-box 的根 fs 部分）
EOF
