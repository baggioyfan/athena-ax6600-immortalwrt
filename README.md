# 雅典娜 AX6600（JDCloud RE-CS-02）定制 ImmortalWrt

给**京东云无线宝雅典娜 AX6600** 编的定制固件，只做三件事，别的都跟随上游默认。

| # | 改动 | 落地位置 | 为什么 |
|---|------|---------|--------|
| 1 | `kmod-nft-queue` | `config/seed.config` | 原固件 `GENERAL_AX6600.txt` 里写的是 `=n`，open-box 起不来/接管不了 nft 队列 |
| 2 | argon 主题 | `config/seed.config` | 界面 |
| 3 | 2.5G WAN | 源码 DTS（无需 config） | 旧 NSS 栈的 DTS 是 `phy-mode = "sgmii"`（1.25Gbps 线速，物理载不动 2.5G）；`owrt` 分支改成 `2500base-x` + `pcs-handle = <&uniphy1 0>` |

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

Actions → `Build Athena AX6600 (RE-CS-02)` → Run workflow（分支保持 `owrt`）。

跑完在 run 页面底部下载 artifact，里面有：

- `*-squashfs-sysupgrade.bin` ← 日常升级用这个
- `*-factory.bin` ← 只在救砖 / U-Boot 恢复时用

本地 / 自己的 Linux 机器也能跑：

```sh
./build-immortalwrt.sh              # 默认 owrt
BRANCH=owrt WORK=$HOME/immortalwrt ./build-immortalwrt.sh
```

脚本会在编译前做这些硬校验（任何一条不过就立刻退出，不浪费两小时）：

1. DTS 的 WAN 段确实是 `2500base-x` + `uniphy1` + `label="wan"`
2. `.config` 里设备 `jdcloud_re-cs-02` 被选中
3. `kmod-nft-queue` / `luci-theme-argon` / `luci-app-argon-config` / `kmod-tun` / `kmod-nft-tproxy` 都 `=y`
4. 编完检查 sysupgrade 包里**同时有 kernel 和 rootfs**（只换 rootfs 不换内核会变砖）

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

## 回滚

- 配置出错但系统能起：`sysupgrade -r /opt/config-before-owrt.tar.gz` 或 LuCI 里恢复备份
- 系统起不来：U-Boot 恢复模式刷回原厂/旧固件，再 `fw_setenv` 按 `/opt/uboot-env.txt` 校正
- open-box：解 `/opt/openbox-rootfs-parts.tar.gz` → `enable` + `start`（详见 `/opt/openbox-preserve.sh restore`）


