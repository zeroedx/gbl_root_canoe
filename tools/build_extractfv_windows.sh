#!/bin/bash
# Cross-build extractfv.exe for Windows (x86_64) with mingw-w64.
#
# extractfv needs liblzma, so the xz source is cross-compiled statically first;
# the resulting .exe has no runtime dependency beyond the Windows CRT it is
# linked against. Output: dist/extractfv.exe
set -e

ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$ROOT"

MINGW_PREFIX="${MINGW_PREFIX:-x86_64-w64-mingw32-}"
CC="${MINGW_PREFIX}gcc"
XZ_VER="5.4.5"
XZ_URL="https://tukaani.org/xz/xz-${XZ_VER}.tar.gz"
XZ_SRC="third_party/xz"
LZMA_BUILD="build/lzma-mingw"
LZMA_INSTALL="build/lzma-install-mingw"
OUT_DIR="dist"

command -v "$CC" >/dev/null 2>&1 || {
    echo "Error: $CC not found, install mingw-w64."
    exit 1
}

# ── Step 1: xz source ──
if [ ! -d "$XZ_SRC" ]; then
    echo "[1/4] Downloading xz-${XZ_VER}..."
    mkdir -p third_party
    curl -sL "$XZ_URL" | tar xz -C third_party
    mv "third_party/xz-${XZ_VER}" "$XZ_SRC"
else
    echo "[1/4] xz source already present, skipping download"
fi

# ── Step 2: cross-compile liblzma ──
if [ -f "${LZMA_INSTALL}/lib/liblzma.a" ]; then
    echo "[2/4] liblzma already built, skipping"
else
    echo "[2/4] Building liblzma for Windows..."
    mkdir -p "$LZMA_BUILD" "$LZMA_INSTALL"
    LZMA_INSTALL_ABS="$(cd "$LZMA_INSTALL" && pwd)"
    XZ_SRC_ABS="$(cd "$XZ_SRC" && pwd)"

    (
        cd "$LZMA_BUILD"
        "${XZ_SRC_ABS}/configure" \
            --host="${MINGW_PREFIX%?}" \
            --prefix="${LZMA_INSTALL_ABS}" \
            --enable-static \
            --disable-shared \
            --disable-xz \
            --disable-xzdec \
            --disable-lzmadec \
            --disable-lzmainfo \
            --disable-scripts \
            --disable-doc \
            --disable-nls \
            --disable-threads \
            CC="$CC" \
            CFLAGS="-O2"
        make -j"$(nproc)"
        make install
    )
    echo "[2/4] liblzma built -> ${LZMA_INSTALL}/lib/liblzma.a"
fi

# ── Step 3: compile extractfv.exe ──
echo "[3/4] Compiling extractfv.exe..."
mkdir -p "$OUT_DIR"
"$CC" -O2 -std=c11 \
    -Wall -Wextra -Wno-unused-parameter \
    -I"${LZMA_INSTALL}/include" \
    -o "${OUT_DIR}/extractfv.exe" \
    tools/extractfv.c \
    -L"${LZMA_INSTALL}/lib" \
    -llzma \
    -static

# ── Step 4: verify the result is a real Windows PE binary ──
echo "[4/4] Verifying extractfv.exe..."
[ -s "${OUT_DIR}/extractfv.exe" ] || { echo "Error: extractfv.exe was not produced"; exit 1; }

python3 - "${OUT_DIR}/extractfv.exe" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
if d[:2] != b'MZ':
    sys.exit("Error: extractfv.exe is not a PE image")
off = struct.unpack_from('<I', d, 0x3c)[0]
if d[off:off+4] != b'PE\0\0':
    sys.exit("Error: extractfv.exe has no PE signature")
machine = struct.unpack_from('<H', d, off + 4)[0]
if machine != 0x8664:
    sys.exit(f"Error: extractfv.exe machine is {machine:#x}, expected 0x8664 (x86_64)")
PY

echo "      size: $(wc -c < "${OUT_DIR}/extractfv.exe" | tr -d ' ') bytes"

# xz is only needed to produce the static library; leave no source tree behind.
rm -rf ./third_party ./build

echo ""
echo "========================================="
echo " Build successful: ${OUT_DIR}/extractfv.exe"
echo "========================================="
