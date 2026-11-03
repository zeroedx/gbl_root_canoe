#!/bin/bash
set -e

# ══════════════════════════════════════
# 配置
# ══════════════════════════════════════
NDK=$NDK_PATH
API=31
TRIPLE="aarch64-linux-android"
SRC="tools/extractfv.c"
OUT_DIR="dist"
XZ_VER="5.4.5"
XZ_URL="https://tukaani.org/xz/xz-${XZ_VER}.tar.gz"
XZ_SRC="third_party/xz"
LZMA_BUILD="build/lzma-aarch64"
LZMA_INSTALL="build/lzma-install-aarch64"

cd "$(dirname "$0")"/../

# ══════════════════════════════════════
# 检查 NDK
# ══════════════════════════════════════
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ ! -d "$TOOLCHAIN" ] && TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"

if [ ! -d "$TOOLCHAIN" ]; then
    echo "Error: NDK toolchain not found."
    echo "Set NDK_PATH to your NDK path."
    exit 1
fi

CC="${TOOLCHAIN}/bin/${TRIPLE}${API}-clang"

if [ ! -f "$CC" ]; then
    echo "Error: Compiler not found: $CC"
    exit 1
fi

echo "NDK Compiler: $CC"

# ══════════════════════════════════════
# Step 1: 下载 xz 源码
# ══════════════════════════════════════
if [ ! -d "$XZ_SRC" ]; then
    echo "[1/3] Downloading xz-${XZ_VER}..."
    mkdir -p third_party
    curl -sL "$XZ_URL" | tar xz -C third_party
    mv "third_party/xz-${XZ_VER}" "$XZ_SRC"
else
    echo "[1/3] xz source already exists, skipping download"
fi

# ══════════════════════════════════════
# Step 2: 交叉编译 liblzma 静态库
# ══════════════════════════════════════
if [ -f "${LZMA_INSTALL}/lib/liblzma.a" ]; then
    echo "[2/3] liblzma already built, skipping"
else
    echo "[2/3] Building liblzma for arm64..."
    mkdir -p "$LZMA_BUILD" "$LZMA_INSTALL"

    LZMA_INSTALL_ABS="$(cd "$LZMA_INSTALL" && pwd)"
    XZ_SRC_ABS="$(cd "$XZ_SRC" && pwd)"

    cd "$LZMA_BUILD"

    "${XZ_SRC_ABS}/configure" \
        --host="${TRIPLE}" \
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
        CC="$CC" \
        CFLAGS="-O2 -fPIC"

    make -j$(nproc)
    make install

    cd ../..
    echo "[2/3] liblzma built -> ${LZMA_INSTALL}/lib/liblzma.a"
fi

# ══════════════════════════════════════
# Step 3: 编译 extractfv
# ══════════════════════════════════════
echo "[3/4] Compiling extractfv for arm64-v8a..."

mkdir -p "$OUT_DIR"

$CC -O2 -std=c11 \
    -Wall -Wextra -Wno-unused-parameter \
    -D__ANDROID__ \
    -I"${LZMA_INSTALL}/include" \
    -o "${OUT_DIR}/extractfv_android" \
    "$SRC" \
    -L"${LZMA_INSTALL}/lib" \
    -llzma \
    -static

# ══════════════════════════════════════
# Step 4: 移除不参与装载的 DWARF
# ══════════════════════════════════════
# NDK 的静态 libc.a 自带大量调试信息，链接后约占九成体积，而它永远不参与装载。
# 只删 .debug_*，保留 .symtab。
echo "[4/4] Stripping DWARF from extractfv..."

STRIP="${TOOLCHAIN}/bin/llvm-strip"
if [ ! -x "$STRIP" ]; then
    echo "Error: llvm-strip not found: $STRIP"
    exit 1
fi

if [ -x "${TOOLCHAIN}/bin/llvm-readelf" ]; then
    READELF="${TOOLCHAIN}/bin/llvm-readelf"
elif command -v llvm-readelf > /dev/null 2>&1; then
    READELF=$(command -v llvm-readelf)
else
    echo "Error: llvm-readelf is required to verify the stripped binary"
    exit 1
fi
if ! command -v cmp > /dev/null 2>&1; then
    echo "Error: cmp is required to compare the PT_LOAD segments"
    exit 1
fi

UNSTRIPPED="${OUT_DIR}/extractfv_android.unstripped"
cp "${OUT_DIR}/extractfv_android" "$UNSTRIPPED"

"$STRIP" --strip-debug "${OUT_DIR}/extractfv_android" || {
    echo "Error: llvm-strip failed, refusing to package the unstripped binary"
    exit 1
}

# strip 只能动不装载的内容：
#   - ELF 头（除 section 表指针外）必须一致
#   - PT_LOAD 的数量、偏移、地址、大小、权限必须一致
#   - 每个 PT_LOAD 段内的字节必须一致
elf_header() {
    "$READELF" -h "$1" |
        grep -vE "Start of section headers|Number of section headers|Section header string table index"
}
loads() { "$READELF" -l -W "$1" | awk '$1 == "LOAD"'; }

if [ "$(elf_header "$UNSTRIPPED")" != "$(elf_header "${OUT_DIR}/extractfv_android")" ]; then
    echo "Error: strip changed the ELF header"
    exit 1
fi
if [ "$(loads "$UNSTRIPPED")" != "$(loads "${OUT_DIR}/extractfv_android")" ]; then
    echo "Error: strip changed the PT_LOAD layout"
    diff <(loads "$UNSTRIPPED") <(loads "${OUT_DIR}/extractfv_android") || true
    exit 1
fi
loads "$UNSTRIPPED" | while read -r _ off _ _ filesz _; do
    skip=$((off))
    count=$((filesz))
    if [ "$skip" -eq 0 ]; then
        # 第一个段以 ELF 头开始，其 section 表指针在 strip 后必然改变，跳过头部。
        skip=64
        count=$((count - 64))
    fi
    cmp -s -i "${skip}:${skip}" -n "$count" \
        "$UNSTRIPPED" "${OUT_DIR}/extractfv_android" || exit 1
done || {
    echo "Error: strip changed the bytes inside a PT_LOAD segment"
    exit 1
}

if "$READELF" -S -W "${OUT_DIR}/extractfv_android" | grep -q '\.debug_'; then
    echo "Error: extractfv_android still contains .debug_* sections"
    "$READELF" -S -W "${OUT_DIR}/extractfv_android" | grep '\.debug_'
    exit 1
fi
if ! "$READELF" -S -W "${OUT_DIR}/extractfv_android" | grep -q '\.symtab'; then
    echo "Error: .symtab is missing, only --strip-debug is allowed"
    exit 1
fi

echo "      size: $(wc -c < "$UNSTRIPPED" | tr -d ' ') -> $(wc -c < "${OUT_DIR}/extractfv_android" | tr -d ' ') bytes"
echo "      no .debug_* sections left, .symtab kept, PT_LOAD unchanged"
rm -f "$UNSTRIPPED"

#clean third party
rm -rf ./third_party
rm -rf ./build
# ══════════════════════════════════════
# 验证
# ══════════════════════════════════════
echo ""
echo "========================================="
echo " Build successful!"
echo "========================================="
file "${OUT_DIR}/extractfv_android"
ls -lh "${OUT_DIR}/extractfv_android"
echo ""
echo "Usage:"
echo "  adb push ${OUT_DIR}/extractfv_android /data/local/tmp/"
echo "  adb shell chmod +x /data/local/tmp/extractfv_android"
echo "  adb shell /data/local/tmp/extractfv -v input.elf"