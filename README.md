# 雅典娜 AX6600（JDCloud RE-CS-02）定制 ImmortalWrt

给**京东云无线宝雅典娜 AX6600** 编的定制固件。三处硬改动是固定的，应用包按 `APPS` 分档。

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

WAN 那一段（编译脚本会逐字校验，被上游改回去就直接停）：

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

**只有手动触发，push 不会自动编。**

Actions → `Build Athena AX6600 (RE-CS-02)` → Run workflow（分支保持 `owrt`，选 `apps` 档位）。

| `apps` | 内容 | 大概耗时 | 什么时候用 |
|--------|------|---------|-----------|
| `full`（默认） | 官方应用包约 60 项 **+** OpenClash、PassWall2、SSR、partexp | 3.5~5h | 贴近原固件 PLUS，一次到位 |
| `official` | 只加官方 feed 应用包约 60 项：adguardhome、docker 全家、samba4、ttyd、upnp、ddns、p910nd、sing-box、xray、iperf3… | 3~4h | 出问题时的退路 |
| `none` | 系统 + 三处改动 | 2~3h | 只想先确认 2.5G 通不通 |

`full` 那一层的外部仓库当初是针对旧栈 + 旧版 luci 编的，在 `owrt` 上**没有官方保证**。
脚本为此加了两道保险：编译前硬校验 10 个核心包是否真的进了 `.config`；编译中若某个**非核心包**挂掉，
会自动把它从 `.config` 剔除后原地续编（已编译产物保留，只补缺失部分），不浪费整轮时间。

`full` **不含**：iStore 全家、gowebdav 全家（都明确不要）；NSS 栈的 24 个 kmod（新栈物理上不存在，
也不需要替代品——PPE + mainline DSA + 内核 flowtable 就是加速路径）。

跑完在 run 页面底部下载 artifact，里面有：

- `*-squashfs-sysupgrade.bin` ← 日常升级用这个
- `*-factory.bin` ← 只在救砖 / U-Boot 恢复时用

本地 / 自己的 Linux 机器也能跑：

```sh
./build-immortalwrt.sh                  # 默认 owrt + full
APPS=official ./build-immortalwrt.sh    # 退路：只官方应用包
APPS=none   ./build-immortalwrt.sh      # 只验 2.5G
BRANCH=owrt WORK=$HOME/immortalwrt ./build-immortalwrt.sh
```

脚本会在编译前做这些硬校验（任何一条不过就立刻退出，不浪费几小时）：

1. DTS 的 WAN 段确实是 `2500base-x` + `uniphy1` + `label="wan"`
2. `.config` 里设备 `jdcloud_re-cs-02` 被选中
3. 设备自带包没被覆盖：`ipq-wifi-jdcloud_re-cs-02`、`ath11k-firmware-qcn9074-ddwrt`、`luci-app-athena-led`
   （缺了刷完没 WiFi / LED 屏黑）
4. `kmod-nft-queue` / `luci-theme-argon` / `luci-app-argon-config` / `kmod-tun` / `kmod-nft-tproxy` 都 `=y`
5. 互斥变体没打架：`dnsmasq-full=y` 且 `dnsmasq=n`、`ip-full=y` 且 `ip-tiny=n`
   （这两组各自 PROVIDES 同一个虚拟包，同时选上会在镜像组装期才崩）
6. `full` 档的 10 个核心包都 `=y`：OpenClash / PassWall2 / partexp / `dnsmasq_full_nftset` /
   `kmod-nft-socket` / `kmod-nft-nat` / `ruby` / `ruby-yaml` / SSR local+redir
7. 编完检查 sysupgrade 包里**同时有 kernel 和 rootfs**（只换 rootfs 不换内核会变砖）
8. 编完从 `.manifest` 抽查关键包是否真进了镜像（`.config` 里 `=y` 不等于镜像里有）

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

## 刷完先验这四件事

```sh
# 1. 起来了、版本对
cat /etc/openwrt_release | grep -E "RELEASE|TARGET"

# 2. 2.5G 真的协商上了（重点看 speed 2500）
ethtool wan | grep -E "Speed|Duplex|Link detected"

# 3. nft queue 模块在
lsmod | grep -E "nft_queue|nfnetlink_queue"

# 4. 主题进了固件
opkg list-installed 2>/dev/null | grep argon || apk list -I 2>/dev/null | grep argon
```

`ethtool wan` 显示 `Speed: 2500Mb/s` 才算这次定制成功；如果还是 1000，先确认对端交换机和网线（超五类以上），再看 `dmesg | grep -i qca8081`。

## 和原固件（ones20250 PLUS）的差距

原固件实测装了 542 个包，其中 **84 个是非 feeds/base 的应用层包**。换栈后它们的归属：

| 类别 | 数量 | 说明 |
|---|---|---|
| 官方 feed 有 | ~60 | `apps-official.config` 已全部点名 |
| 要第三方源 | ~8 | OpenClash / PassWall2 / SSR / partexp，`full` 档带回来 |
| 新固件自带 | — | `luci-app-athena-led`（在 `DEVICE_PACKAGES`）、`luci-app-firewall`、`luci-app-package-manager`、`argon` |
| **不能带** | 24 个 kmod | `kmod-qca-nss-dp/drv/ecm`、`kmod-qca-ssdk`、`nss-firmware`… NSS 栈专属，新栈走 PPE，物理上没有对应包，也不需要替代 |
| **明确不要** | 8 | iStore 全家（`luci-app-store`/`taskd`/`luci-lib-taskd`/`luci-lib-xterm`）、gowebdav 全家（官方 feed 无此包） |
| 不需要 | 1 | `fullconenat-sonic`（自定义全锥 NAT 补丁包，新栈流程不同，未验证） |

应用包的校验是**软校验**：编完会打印「点了 N 个、没进 .config 的 M 个」，不会静默丢失。
基础三件（`kmod-nft-queue` / `argon` / `tproxy`+`tun`）是硬校验，缺一个就中止。

## 回滚

- 配置出错但系统能起：`sysupgrade -r /opt/config-before-owrt.tar.gz` 或 LuCI 里恢复备份
- 系统起不来：U-Boot 恢复模式刷回原厂/旧固件，再 `fw_setenv` 按 `/opt/uboot-env.txt` 校正
- open-box：解 `/opt/openbox-rootfs-parts.tar.gz` → `enable` + `start`（详见 `/opt/openbox-preserve.sh restore`）


