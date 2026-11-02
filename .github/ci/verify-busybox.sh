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
n=$("$B" --list | wc -l)
echo "applets: $n"
[ "$n" -eq 364 ] || {
    echo "unexpected applet count: $n" >&2
    exit 1
}

readelf -lW "$B" >"${TMPDIR:-/tmp}/lmi-busybox-headers.txt"
tls_align=$(awk '/TLS/{print $NF; exit}' "${TMPDIR:-/tmp}/lmi-busybox-headers.txt")
echo "TLS alignment: $tls_align"
[ "$tls_align" = "0x40" ] || {
    echo "unexpected TLS alignment: $tls_align" >&2
    exit 1
}

# A few key applet symlinks should exist when OrangeFox's predefined list is present.
for a in awk sed grep tar; do
    if [ -e "$(dirname "$B")/$a" ]; then
        echo "applet link: $a -> $(readlink "$(dirname "$B")/$a" 2>/dev/null || echo present)"
    else
        echo "note: no /sbin/$a link; busybox applet is still available via /sbin/busybox $a"
    fi
done
