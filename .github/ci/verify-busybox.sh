#!/usr/bin/env bash
# Fail the build if the BusyBox binary did not make it into the recovery root.
set -euo pipefail

: "${FOX_DIR:?FOX_DIR not set}"

B=$(find "$FOX_DIR/out" -type f -path '*/recovery/root/sbin/busybox' -print -quit 2>/dev/null || true)
if [ -z "$B" ]; then
    B=$(find "$FOX_DIR/out" -type f -path '*/recovery/root/*busybox*' -print -quit 2>/dev/null || true)
fi
[ -n "$B" ] || {
    echo "BusyBox was not copied into the recovery root under $FOX_DIR/out" >&2
    exit 1
}

echo "recovery busybox: $B"
file "$B"
case "$(file -b "$B")" in
    *ARM\ aarch64*statically\ linked*) ;;
    *) echo "not a static aarch64 binary" >&2; exit 1 ;;
esac

BUILT=${BUSYBOX_BIN:-${RUNNER_TEMP:-/tmp}/busybox-build/out/busybox}
if [ -f "$BUILT" ]; then
    cmp -s "$B" "$BUILT" || {
        echo "recovery BusyBox differs from the freshly built binary: $B != $BUILT" >&2
        exit 1
    }
    echo "recovery BusyBox matches freshly built binary"
else
    echo "warning: freshly built BusyBox not found for comparison: $BUILT" >&2
fi

readelf -lW "$B" >"${TMPDIR:-/tmp}/lmi-busybox-headers.txt"
tls_align=$(awk '/TLS/{print $NF; exit}' "${TMPDIR:-/tmp}/lmi-busybox-headers.txt")
echo "TLS alignment: $tls_align"
[ "$tls_align" = "0x40" ] || {
    echo "unexpected TLS alignment: $tls_align" >&2
    exit 1
}

# The target binary cannot be executed on the x86_64 runner. Check that every
# expected applet name is embedded in the binary instead.
EXPECTED=${BUSYBOX_APPLETS:-${GITHUB_WORKSPACE:-$PWD}/.github/ci/busybox-applets.txt}
[ -f "$EXPECTED" ] || {
    echo "expected applet list not found: $EXPECTED" >&2
    exit 1
}
strings -n 1 "$B" >"${TMPDIR:-/tmp}/lmi-busybox-strings.txt"
missing=0
while IFS= read -r a; do
    [ -n "$a" ] || continue
    if ! grep -Fxq "$a" "${TMPDIR:-/tmp}/lmi-busybox-strings.txt"; then
        echo "missing applet string: $a" >&2
        missing=1
    fi
done <"$EXPECTED"
[ "$missing" -eq 0 ] || exit 1
echo "all $(wc -l <"$EXPECTED") expected applets present"

# A few key applet symlinks should exist when OrangeFox's predefined list is present.
for a in awk sed grep tar; do
    if [ -e "$(dirname "$B")/$a" ]; then
        echo "applet link: $a -> $(readlink "$(dirname "$B")/$a" 2>/dev/null || echo present)"
    else
        echo "note: no /sbin/$a link; busybox applet is still available via /sbin/busybox $a"
    fi
done
