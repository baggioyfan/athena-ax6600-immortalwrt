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
#   official  再加官方 feed 的应用包（约 60 项）
#   full      再加第三方（OpenClash / PassWall2 / SSR / partexp）—— 复刻 PLUS
#             （iStore、gowebdav 不编；NSS 栈 kmod 新栈不存在，也不需要替代）
#
# 运行环境：GNU/Linux（GitHub Actions 的 ubuntu runner，或本机 Docker 容器）。
#   macOS 原生不能编 OpenWrt（构建系统要求大小写敏感文件系统）。
#
# 用法：
#   ./build-immortalwrt.sh
#   APPS=full ./build-immortalwrt.sh
#   APPS=full NODOWNLOAD=1 ./build-immortalwrt.sh
#   V=s ./build-immortalwrt.sh
#
set -euo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HOME/immortalwrt}"
BRANCH="${BRANCH:-owrt}"
APPS="${APPS:-full}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
PROXY="${PROXY:-}"
V="${V:-}"
REPO="${REPO:-https://github.com/VIKINGYFY/immortalwrt.git}"
BUILD_LOG="${BUILD_LOG:-$(dirname "${WORK:-$HOME/immortalwrt}")/build.log}"
RETRY_ON_FAIL="${RETRY_ON_FAIL:-1}"

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

# 同上，但失败只返回非 0，不中止脚本（第三方仓库拉不到不该拖垮整轮）
run_retry_soft() {
  local n="$1" to="$2"; shift 2
  local i=1
  while true; do
    if run_to "$to" "$@"; then return 0; fi
    if [ "$i" -ge "$n" ]; then return 1; fi
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
  if ! run_retry_soft 2 600 git clone --depth 1 --single-branch "$url" "$tmp"; then
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
  fetch_repo "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git" /tmp/tp-pw-pkgs shadowsocksr-libev

  for d in luci-app-openclash luci-app-passwall2 luci-app-partexp shadowsocksr-libev; do
    [ -d "package/$d" ] || echo "  !! package/$d 不存在（后面 defconfig 会把对应 CONFIG 丢掉）"
  done
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

# 设备默认包（WiFi 固件 / LED 屏）不能被 seed 覆盖掉，否则刷完没 WiFi
for pkg in ipq-wifi-jdcloud_re-cs-02 ath11k-firmware-qcn9074-ddwrt luci-app-athena-led; do
  s=$(sel "CONFIG_PACKAGE_${pkg}")
  echo "  设备默认 ${pkg}: ${s}"
  [ "$s" = y ] || die "设备默认包被覆盖掉了：${pkg} —— 检查 seed.config 里 CONFIG_TARGET_DEVICE_PACKAGES 那行"
done

# 基础三件：硬校验（缺了这次就白编了）
for pkg in kmod-nft-queue luci-theme-argon luci-app-argon-config kmod-tun kmod-nft-tproxy; do
  s=$(sel "CONFIG_PACKAGE_${pkg}")
  echo "  必需 ${pkg}: ${s}"
  [ "$s" = y ] || die "必需包没被选上：${pkg}"
done

# 互斥变体：两个都 y 会导致镜像里两个包抢同一个虚拟名，安装期就崩。
# 这类错误在编译到 90% 才暴露，所以在动手编之前就拦。
if [ "$APPS" = full ]; then
  echo "  --- 互斥变体 ---"
  for pair in "dnsmasq-full:dnsmasq" "ip-full:ip-tiny"; do
    want="${pair%%:*}"; avoid="${pair##*:}"
    a=$(sel "CONFIG_PACKAGE_${want}"); b=$(sel "CONFIG_PACKAGE_${avoid}")
    echo "  ${want}=${a}  ${avoid}=${b}"
    [ "$a" = y ] || die "${want} 没被选上 —— full 档必须要它"
    [ "$b" = n ] || die "${avoid} 仍是 y，会和 ${want} 冲突（两个都 PROVIDES 同一虚拟包）"
  done

  echo "  --- full 档核心包（硬校验）---"
  for pkg in luci-app-openclash luci-app-passwall2 luci-app-partexp \
             dnsmasq_full_nftset kmod-nft-socket kmod-nft-nat ruby ruby-yaml \
             shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir; do
    s=$(sel "CONFIG_PACKAGE_${pkg}")
    echo "  ${pkg}: ${s}"
    [ "$s" = y ] || die "full 档核心包没被选上：${pkg}（编译前拦下，不用白等 3 小时）"
  done
fi

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

log "7/8 下载源码包（国内网络容易卡；这一阶段失败不致命）"
if [ "${NODOWNLOAD:-0}" = 1 ]; then
  echo "  NODOWNLOAD=1，跳过"
else
  run_to 5400 make -j"$JOBS" download || echo "  ! 有包没下全，交给编译阶段自己重试"
fi

log "8/8 编译（首次 2~5 小时，取决于 APPS 档位）"

# 编译失败时 OpenWrt 会打印形如
#   make[3]: *** [Makefile:88: /…/build_dir/target-…/luci-app-xxx-1.2.3/.built] Error 1
# 从日志里把这几个目录名抠出来，按"去掉版本号"映射回包名。
# 只对**非核心包**做一次自动剔除重编：核心包挂了就正常失败，不掩盖问题。
# SSR 故意不算核心：它是原固件遗留的老包，编不过时关掉 passwall2 的 SSR 选项即可，
# 不影响 PassWall2 的其余功能（xray / sing-box / ss-rust 都还在）。
CORE_PKGS="luci-app-openclash luci-app-passwall2 luci-app-partexp kmod-nft-queue"

extract_failed() {
  [ -f "$BUILD_LOG" ] || return 0
  grep -oE '/build_dir/[^ /]+/[A-Za-z0-9._+-]+/\.built' "$BUILD_LOG" 2>/dev/null \
    | sed -E 's#^.*/build_dir/[^/]+/##; s#/\.built$##; s#-[0-9].*$##' \
    | sort -u
}

drop_pkg() {   # 把某个包的 CONFIG 及其子包/变体（-xxx、_xxx）一起关掉
  local p="$1"
  sed -i -E "s#^CONFIG_PACKAGE_${p}=y#\# CONFIG_PACKAGE_${p} is not set#" .config
  sed -i -E "s#^CONFIG_PACKAGE_(${p}[-_][A-Za-z0-9_.+-]+)=y#\# CONFIG_PACKAGE_\1 is not set#" .config
  # SSR 是 passwall2 用 select 拉进来的：光删包没意义，defconfig 会再拉回来，
  # 必须同时关掉 passwall2 的那个编译开关。
  if [ "$p" = shadowsocksr-libev ]; then
    sed -i -E \
      "s#^CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_ShadowsocksR_Libev_Client=y#\# CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_ShadowsocksR_Libev_Client is not set#" \
      .config
  fi
  ! grep -q "^CONFIG_PACKAGE_${p}=y$" .config
}

build_once() {
  local rc=0
  set +e
  if [ -n "$V" ]; then
    make -j"$JOBS" V="$V" 2>&1 | tee "$BUILD_LOG"
  else
    make -j"$JOBS" 2>&1 | tee "$BUILD_LOG"
  fi
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

attempt=1
while true; do
  if build_once; then
    echo "  ✓ 编译完成"
    break
  fi

  if [ "$RETRY_ON_FAIL" != 1 ] || [ "$attempt" -ge 2 ]; then
    echo
    echo "!! 编译失败（第 $attempt 次）。构建日志：$BUILD_LOG"
    echo "   可疑包："
    extract_failed | sed 's/^/     /' || true
    echo "   最后 40 行："
    tail -40 "$BUILD_LOG" 2>/dev/null | sed 's/^/     /' || true
    exit 1
  fi

  failed=$(extract_failed | tr '\n' ' ')
  echo
  echo "!! 第 $attempt 次编译失败，日志里的包：${failed:-<识别不出>}"
  if [ -z "$failed" ]; then
    echo "   识别不出失败包，不做自动剔除，直接报错"
    tail -40 "$BUILD_LOG" | sed 's/^/     /'
    exit 1
  fi

  dropped=0
  for p in $failed; do
    if printf '%s ' $CORE_PKGS | grep -qF "$p "; then
      echo "   $p 是核心包，不自动剔除（要它就得改代码，不能靠删）"
      continue
    fi
    if drop_pkg "$p"; then
      echo "   已剔除：$p（保留已编译产物，重编只补缺失部分）"
      dropped=$((dropped+1))
    fi
  done

  if [ "$dropped" -eq 0 ]; then
    echo "   没有可剔除的包，直接报错"
    tail -40 "$BUILD_LOG" | sed 's/^/     /'
    exit 1
  fi

  echo "   重新 make defconfig 后续编（已编译的包不会重编）"
  make defconfig >/dev/null 2>&1 || true
  attempt=$((attempt+1))
done

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

# 关键包是否真的进了镜像（manifest 是最终真相，不是 .config）
MAN=$(ls "$ASSETS/out/"*.manifest 2>/dev/null | head -1)
if [ -n "$MAN" ]; then
  echo "  镜像内关键包抽查："
  for pkg in kmod-nft-queue luci-theme-argon luci-app-athena-led; do
    if grep -qiE "^${pkg} " "$MAN"; then echo "    ✓ $pkg"; else echo "    ✗ $pkg 不在 manifest 里"; fi
  done
  if [ "$APPS" = full ]; then
    for pkg in luci-app-openclash luci-app-passwall2 dnsmasq-full ip-full; do
      if grep -qiE "^${pkg} " "$MAN"; then echo "    ✓ $pkg"; else echo "    ✗ $pkg 不在 manifest 里"; fi
    done
  fi
fi

ls -lh "$SU"

(cd "$ASSETS/out" && [ -f sha256sums ] && sha256sum -c sha256sums 2>/dev/null | tail -3) || true
ls -lh "$ASSETS/out"

cat <<'EOF'

完成。产物在 out/：
  *-squashfs-sysupgrade.bin   ← 在 OpenWrt 里 sysupgrade（保留配置）
  *-factory.bin               ← 只在救砖/U-Boot 恢复时用

刷机前必做：
  1. 设备上备份配置：  sysupgrade -b /opt/config-before-owrt.tar.gz
  2. 备份 U-Boot 环境：fw_printenv > /opt/uboot-env.txt
  3. 确认 /opt/openbox-rootfs-parts.tar.gz 在（open-box 的根 fs 部分）
EOF
