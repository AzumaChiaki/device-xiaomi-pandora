#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${1:-$ROOT_DIR/plg/images}"

need_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "missing required file: $file" >&2
        exit 1
    fi
}

need_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "missing required command: $cmd" >&2
        exit 1
    fi
}

need_cmd python3
need_cmd lz4
need_cmd cpio

need_file "$IMAGES_DIR/boot.img"
need_file "$IMAGES_DIR/vendor_boot.img"
need_file "$IMAGES_DIR/recovery.img"
need_file "$IMAGES_DIR/dtbo.img"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pandora-prep.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$IMAGES_DIR/boot.img" "$IMAGES_DIR/vendor_boot.img" "$IMAGES_DIR/recovery.img" "$TMP_DIR" <<'PY'
import pathlib
import struct
import sys

boot_img = pathlib.Path(sys.argv[1])
vendor_boot_img = pathlib.Path(sys.argv[2])
recovery_img = pathlib.Path(sys.argv[3])
out_dir = pathlib.Path(sys.argv[4])


def align(value: int, page: int) -> int:
    return ((value + page - 1) // page) * page


def parse_boot(path: pathlib.Path):
    blob = path.read_bytes()
    if blob[:8] != b"ANDROID!":
        raise SystemExit(f"{path} is not an Android boot image")
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack_from("<IIII", blob, 8)
    header_version = struct.unpack_from("<I", blob, 40)[0]
    cmdline = blob[44:44 + 1536].split(b"\x00", 1)[0].decode("ascii", "ignore")
    page = 4096
    header_aligned = align(header_size, page)
    kernel_off = header_aligned
    ramdisk_off = kernel_off + align(kernel_size, page)
    return {
        "blob": blob,
        "kernel_size": kernel_size,
        "ramdisk_size": ramdisk_size,
        "os_version": os_version,
        "header_size": header_size,
        "header_version": header_version,
        "cmdline": cmdline,
        "kernel_off": kernel_off,
        "ramdisk_off": ramdisk_off,
    }


boot = parse_boot(boot_img)
if boot["kernel_size"] <= 0:
    raise SystemExit("boot.img does not contain a kernel payload")
(out_dir / "Image").write_bytes(
    boot["blob"][boot["kernel_off"]:boot["kernel_off"] + boot["kernel_size"]]
)

recovery = parse_boot(recovery_img)
if recovery["ramdisk_size"] <= 0:
    raise SystemExit("recovery.img does not contain a ramdisk payload")
(out_dir / "recovery_ramdisk.lz4").write_bytes(
    recovery["blob"][recovery["ramdisk_off"]:recovery["ramdisk_off"] + recovery["ramdisk_size"]]
)

vendor_blob = vendor_boot_img.read_bytes()
if vendor_blob[:8] != b"VNDRBOOT":
    raise SystemExit("vendor_boot.img is not a vendor boot image")

header_version = struct.unpack_from("<I", vendor_blob, 8)[0]
if header_version < 4:
    raise SystemExit(f"unsupported vendor boot header version: {header_version}")

page_size, kernel_addr, ramdisk_addr, vendor_ramdisk_size = struct.unpack_from("<IIII", vendor_blob, 12)
cmdline = vendor_blob[28:28 + 2048].split(b"\x00", 1)[0].decode("ascii", "ignore")
offset = 28 + 2048
tags_addr = struct.unpack_from("<I", vendor_blob, offset)[0]
offset += 4
board_name = vendor_blob[offset:offset + 16].split(b"\x00", 1)[0].decode("ascii", "ignore")
offset += 16
header_size = struct.unpack_from("<I", vendor_blob, offset)[0]
offset += 4
dtb_size = struct.unpack_from("<I", vendor_blob, offset)[0]
offset += 4
dtb_addr = struct.unpack_from("<Q", vendor_blob, offset)[0]
offset += 8
table_size, table_num, table_entry_size, bootconfig_size = struct.unpack_from("<IIII", vendor_blob, offset)

header_aligned = align(header_size, page_size)
vendor_ramdisk_aligned = align(vendor_ramdisk_size, page_size)
dtb_off = header_aligned + vendor_ramdisk_aligned
table_off = dtb_off + align(dtb_size, page_size)
bootconfig_off = table_off + align(table_size, page_size)

(out_dir / "vendor_ramdisk.lz4").write_bytes(
    vendor_blob[header_aligned:header_aligned + vendor_ramdisk_size]
)
(out_dir / "dtb.img").write_bytes(vendor_blob[dtb_off:dtb_off + dtb_size])
(out_dir / "bootconfig.txt").write_bytes(vendor_blob[bootconfig_off:bootconfig_off + bootconfig_size])

meta = "\n".join([
    f"boot_header_version={boot['header_version']}",
    f"boot_kernel_size={boot['kernel_size']}",
    f"boot_ramdisk_size={boot['ramdisk_size']}",
    f"boot_header_size={boot['header_size']}",
    f"boot_cmdline={boot['cmdline']}",
    f"vendor_boot_header_version={header_version}",
    f"vendor_boot_page_size={page_size}",
    f"vendor_boot_kernel_addr=0x{kernel_addr:x}",
    f"vendor_boot_ramdisk_addr=0x{ramdisk_addr:x}",
    f"vendor_boot_ramdisk_size={vendor_ramdisk_size}",
    f"vendor_boot_cmdline={cmdline}",
    f"vendor_boot_tags_addr=0x{tags_addr:x}",
    f"vendor_boot_board_name={board_name}",
    f"vendor_boot_header_size={header_size}",
    f"vendor_boot_dtb_size={dtb_size}",
    f"vendor_boot_dtb_addr=0x{dtb_addr:x}",
    f"vendor_boot_table_size={table_size}",
    f"vendor_boot_table_num={table_num}",
    f"vendor_boot_table_entry_size={table_entry_size}",
    f"vendor_boot_bootconfig_size={bootconfig_size}",
    f"vendor_boot_dtb_offset={dtb_off}",
    f"vendor_boot_table_offset={table_off}",
    f"vendor_boot_bootconfig_offset={bootconfig_off}",
])
(out_dir / "extract.meta").write_text(meta + "\n")
PY

lz4 -d -f "$TMP_DIR/vendor_ramdisk.lz4" "$TMP_DIR/vendor_ramdisk.cpio" >/dev/null
mkdir -p "$TMP_DIR/vendor_ramdisk"
( cd "$TMP_DIR/vendor_ramdisk" && cpio -idmu < "$TMP_DIR/vendor_ramdisk.cpio" >/dev/null 2>&1 )

lz4 -d -f "$TMP_DIR/recovery_ramdisk.lz4" "$TMP_DIR/recovery_ramdisk.cpio" >/dev/null
mkdir -p "$TMP_DIR/recovery_ramdisk"
( cd "$TMP_DIR/recovery_ramdisk" && cpio -idmu < "$TMP_DIR/recovery_ramdisk.cpio" >/dev/null 2>&1 )

cp "$TMP_DIR/Image" "$ROOT_DIR/prebuilt/Image"
cp "$TMP_DIR/dtb.img" "$ROOT_DIR/prebuilt/dtb"
cp "$IMAGES_DIR/dtbo.img" "$ROOT_DIR/prebuilt/dtbo.img"
cp "$TMP_DIR/vendor_ramdisk/first_stage_ramdisk/fstab.qcom" "$ROOT_DIR/recovery/root/system/etc/recovery.fstab"
# Ensure removable storage (USB OTG, SD card) entries exist for vold auto-mount
python3 - "$ROOT_DIR/recovery/root/system/etc/recovery.fstab" <<'FSTAB_PY'
import sys
from pathlib import Path
fstab = Path(sys.argv[1])
content = fstab.read_text()
removable = """
# Removable storage: vold auto-discovers via uevents when device is plugged in
/devices/platform/soc/8804000.sdhci/mmc_host*           /storage/sdcard1       vfat    nosuid,nodev                                         wait,voldmanaged=sdcard1:auto,encryptable=footer
/devices/platform/soc/*.ssusb/*.dwc3/xhci-hcd.*.auto*   /storage/usbotg        vfat    nosuid,nodev                                         wait,voldmanaged=usbotg:auto
"""
if "voldmanaged=usbotg:auto" not in content:
    fstab.write_text(content.rstrip() + removable)
FSTAB_PY
cp "$TMP_DIR/recovery_ramdisk/init.recovery.qcom.rc" "$ROOT_DIR/recovery/root/init.recovery.qcom.rc"
cp "$TMP_DIR/recovery_ramdisk/system/etc/ueventd.rc" "$ROOT_DIR/recovery/root/system/etc/ueventd.rc"

# Ensure recovery init keeps touchscreen hooks when init.recovery.qcom.rc is refreshed from stock ramdisk.
python3 - "$ROOT_DIR/recovery/root/init.recovery.qcom.rc" <<'PY'
import sys
from pathlib import Path

rc = Path(sys.argv[1])
content = rc.read_text()

trigger = """
on late-init
    # Mount vendor_dlkm and load the minimal touch modules early.
    start load_touch_modules
"""

trigger_postinit = """
on property:orangefox.postinit.status=1
    # Run a second pass after OrangeFox startup in case the first pass raced.
    start load_touch_modules
"""

service_touch = """
service load_touch_modules /system/bin/sh /sbin/load_touch_modules.sh
    class core
    user root
    group root system input
    seclabel u:r:recovery:s0
    oneshot
"""

updated = content
if "start load_touch_modules" not in updated:
    updated = updated.rstrip() + "\n\n" + trigger.strip("\n") + "\n"
if "on property:orangefox.postinit.status=1" not in updated:
    updated = updated.rstrip() + "\n\n" + trigger_postinit.strip("\n") + "\n"
if "service load_touch_modules " not in updated:
    updated = updated.rstrip() + "\n" + service_touch.strip() + "\n"

if updated != content:
    rc.write_text(updated)
PY

# Drop malformed line copied from stock ueventd that causes parsing to stop early.
python3 - "$ROOT_DIR/recovery/root/vendor/ueventd.rc" <<'PY'
import sys
from pathlib import Path

ueventd = Path(sys.argv[1])
if not ueventd.exists():
    raise SystemExit(0)

lines = ueventd.read_text().splitlines()
filtered = [line for line in lines if line.strip() != "*/"]
if filtered != lines:
    ueventd.write_text("\n".join(filtered) + "\n")
PY

echo "Prepared files from $IMAGES_DIR"
echo "  - prebuilt/Image"
echo "  - prebuilt/dtb"
echo "  - prebuilt/dtbo.img"
echo "  - recovery/root/system/etc/recovery.fstab"
echo "  - recovery/root/init.recovery.qcom.rc"
echo "  - recovery/root/system/etc/ueventd.rc"
echo
echo "Extract metadata:"
cat "$TMP_DIR/extract.meta"
