# 雅典娜 AX6600（JDCloud RE-CS-02）定制 ImmortalWrt

给**京东云无线宝雅典娜 AX6600** 编的定制固件。三处硬改动是固定的，应用包按 `APPS` 分档；
`seed.config` 里另有一组可关闭的优化项（2026-11-19 从 `ones20250/Openwrt-AX6600` 吸收）。

| # | 改动 | 落地位置 | 为什么 |
|---|------|---------|--------|
| 1 | `kmod-nft-queue` | `config/seed.config` | 原固件 `GENERAL_AX6600.txt` 里写的是 `=n`，open-box 起不来/接管不了 nft 队列 |
| 2 | argon 主题 | `config/seed.config` | 原固件本来就带（`luci-theme-argon 2.4.7` + 配置页 + 中文包），这里是保证换栈后仍在 |
| 3 | 2.5G WAN | 源码 DTS（无需 config） | 旧 NSS 栈的 DTS 是 `phy-mode = "sgmii"`（1.25Gbps 线速，物理载不动 2.5G）；`owrt` 分支改成 `2500base-x` + `pcs-handle = <&uniphy1 0>` |

> ⚠️ 这不是「在原固件上改三处」。换栈 = 换整棵源码树，原固件的包集必须在新源码里重建，
> 所以有了下面的 `APPS` 三档。

## 源码

- 仓库：`VIKINGYFY/immortalwrt`，分支 **`owrt`**（上游 PPE/DSA 新栈，不是 QSDK NSS）
- 设备定义：`target/linux/qualcommax/image/ipq60xx.mk` → `Device/jdcloud_re-cs-02`
- 设备树：`target/linux/qualcommax/dts/ipq6010-re-cs-02.dts`

构建脚本用 `git clone --depth 1 --single-branch -b owrt` 取**分支 HEAD，不锁 SHA**，
所以每次重跑都会带进上游最新代码（含 11-14～11-16 那批 `qca_ppe` / `EDMA` / `UNIPHY` 修复）。

WAN 那一段（编译脚本第 2 步会逐字校验，被上游改回去就直接停）：

```dts
swport5: port@5 {
    reg = <5>;
    label = "wan";
    phy-handle = <&qca8081>;
    phy-mode = "2500base-x";
    pcs-handle = <&uniphy1 0>;
};
```

## 构建

**只有手动触发（`workflow_dispatch`），push 不会自动编，也没有定时任务。**

入口：Actions → `Build Athena AX6600 (RE-CS-02)` → Run workflow。

### 点之前先分清两个「分支」

| 位置 | 该选什么 | 说明 |
|------|---------|------|
| 页面右上 **Use workflow from** | **`main`** | 本仓库只有 `main` 这一个分支，workflow 和 config 都在这上面；下拉里没有别的可选 |
| workflow 输入 **branch** | **`owrt`**（默认值） | 这是**上游源码分支**（`VIKINGYFY/immortalwrt`）。选 `main` 会退回旧 NSS 栈，没有 2500base-x DTS，第 2 步校验会直接停 |

另外两个输入：`apps` 保持 **`full`**；`jobs` 保持 **`4`**（4 核 runner，填大了反而慢）。

| `apps` | 内容 | 大概耗时 | 什么时候用 |
|--------|------|---------|-----------|
| `full`（默认） | 官方应用包约 60 项 **+** OpenClash、PassWall2、SSR、partexp | 3.5~5h | 贴近原固件 PLUS，一次到位 |
| `official` | 只加官方 feed 应用包约 60 项：adguardhome、docker 全家、samba4、ttyd、upnp、ddns、p910nd、sing-box、xray、iperf3、wol… | 3~4h | 出问题时的退路 |
| `none` | 系统 + 三处改动 + `seed.config` 里的优化项 | 2~3h | 只想先确认 2.5G 通不通 |

`full` 那一层的外部仓库当初是针对旧栈 + 旧版 luci 编的，在 `owrt` 上**没有官方保证**。
脚本为此加了两道保险：
- 编译前校验 10 个核心包是否真的进了 `.config`；
- 编译中若某个**非核心包**挂掉，把它从 `.config` 剔除后**原地续编一次**（已编译产物保留）。

**只重试一次**（`RETRY_ON_FAIL=1`，第 2 次仍失败就直接退出，不掩盖问题）。
这四个包不会被自动剔除，挂了就正常失败：`luci-app-openclash`、`luci-app-passwall2`、
`luci-app-partexp`、`kmod-nft-queue`。

`full` **不含**：iStore 全家、gowebdav 全家（都明确不要）；NSS 栈的 24 个 kmod（新栈物理上不存在，
也不需要替代品——PPE + mainline DSA + 内核 flowtable 就是加速路径）。

### 产物与有效期

跑完在 run 页面**最底部**的 Artifacts 下载，名字形如
`immortalwrt-owrt-full-jdcloud_re-cs-02-r<运行号>`，里面有：

- `*-squashfs-sysupgrade.bin` ← 日常升级用这个
- `*-factory.bin` ← 只在救砖 / U-Boot 恢复时用
- `sha256sums` / `*.manifest` / `profiles.json`
- 失败时另有一个 `build-logs-r<运行号>`（含 `build.log`，只留 7 天）

⚠️ **artifact 只保留 30 天**（`retention-days: 30`），过期后连自己也下不到，只能重跑。
上一版（10-17 那次 `run #2`）的产物已经过期，所以现在没有可下固件。

### 本地 / 自己的 Linux 机器也能跑

脚本要求 GNU/Linux（macOS 原生不行，构建系统要大小写敏感文件系统）。

```sh
./build-immortalwrt.sh                  # 默认 owrt + full
APPS=official ./build-immortalwrt.sh    # 退路：只官方应用包
APPS=none   ./build-immortalwrt.sh      # 只验 2.5G
BRANCH=owrt WORK=$HOME/immortalwrt ./build-immortalwrt.sh
NODOWNLOAD=1 ./build-immortalwrt.sh     # 跳过 7/8 的 make download
PROXY=http://127.0.0.1:7890 ./build-immortalwrt.sh   # 给 clone 和编译过程挂代理
V=s ./build-immortalwrt.sh              # 出问题看详细日志
RETRY_ON_FAIL=0 ./build-immortalwrt.sh  # 编挂了直接停，不做自动剔除
```

产物在 `out/`。

### 脚本实际会做的校验（8 步，逐条都是代码里真有的）

编译前（任何一条不过立刻退出，不浪费几小时）：

1. **第 2 步 / DTS**：`swport5: port@5` 必须存在，块内必须有
   `label = "wan"`、`phy-mode = "2500base-x"`、`pcs-handle = <&uniphy1`
2. **第 6 步 / 设备**：`CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02` 或
   `CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02` 至少一个 `=y`
3. **第 6 步 / 设备自带包没被覆盖**（缺了刷完没 WiFi / LED 屏黑）：
   `ipq-wifi-jdcloud_re-cs-02`、`ath11k-firmware-qcn9074-ddwrt`、`luci-app-athena-led`
4. **第 6 步 / 基础必需 4 件**：`kmod-nft-queue`、`luci-theme-argon`、`kmod-tun`、`kmod-nft-tproxy`
   ；外加 argon 配置页（判据：`luci-theme-argon=y` 即可，见下方「2026-10 上游变更」）
5. **第 6 步 / 互斥变体**（仅 `full`）：`dnsmasq-full=y` 且 `dnsmasq=n`、`ip-full=y` 且 `ip-tiny=n`
   （这两组各自 PROVIDES 同一个虚拟包，同时选上会在镜像组装期才崩）
6. **第 6 步 / `full` 档核心 10 个**：OpenClash、PassWall2、partexp、`dnsmasq_full_nftset`、
   `kmod-nft-socket`、`kmod-nft-nat`、`ruby`、`ruby-yaml`、SSR local、SSR redir
7. **编完 / 镜像结构**：`sysupgrade` 包里必须**同时有 kernel 和 rootfs**
   （只换 rootfs 不换内核会变砖）
8. **编完 / manifest 抽查**：`kmod-nft-queue`、`luci-theme-argon`、`luci-app-athena-led`
   必须真的在 `.manifest` 里；`full` 档另查 `luci-app-openclash`、`luci-app-passwall2`、
   `dnsmasq-full`、`ip-full`

**应用包是软校验，且发生在编译前（第 6 步），不是编完**：脚本会遍历
`apps-official.config` / `apps-thirdparty.config`，打印「点了 N 个，没进 .config 的 M 个」，
只报告不中断（包名在分支间偶有差异）。所以「编过了」不等于「包都在」，要对照这段输出。

## 2026-10 上游变更：argon 配置页并入主题（2026-11-19 修复）

上游 `immortalwrt/luci` 在 **2026-10-21** 的 `luci-theme-argon: update to 3.0.0` 提交里，
把独立的 `applications/luci-app-argon-config` **合并进了 `themes/luci-theme-argon`**：

- 主题包 Makefile 新增 `PKG_PROVIDES:=luci-app-argon-config`、`LUCI_BASENAME:=argon-config`
- 配置页/菜单/翻译随主题包：`htdocs/luci-static/resources/view/argon-config.js`、
  `root/usr/share/luci/menu.d/luci-app-argon-config.json`、`po/zh_Hans`
- `applications/luci-app-argon-config` 目录已删除（主题当前 `3.1.4`，`PKG_RELEASE:=20261113`）

后果：`seed.config` 里那行 `CONFIG_PACKAGE_luci-app-argon-config=y` 的**符号已不存在**，
`make defconfig` 静默丢掉它，第 6 步硬校验就报「必需包没被选上：luci-app-argon-config」。
`2026-10-17` 那轮能过、`2026-11-19` 这轮挂掉，原因就是这条上游改动。

修复内容：

1. `seed.config`：删掉 `CONFIG_PACKAGE_luci-app-argon-config=y`（选 `luci-theme-argon` 即带配置页）
2. `build-immortalwrt.sh` 第 6 步：argon 配置页判据改成「独立包在 **或** 主题在」，两边兼容
3. `build-immortalwrt.sh` 第 5 步：`make defconfig` 后新增**seed 丢弃报告**，把 seed 里点亮却没进
   `.config` 的项逐条 `✗` 打出来 —— 这类上游改名/合并会在这一步立刻暴露，而不是等到硬校验报错

> 判断依据记一下：**defconfig 丢弃不存在的符号时不会报错也不会警告**，只会在 `.config` 里消失。
> 所以 seed 里每写一个 `CONFIG_PACKAGE_xxx=y`，都要有对应的硬校验或丢弃报告兜着。

## 从 ones20250 吸收的配置（2026-11-19）

`ones20250/Openwrt-AX6600` 只是配置/脚本仓库（464KB），源码是 `VIKINGYFY/immortalwrt@owrt` 的 fork，
和我们同一棵树，所以它的 `CONFIG_` 符号可以直接用。下面是**实际加进 `seed.config` 的项**：

| 项 | 作用 | 备注 |
|---|---|---|
| `fullconenat-sonic=y` | 全锥 NAT1 | 见下方说明，树里本来就有且默认进 |
| `IPQ_MEM_PROFILE_1024=y` | 1GB 内存档位 | ⚠️ 符号未验证，见下 |
| `KERNEL_CC_OPTIMIZE_FOR_PERFORMANCE=y` | 内核用 -O2 而非 -Os | 拿体积换性能 |
| `kmod-nft-offload` / `nft-fib` / `nft-netdev` | PPE 卸载 + 透明代理所需表达式 | 防御性声明，防上游改默认值 |
| `fstrim` / `resize2fs` / `tune2fs` | eMMC 维护、partexp 扩容后要用 | |
| `block-mount=y` / `mountd=n` | 挂载 | `mountd` 与新版 fstools 冲突 |
| `luci-app-wireless-regdb` | LuCI 里能选 US 地区 | 拿到正确功率上限 |
| `iperf3` | 测 2.5G 实际带宽 | `official`/`full` 档本来也有 |
| `skb_recycler=n` | 关掉老优化 | ones20250 注释「副作用大」 |

**刻意没采用的**（照抄会出问题）：

| 他的写法 | 为什么不要 |
|---|---|
| `CONFIG_PACKAGE_kmod-nft-queue=n` | open-box 的命门，必须 `=y` |
| `CONFIG_PACKAGE_iptables=n` + `kmod-nf-ipt=n` | SSR 和部分代理模式仍走 iptables |
| `CONFIG_PACKAGE_luci-app-fullconenat-sonic=y` | 这个包**不存在**（`immortalwrt/luci` 里 404），界面内嵌在 firewall4 |
| `CONFIG_DEVEL` / `CCACHE` / `TARGET_MULTI_PROFILE` / `TARGET_PER_DEVICE_ROOTFS` | 构建期开关，对成品无收益 |
| `samba4` / `arpbind` / `autoreboot` / `https-dns-proxy` / `sentinel` | 个人偏好；`samba4`、`arpbind`、`autoreboot` 在 `apps-official.config` 里已有 |

### 关于 WOL（只带 `etherwake`，不带 `wakeonlan`）

`apps-official.config` 里只点名了两项：

```config
CONFIG_PACKAGE_luci-app-wol=y
CONFIG_PACKAGE_etherwake=y
```

**故意没加 `wakeonlan`**。两者功能重叠（都是发 magic packet），区别在实现：

| 包 | 实现 | 连带依赖 | 体积 |
|---|---|---|---|
| `etherwake` | C，只依赖 libc | 无 | 极小 |
| `wakeonlan` | **Perl 脚本** | `perl` 5.40 + 22 个 `perlbase-*` | 实测 **3667 KiB** |

2026-11-19 在设备上 `apk add luci-app-wol wakeonlan` 实测：`luci-app-wol` 依赖只有
`etherwake / libc / luci-base`，**根本不需要 `wakeonlan`**；而 `wakeonlan` 一口气拉了
perl 全家。所以固件里只留前者，省下的 3.6MB 比命令行版那点便利值钱。

入口在 LuCI 的 **服务 → Wake on LAN**（`admin/services/wol`，`order: 90`），不是「网络」菜单。
包内文件：`/usr/share/luci/menu.d/luci-app-wol.json`、`/usr/share/rpcd/acl.d/luci-app-wol.json`、
`/usr/share/rpcd/ucode/luci.wol`、`/www/luci-static/resources/view/wol.js`、`/etc/config/luci-wol`。
装完必须 `/etc/init.d/rpcd restart`，否则菜单项不出现。

### 关于 `fullconenat-sonic`

- 在源码树里：`package/network/utils/fullconenat-sonic`，`PKG_VERSION:=20261116`
- Makefile 里 `DEFAULT:=y if PACKAGE_firewall4` —— 只要防火墙是 firewall4（默认就是），**它本来就会进**
- 依赖 `@LINUX_6_18`，我们是 6.18，满足
- 与 `kmod-nft-fullcone` / `kmod-ipt-fullconenat` 等 4 个旧包 CONFLICTS，我们一个都没装
- `seed.config` 里显式写 `=y` 只是**防止上游哪天改掉 DEFAULT** 被静默丢掉

### 关于 `IPQ_MEM_PROFILE_1024`（唯一没底的一条）

没找到 `IPQ_MEM_PROFILE` 的 `Config.in` 定义位置（试了三个路径都 404），`ones20250` release 里
那份完整 `.config` 也没下载成功。所以这条**可能生效，也可能被 `defconfig` 静默忽略**——
符号不存在时不会报错，编照样成功。刷完用 `free -m` 对比总内存，没变化就是没生效。

## 刷机前 10 分钟

按顺序在设备上执行（都只写 `/opt`，不动当前系统）：

```sh
# ① 整机配置备份（跨栈升级，出问题要能回滚）
sysupgrade -b /opt/config-before-owrt.tar.gz

# ② U-Boot 环境备份（万一 bootargs 不对，能照着改回来）
fw_printenv > /opt/uboot-env.txt 2>/dev/null || echo "没有 fw_printenv，跳过"

# ③ open-box 根 fs 那 6 项（上次已打好的包，确认还在）
ls -lh /opt/openbox-rootfs-parts.tar.gz

# ④ 记下当前分区，刷完对比
cat /proc/partitions > /opt/parts-before.txt
```

**注意**：跨栈（NSS → PPE）升级时，① 不是"冗余保险"而是**回滚依据**。同栈升级时 `sysupgrade` 本来就会保留 `/etc/config`，但换栈后如果网络配置语义变了（比如旧配置里的 NSS/flow offload 选项），你需要能拿一份干净的原配置对照。

## 刷机

```sh
sysupgrade -v /tmp/immortalwrt-qualcommax-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade.bin
```

保留配置是**有依据的**，四条都对得上：

| 判据 | 当前固件 | 新固件 |
|------|---------|--------|
| board 名 | `jdcloud,re-cs-02` | `jdcloud,re-cs-02` |
| target/subtarget | `qualcommax/ipq60xx` | `qualcommax/ipq60xx` |
| 网口名 | `wan` / `lan1~lan4` | `wan` / `lan1~lan4` |
| 内核分区 | p16/p17 各 6144KB | `KERNEL_SIZE := 6144k` |
| 根文件系统 | GPT，`root=PARTUUID=...` | GPT + `EmmcImage` |

`/opt`（p27，111.5G）不参与 sysupgrade，open-box 的数据和备份都在那里，不会丢。

## 刷完先验这几件事

```sh
# 1. 起来了、版本对
cat /etc/openwrt_release | grep -E "RELEASE|TARGET"

# 2. 2.5G 真的协商上了（重点看 speed 2500）
ethtool wan | grep -E "Speed|Duplex|Link detected"

# 3. nft queue 模块在
lsmod | grep -E "nft_queue|nfnetlink_queue"

# 4. 主题进了固件
opkg list-installed 2>/dev/null | grep argon || apk list -I 2>/dev/null | grep argon

# 5. 全锥 NAT 是否在（LuCI「防火墙」页也应有全锥 NAT 开关）
opkg list-installed 2>/dev/null | grep -i fullcone \
  || apk list -I 2>/dev/null | grep -i fullcone

# 6. 内存档位是否真的生效（和刷机前对比总内存）
free -m

# 7. eMMC 工具链在不在
for c in fstrim resize2fs tune2fs; do command -v $c || echo "$c 缺失"; done

# 8. 无线能不能选 US 地区（LuCI → 网络 → 无线 → 国家/地区）
```

`ethtool wan` 显示 `Speed: 2500Mb/s` 才算这次定制成功；如果还是 1000，先确认对端交换机和网线（超五类以上），再看 `dmesg | grep -i qca8081`。

第 7 项是 `IPQ_MEM_PROFILE_1024` 的唯一验证手段；第 8 项验证 `luci-app-wireless-regdb` 是否真进了镜像。

## 和原固件（ones20250 PLUS）的差距

原固件实测装了 542 个包，其中 **84 个是非 feeds/base 的应用层包**。换栈后它们的归属：

| 类别 | 数量 | 说明 |
|---|---|---|
| 官方 feed 有 | ~60 | `apps-official.config` 已全部点名 |
| 要第三方源 | ~8 | OpenClash / PassWall2 / SSR / partexp，`full` 档带回来 |
| 新固件自带 | — | `luci-app-athena-led`（在 `DEVICE_PACKAGES`）、`luci-app-firewall`、`luci-app-package-manager`、`argon`、`fullconenat-sonic`（见下） |
| **不能带** | 24 个 kmod | `kmod-qca-nss-dp/drv/ecm`、`kmod-qca-ssdk`、`nss-firmware`… NSS 栈专属，新栈走 PPE，物理上没有对应包，也不需要替代 |
| **明确不要** | 8 | iStore 全家（`luci-app-store`/`taskd`/`luci-lib-taskd`/`luci-lib-xterm`）、gowebdav 全家（官方 feed 无此包） |

`fullconenat-sonic` 不在这张差距表里了：它在源码树里（`package/network/utils/fullconenat-sonic`），
`DEFAULT:=y if PACKAGE_firewall4`，**默认就会被编进去**，`seed.config` 里只是显式写死。

## 回滚

- 配置出错但系统能起：`sysupgrade -r /opt/config-before-owrt.tar.gz` 或 LuCI 里恢复备份
- 系统起不来：U-Boot 恢复模式刷回原厂/旧固件，再 `fw_setenv` 按 `/opt/uboot-env.txt` 校正
- open-box：解 `/opt/openbox-rootfs-parts.tar.gz` → `enable` + `start`（详见 `/opt/openbox-preserve.sh restore`）
