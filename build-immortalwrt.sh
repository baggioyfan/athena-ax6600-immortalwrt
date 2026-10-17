#!/usr/bin/env bash
#
# 为京东云雅典娜 AX6600（JDCloud RE-CS-02）编一版定制 ImmortalWrt：
#
#   源码  VIKINGYFY/immortalwrt @ owrt   —— 上游 PPE/DSA 新栈
#   改动 1  kmod-nft-queue          （open-box 需要；旧固件里是 =n 编不进去）
#   改动 2  argon 主题 + 配置页
#   改动 3  2.5G WAN                （靠源码 DTS 的 2500base-x，不是 config 开关）
#
# 运行环境：GNU/Linux（GitHub Actions 的 ubuntu runner，或本机 Docker 容器）。
#   macOS 原生不能编 OpenWrt（构建系统要求大小写敏感文件系统）。
#
# 用法：
#   ./build-immortalwrt.sh
#   BRANCH=owrt WORK=$HOME/immortalwrt ./build-immortalwrt.sh
#   PROXY=http://host.docker.internal:2080 ./build-immortalwrt.sh   # 容器里借宿主机代理
#   V=s ./build-immortalwrt.sh                                      # 排错时看详细日志
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HOME/immortalwrt}"
BRANCH="${BRANCH:-owrt}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
PROXY="${PROXY:-}"
V="${V:-}"
REPO="${REPO:-https://github.com/VIKINGYFY/immortalwrt.git}"

DEV="jdcloud_re-cs-02"
DTS="target/linux/qualcommax/dts/ipq6010-re-cs-02.dts"
OUTDIR="bin/targets/qualcommax/ipq60xx"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# 联网/编译类命令统一带超时（Linux 上有 timeout；没有就退化为直接跑）
run_to() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# 带重试：run_retry <次数> <单次超时秒> <命令...>
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

[ -f "$ASSETS/config/seed.config" ] || die "找不到 $ASSETS/config/seed.config"

if [ -n "$PROXY" ]; then
  export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
  export no_proxy="${no_proxy:-localhost,127.0.0.1}"
  echo "已为构建过程设置代理: $PROXY"
fi

log "1/7 获取源码 $REPO ($BRANCH) -> $WORK"

# ⚠️ 缓存陷阱：Actions 的 dl/ 缓存恢复时会先把 $WORK 建出来（里面只有 dl/），
#    于是 git clone 直接报 "destination path already exists"。
#    处理：先把整个目录挪走，clone 完再把 dl/ 归位。
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
  rmdir "$STASH" 2>/dev/null || echo "  保留 ${STASH}（里面还有别的东西，没动它）"
fi
cd "$WORK"

echo "  源码版本：$(git log -1 --oneline 2>/dev/null || echo unknown)"

log "2/7 校验源码：WAN 口是不是真的 2500base-x"

[ -f "$DTS" ] || die "$DTS 不存在 —— 这个分支可能没带 RE-CS-02 支持，先确认分支选对了"
python3 - "$DTS" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()

# 提取 swport5 / port@5 的块（花括号配平），只看 WAN 这一段
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

log "3/7 更新 feeds"
run_retry 3 1200 ./scripts/feeds update -a
run_retry 3 1200 ./scripts/feeds install -a

log "4/7 生成 .config（seed → defconfig）"
cp -f "$ASSETS/config/seed.config" .config
make defconfig

sel() { grep -q "^$1=y$" .config && echo y || echo n; }

DEV_A=$(sel "CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_${DEV}")
DEV_B=$(sel "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_${DEV}")
echo "  设备选中：$DEV_A / $DEV_B"
[ "$DEV_A" = y ] || [ "$DEV_B" = y ] || die "设备没被选上：jdcloud_re-cs-02"

# 包校验（自证前进）：Kconfig 遇到不存在的包名会静默丢掉这行，
# 不校验就得等编完刷进机器才发现"主题/队列没进去"。
for pkg in kmod-nft-queue luci-theme-argon luci-app-argon-config kmod-tun kmod-nft-tproxy; do
  s=$(sel "CONFIG_PACKAGE_${pkg}")
  echo "  包 ${pkg}: ${s}"
  [ "$s" = y ] || die "包没被选上：${pkg} —— 检查 seed.config 的包名与当前分支的 feeds"
done

# 语言包只做提醒（不同分支的 i18n 包名后缀可能变）
for pkg in luci-i18n-argon-config-zh-cn luci-i18n-base-zh-cn; do
  s=$(sel "CONFIG_PACKAGE_${pkg}")
  echo "  包 ${pkg}: ${s}（不致命）"
done

log "5/7 下载源码包（国内网络容易卡，失败重试）"
run_retry 3 3600 make -j"$JOBS" download

log "6/7 编译（首次 1.5~3 小时）"
run_to 10800 make -j"$JOBS" ${V:+"V=$V"}

log "7/7 收集并校验产物"
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
