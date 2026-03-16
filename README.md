# OFRP Device Tree for Xiaomi 17 Pro (pandora)

参考：<https://github.com/0x7B00/OFRP>

## 当前设备信息（来自刷机包）

- Device: `pandora`
- Platform: `canoe`
- Android: `16` (`sdk 36`)
- Build: `OS3.0.30.0.WBLCNXM`
- Security patch: `2025-10-01`

## 已知问题

- 无法解密/挂载data分区
- 部分刷机包无法正常刷入

## 已完成的重建内容

- 该设备树在 `pandora/canoe` 已经成功开机并修复触控驱动和挂载外部otg
- `BoardConfig.mk` 切换到 boot header v4，并同步分区大小
- 预编译内核与设备树已替换：
  - `prebuilt/Image` <- `boot.img` kernel
  - `prebuilt/dtb` <- `vendor_boot.img` dtb
  - `prebuilt/dtbo.img` <- `dtbo.img`
- recovery 关键配置同步：
  - `recovery/root/system/etc/recovery.fstab`
  - `recovery/root/init.recovery.qcom.rc`
  - `recovery/root/system/etc/ueventd.rc`

## 一键同步脚本

固件更新后可以直接运行：

```bash
./prepare_from_plg.sh
```

可选指定固件目录：

```bash
./prepare_from_plg.sh /path/to/rom/images
```

## 获取完整源码（OrangeFox 12.1）

按照 OrangeFox 官方 `sync` 工具拉取完整源码：

```bash
mkdir -p ~/OrangeFox_sync
cd ~/OrangeFox_sync
git clone https://gitlab.com/OrangeFox/sync.git
cd sync
./orangefox_sync.sh --branch 12.1 --path ~/fox_12.1
```

然后把本仓库放到：

```bash
~/fox_12.1/device/xiaomi/pandora
```

## 编译

将仓库放到源码树 `device/xiaomi/pandora` 后，先做检查：

```bash
ls -la device/xiaomi/pandora
grep -n "twrp_pandora" device/xiaomi/pandora/AndroidProducts.mk
```

应能看到：

- `twrp_pandora.mk`
- `BoardConfig.mk`
- `prebuilt/Image`、`prebuilt/dtb`、`prebuilt/dtbo.img`
- `AndroidProducts.mk` 里有 `twrp_pandora-*`

`fox_12.1` 分支下必须保证：

```makefile
PRODUCT_TARGET_VNDK_VERSION := 32
PRODUCT_SHIPPING_API_LEVEL := 32
```

否则会报：

```text
BOARD_SYSTEMSDK_VERSIONS (32) must all be greater than or equal to PRODUCT_SHIPPING_API_LEVEL (36)
```

`fox_12.1`（新版 OrangeFox）里 `FOX_VERSION` 已废弃，需改为：

```bash
export FOX_MAINTAINER_PATCH_VERSION=你的维护者补丁版本号
```

建议编译顺序：

```bash
. build/envsetup.sh
lunch twrp_pandora-eng
mka bootimage
```

如 `bootimage` 报目标不匹配，再尝试：

```bash
mka recoveryimage
```

## GitHub Action（云编译）

可继续使用项目根目录下的 OrangeFox Action Builder，按下面参数填写：

参考：

- `https://github.com/ymdzq/OrangeFox-Action-Builder`
修改版：

操作流程：

1. Fork 上面的 Action Builder 仓库到你自己的账号
2. 进入你 Fork 后仓库的 `Actions`
3. 选择 `OrangeFox - Build`
4. 点击 `Run workflow`，按下方参数填写

- OrangeFox Branch: `14.1`
- Custom Recovery Tree: `https://github.com/AzumaChiaki/OFRP`
- Custom Recovery Tree Branch: `fox_12.1-a14`
- Specify your device path: `device/xiaomi/pandora`
- Specify your Device Codename: `pandora`
- Specify your Build Target: `boot`

如果 `boot` 失败且日志提示目标不匹配，再把 Build Target 改为 `recovery` 重跑。

当前 workflow 会在同步 `fox_14.1` 源码后自动执行 `patches/fox_14.1/apply_a16_compat.sh`，先为 `cts/tests/tests/os/assets/platform_releases.txt` 和 `platform_versions.txt` 补上 `16`，以解决 A16 设备树在 14.1 基线上的首个阻塞报错。

如果后续云编译仍然因为 Android 16 兼容问题失败，优先继续扩展这一个补丁入口，而不是把兼容逻辑分散到设备树和 workflow 的其他步骤里。

建议在 Action 前先确认仓库里已包含最新 `plg/images` 提取结果（或本地先跑过一次 `./prepare_from_plg.sh` 再提交）。
