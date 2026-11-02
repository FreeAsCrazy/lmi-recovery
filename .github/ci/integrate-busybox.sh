#!/usr/bin/env bash
# Put the freshly built BusyBox into the synced OrangeFox vendor tree and
# enable FOX_USE_BUSYBOX_BINARY in the throw-away device-tree copy.
set -euo pipefail

: "${FOX_DIR:?FOX_DIR not set}"
BUSYBOX_BIN=${BUSYBOX_BIN:-${RUNNER_TEMP:-/tmp}/busybox-build/out/busybox}
# OrangeFox 16.0 uses vendor/recovery; older manifests use vendor/twrp.
if [ -n "${FOX_VENDOR_PATH:-}" ]; then
    VENDOR=$FOX_VENDOR_PATH
elif [ -d "$FOX_DIR/vendor/recovery" ]; then
    VENDOR=$FOX_DIR/vendor/recovery
else
    VENDOR=$FOX_DIR/vendor/twrp
fi
DEST=$VENDOR/prebuilt/arm64/busybox
DEVICE=$FOX_DIR/device/xiaomi/lmi

[ -x "$BUSYBOX_BIN" ] || {
    echo "BusyBox binary not found: $BUSYBOX_BIN" >&2
    exit 1
}
[ -d "$VENDOR" ] || {
    echo "OrangeFox vendor tree not found: $VENDOR" >&2
    exit 1
}
[ -f "$DEVICE/vendorsetup.sh" ] || {
    echo "vendorsetup.sh not found: $DEVICE/vendorsetup.sh" >&2
    exit 1
}

mkdir -p "$(dirname "$DEST")"
install -m 0755 "$BUSYBOX_BIN" "$DEST"
echo "installed: $DEST"
file "$DEST"
case "$(file -b "$DEST")" in
    *ARM\ aarch64*statically\ linked*) ;;
    *) echo "not a static aarch64 BusyBox: $DEST" >&2; exit 1 ;;
esac

# Enable BusyBox only in the build copy. The source device tree stays untouched.
sed -i -E 's/export FOX_USE_BUSYBOX_BINARY=0/export FOX_USE_BUSYBOX_BINARY=1/' "$DEVICE/vendorsetup.sh"
grep -n 'FOX_USE_BUSYBOX_BINARY=' "$DEVICE/vendorsetup.sh"

if [ ! -f "$VENDOR/Files/bbx_sel_applets.txt" ]; then
    echo "warning: $VENDOR/Files/bbx_sel_applets.txt missing; busybox will be installed without applet symlinks" >&2
else
    echo "applet symlink list: $VENDOR/Files/bbx_sel_applets.txt ($(wc -l <"$VENDOR/Files/bbx_sel_applets.txt") entries)"
fi
