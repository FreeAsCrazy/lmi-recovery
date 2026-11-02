#!/usr/bin/env bash
# Build a static aarch64 BusyBox 1.36.1 for Android recovery.
#
# The applet set is the union of:
#   - BusyBox v1.36.1.1 topjohnwu
#   - BusyBox v1.36.1-osm0sis
#
# Base source/config/patches: osm0sis/android-busybox-ndk
# Extra fixes: .github/ci/patches/busybox-lmi-fixes.patch
#
# Outputs:
#   $OUT/busybox              stripped binary
#   $OUT/busybox_unstripped   debug binary
#   $OUT/applets.txt          applet list
set -euo pipefail

CI_DIR=${CI_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
API=${API:-29}
NDK_VERSION=${NDK_VERSION:-r27c}
BB_VERSION=${BB_VERSION:-1.36.1}
WORK=${BUSYBOX_BUILD_DIR:-${WORK:-${RUNNER_TEMP:-/tmp}/busybox-build}}
OUT=${BUSYBOX_OUT:-$WORK/out}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
HOSTCC=${HOSTCC:-gcc}

NDK=${NDK:-$WORK/android-ndk-$NDK_VERSION}
NDK_BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
CC=${CC:-$NDK_BIN/aarch64-linux-android${API}-clang}
AR=${AR:-$NDK_BIN/llvm-ar}
RANLIB=${RANLIB:-$NDK_BIN/llvm-ranlib}
STRIP=${STRIP:-$NDK_BIN/llvm-strip}
NM=${NM:-$NDK_BIN/llvm-nm}
OBJCOPY=${OBJCOPY:-$NDK_BIN/llvm-objcopy}

log() { printf '\n=== %s ===\n' "$*" >&2; }
die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }

download() {
    local url=$1 out=$2
    mkdir -p "$(dirname "$out")"
    [ -s "$out" ] && return 0
    local i
    for i in 1 2 3 4 5; do
        if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
                --max-time 900 -o "$out.part" "$url"; then
            mv "$out.part" "$out"
            return 0
        fi
        rm -f "$out.part"
        echo "download failed (attempt $i): $url" >&2
        sleep $((i * 3))
    done
    return 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need curl
need tar
need unzip
need patch
need make
need python3
need readelf
need file

mkdir -p "$WORK" "$OUT"

# ---------------------------------------------------------------- NDK
if [ ! -x "$CC" ]; then
    log "Downloading Android NDK $NDK_VERSION"
    download "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
        "$WORK/android-ndk-${NDK_VERSION}-linux.zip"
    rm -rf "$NDK"
    unzip -q "$WORK/android-ndk-${NDK_VERSION}-linux.zip" -d "$WORK"
    [ -x "$CC" ] || die "NDK clang not found: $CC"
fi

# ---------------------------------------------------------------- sources
BB_DIR=$WORK/busybox-$BB_VERSION
OSM_DIR=$WORK/android-busybox-ndk-master
PCRE_DIR=$WORK/pcre2-10.44
SEL_DIR=$WORK/selinux-3.7

if [ ! -f "$BB_DIR/.lmi-patched" ]; then
    log "Downloading BusyBox $BB_VERSION"
    download "https://busybox.net/downloads/busybox-${BB_VERSION}.tar.bz2" \
        "$WORK/busybox-${BB_VERSION}.tar.bz2"
    rm -rf "$BB_DIR"
    mkdir -p "$BB_DIR"
    tar -xjf "$WORK/busybox-${BB_VERSION}.tar.bz2" -C "$WORK"
    [ -d "$WORK/busybox-$BB_VERSION" ] || die "BusyBox source not extracted"

    log "Downloading osm0sis configs/patches"
    download "https://codeload.github.com/osm0sis/android-busybox-ndk/tar.gz/refs/heads/master" \
        "$WORK/android-busybox-ndk.tar.gz"
    rm -rf "$OSM_DIR"
    tar -xzf "$WORK/android-busybox-ndk.tar.gz" -C "$WORK"
    [ -d "$OSM_DIR/patches" ] || die "osm0sis patches not extracted"

    log "Applying osm0sis patches"
    for p in "$OSM_DIR"/patches/*.patch; do
        patch -d "$BB_DIR" -p1 --forward --batch <"$p" >/dev/null ||
            die "patch failed: $(basename "$p")"
    done

    log "Applying lmi fixes"
    patch -d "$BB_DIR" -p1 --forward --batch \
        <"$CI_DIR/patches/busybox-lmi-fixes.patch" >/dev/null ||
        die "lmi fixes patch failed"
    touch "$BB_DIR/.lmi-patched"
fi

if [ ! -d "$PCRE_DIR/src" ]; then
    log "Downloading PCRE2 10.44"
    download "https://codeload.github.com/PCRE2Project/pcre2/tar.gz/refs/tags/pcre2-10.44" \
        "$WORK/pcre2-10.44.tar.gz"
    rm -rf "$PCRE_DIR"
    tar -xzf "$WORK/pcre2-10.44.tar.gz" -C "$WORK"
    if [ ! -d "$PCRE_DIR/src" ] && [ -d "$WORK/pcre2-pcre2-10.44/src" ]; then
        mv "$WORK/pcre2-pcre2-10.44" "$PCRE_DIR"
    fi
    [ -d "$PCRE_DIR/src" ] || die "PCRE2 source not extracted"
fi

if [ ! -d "$SEL_DIR/libselinux/src" ]; then
    log "Downloading SELinux 3.7"
    download "https://codeload.github.com/SELinuxProject/selinux/tar.gz/refs/tags/3.7" \
        "$WORK/selinux-3.7.tar.gz"
    rm -rf "$SEL_DIR"
    tar -xzf "$WORK/selinux-3.7.tar.gz" -C "$WORK"
    [ -d "$SEL_DIR/libselinux/src" ] || die "SELinux source not extracted"
fi

# PCRE2 upstream tarball ships templates rather than generated files.
[ -f "$PCRE_DIR/src/config.h" ] ||
    cp "$PCRE_DIR/src/config.h.generic" "$PCRE_DIR/src/config.h"
[ -f "$PCRE_DIR/src/pcre2_chartables.c" ] ||
    cp "$PCRE_DIR/src/pcre2_chartables.c.dist" "$PCRE_DIR/src/pcre2_chartables.c"
mkdir -p "$PCRE_DIR/include"
if [ ! -f "$PCRE_DIR/include/pcre2.h" ]; then
    cat >"$PCRE_DIR/include/pcre2.h" <<'EOF'
#pragma once

#define PCRE2_CODE_UNIT_WIDTH 8

#include "../src/pcre2.h.generic"
EOF
fi

# ---------------------------------------------------------------- static libs
log "Building libpcre2.a"
rm -rf "$OUT/pcre2" "$OUT/selinux"
mkdir -p "$OUT/pcre2" "$OUT/selinux"
CFLAGS_LIB="-O2 -fPIC -DANDROID -D__ANDROID__"
PCRE_SRCS="pcre2_auto_possess.c pcre2_compile.c pcre2_config.c pcre2_context.c \
pcre2_convert.c pcre2_dfa_match.c pcre2_error.c pcre2_extuni.c \
pcre2_find_bracket.c pcre2_maketables.c pcre2_match.c pcre2_match_data.c \
pcre2_jit_compile.c pcre2_newline.c pcre2_ord2utf.c pcre2_pattern_info.c \
pcre2_serialize.c pcre2_string_utils.c pcre2_study.c pcre2_substitute.c \
pcre2_substring.c pcre2_tables.c pcre2_ucd.c pcre2_valid_utf.c \
pcre2_xclass.c pcre2_chartables.c pcre2_chkdint.c pcre2_script_run.c \
pcre2_ucptables.c"
pcobjs=""
for f in $PCRE_SRCS; do
    o=$OUT/pcre2/${f%.c}.o
    $CC $CFLAGS_LIB -DHAVE_CONFIG_H -DPCRE2_CODE_UNIT_WIDTH=8 \
        -I"$PCRE_DIR/src" -I"$PCRE_DIR/include" \
        -c "$PCRE_DIR/src/$f" -o "$o"
    pcobjs="$pcobjs $o"
done
$AR rcs "$OUT/libpcre2.a" $pcobjs

log "Building libselinux.a"
SEL_SRCS="avc.c avc_internal.c avc_sidtab.c booleans.c callbacks.c \
canonicalize_context.c checkAccess.c check_context.c compute_av.c \
compute_create.c compute_member.c context.c deny_unknown.c disable.c \
enabled.c fgetfilecon.c freecon.c fsetfilecon.c get_initial_context.c \
getenforce.c getfilecon.c getpeercon.c hashtab.c init.c label.c \
label_backends_android.c label_file.c label_support.c lgetfilecon.c \
load_policy.c lsetfilecon.c mapping.c matchpathcon.c policyvers.c \
procattr.c regex.c reject_unknown.c selinux_internal.c selinux_config.c \
sestatus.c seusers.c setenforce.c setexecfilecon.c setfilecon.c \
setrans_client.c sha1.c stringrep.c"
selobjs=""
for f in $SEL_SRCS; do
    o=$OUT/selinux/${f%.c}.o
    $CC $CFLAGS_LIB -DNO_PERSISTENTLY_STORED_PATTERNS -DDISABLE_SETRANS \
        -DDISABLE_BOOL -D_GNU_SOURCE -DNO_MEDIA_BACKEND -DNO_X_BACKEND \
        -DNO_DB_BACKEND -DUSE_PCRE2 -DPCRE2_CODE_UNIT_WIDTH=8 \
        -DHAVE_REALLOCARRAY=1 -DAUDITD_LOG_TAG=1003 \
        -I"$SEL_DIR/libselinux/include" -I"$SEL_DIR/libselinux/src" \
        -I"$PCRE_DIR/include" -I"$PCRE_DIR/src" \
        -c "$SEL_DIR/libselinux/src/$f" -o "$o"
    selobjs="$selobjs $o"
done
$AR rcs "$OUT/libselinux.a" $selobjs

log "Building libtls_align.a"
cat >"$OUT/tls_align.c" <<'EOF'
#include <stdint.h>
__attribute__((section(".tdata.bb_tls_align"), used, visibility("default"), aligned(64)))
volatile uint64_t bb_tls_align_pad[8] = {0};
EOF
$CC $CFLAGS_LIB -fno-emulated-tls -c "$OUT/tls_align.c" -o "$OUT/tls_align.o"
$AR rcs "$OUT/libtls_align.a" "$OUT/tls_align.o"

# BusyBox's SELinux support asks pkg-config for libsepol even though this
# minimal libselinux does not use it. Keep an empty archive for that lookup.
rm -f "$OUT/libsepol.a"
$AR rcs "$OUT/libsepol.a"

# ---------------------------------------------------------------- config
log "Configuring BusyBox"
rm -rf "$WORK/busybox-include"
cp -a "$CI_DIR/busybox-include" "$WORK/busybox-include"
cp "$OSM_DIR/osm0sis-full-selinux.config" "$BB_DIR/.config"
python3 - "$BB_DIR/.config" "$WORK" "$OUT" "$SEL_DIR" "$PCRE_DIR" <<'PY'
import sys
from pathlib import Path

cfg, work, out, sel, pcre = sys.argv[1:6]
p = Path(cfg)
lines = p.read_text().splitlines()
values = {
    "CONFIG_EXTRA_CFLAGS": (
        f'-DANDROID -D__ANDROID__ -D_GNU_SOURCE -DSK_RELEASE -Os '
        f'-fno-short-enums -fno-builtin-stpcpy -fno-emulated-tls '
        f'-I{work}/busybox-include -I{sel}/libselinux/include -I{pcre}/include'
    ),
    "CONFIG_EXTRA_LDFLAGS": f'-L{out} -Wl,-u,bb_tls_align_pad',
    "CONFIG_EXTRA_LDLIBS": "tls_align selinux pcre2",
    "CONFIG_NPROC": "y",
    "CONFIG_FALLOCATE": "y",
    "CONFIG_NSENTER": "y",
    "CONFIG_SEEDRNG": "y",
    "CONFIG_POWERTOP": "y",
    "CONFIG_FEATURE_POWERTOP_INTERACTIVE": "y",
}
done = set()
new = []
for line in lines:
    key = line.split("=", 1)[0]
    if line.startswith("# ") and line.endswith(" is not set"):
        key = line[2:-len(" is not set")]
    if key in values:
        val = values[key]
        if val in ("y", "n"):
            new.append(f"{key}={val}")
        else:
            new.append(f'{key}="{val}"')
        done.add(key)
    else:
        new.append(line)
for key, val in values.items():
    if key not in done:
        new.append(f'{key}="{val}"' if val not in ("y", "n") else f"{key}={val}")
p.write_text("\n".join(new) + "\n")
PY

# ---------------------------------------------------------------- build
log "Building BusyBox"
make -C "$BB_DIR" -j"$JOBS" \
    HOSTCC="$HOSTCC" \
    CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
    NM="$NM" OBJCOPY="$OBJCOPY" PKG_CONFIG=/bin/false

[ -x "$BB_DIR/busybox" ] || die "BusyBox build did not produce busybox"
install -m 0755 "$BB_DIR/busybox" "$OUT/busybox"
install -m 0755 "$BB_DIR/busybox_unstripped" "$OUT/busybox_unstripped"

# The target binary cannot run on the x86_64 runner. Reconstruct the applet
# list from BusyBox's generated include/applets.h instead.
python3 - "$BB_DIR/include/applets.h" "$BB_DIR/.config" "$OUT/applets.txt" <<'PY'
import re
import sys

applets_h, config, out = sys.argv[1:4]
enabled = {}
for line in open(config):
    m = re.match(r'^(CONFIG_[A-Z0-9_]+)=(y|n)$', line.strip())
    if m:
        enabled[m.group(1)] = m.group(2) == 'y'

applet_re = re.compile(
    r'APPLET(?:_NOEXEC|_NOFORK|_ODDNAME|_SCRIPTED)?\(\s*([^,\s]+)')
if_re = re.compile(r'^\s*IF_(NOT_)?([A-Z0-9_]+)\(')
names = set()
for line in open(applets_h):
    m = applet_re.search(line)
    im = if_re.match(line)
    if not m or not im:
        continue
    neg = bool(im.group(1))
    val = enabled.get('CONFIG_' + im.group(2), False)
    if (not neg and val) or (neg and not val):
        names.add(m.group(1).strip('"'))
names.discard('busybox')
with open(out, 'w') as f:
    for name in sorted(names):
        f.write(name + '\n')
PY

log "Verifying BusyBox"
file "$OUT/busybox"
readelf -lW "$OUT/busybox" >"$OUT/program-headers.txt"
grep -A1 -i 'TLS' "$OUT/program-headers.txt" || true
tls_align=$(awk '/TLS/{print $NF; exit}' "$OUT/program-headers.txt")
[ "$tls_align" = "0x40" ] || die "TLS alignment is $tls_align, expected 0x40 (64)"
applets=$(wc -l <"$OUT/applets.txt")
[ "$applets" -eq 364 ] || die "applet count is $applets, expected 364"

if [ -f "$CI_DIR/busybox-applets.txt" ]; then
    missing=$(comm -23 <(sort -u "$CI_DIR/busybox-applets.txt") \
        <(sort -u "$OUT/applets.txt"))
    [ -z "$missing" ] || die "missing applets: $missing"
fi

echo
echo "BusyBox OK: $OUT/busybox"
echo "size=$(stat -c%s "$OUT/busybox") applets=$applets tls=$tls_align"
