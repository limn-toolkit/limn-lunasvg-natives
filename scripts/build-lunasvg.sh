#!/usr/bin/env bash
#
# Builds the SVG renderer the Limn toolkit loads: lunasvg and plutovg, compiled from a pinned
# source into ONE shared library per platform together with the JNI shim in src/main/cpp, called
# liblimnsvg. This repository IS that payload (ADR 066 in limn-toolkit), versioned after lunasvg.
#
# NOTHING THIS PRODUCES IS COMMITTED. The whole native/ tree is gitignored: a binary in a source
# repository is a binary nobody can review, and the published jars are the only place the library
# is meant to exist. A release builds its own on six machines (.github/workflows/natives.yml);
# this script is how a developer gets one locally.
#
#   ./scripts/build-lunasvg.sh                     # this JVM's architecture (macOS: both)
#   ./scripts/build-lunasvg.sh --arch arm64,x86_64 # macOS universal
#   ./scripts/build-lunasvg.sh --clean             # discard the source and every output
#
# ONE LIBRARY, NOT THREE. lunasvg and plutovg are static libraries here, linked into the shim, so
# a platform's payload is one file the loader extracts and loads, with no load order to keep and
# no second file to be missing. Only the shim's JNI entry points are exported; everything of
# lunasvg's is hidden and the linker drops what the shim never calls.
#
# BUILT FOR RELEASE: NDEBUG, always. lunasvg asserts on what a damaged file says, and an
# assertion is an abort: built with them, 5 of 6,000 damaged copies stopped the process; built
# without, none did (ADR 066 §2).
#
# FONTS. lunasvg looks up the system's installed fonts for SVG text, as the toolkit's owner chose
# (ADR 066 §3): LUNASVG_DISABLE_LOAD_SYSTEM_FONTS is deliberately NOT defined. The toolkit also
# registers the fonts it bundles through the shim's addFont.
#
# PATCHED, ONCE. The archive is verified and then patches/*.patch are applied to it: one today, a
# budget of splits for each curve plutovg flattens, without which a curve far from the origin
# never ended (the patch's header says how the fuzz found it). Every other line is upstream's.
#
# LICENCE. lunasvg and plutovg are MIT; their notices travel in every jar (stage_licence below).
# The shim is Limn's own, Apache 2.0.

set -euo pipefail
export LC_ALL=C

# ---------------------------------------------------------------------------- the pin

LUNASVG_VERSION="3.5.0"

# The tag's archive from GitHub, checked on every fetch so every machine builds the same bytes.
# lunasvg publishes no checksum and no binary; this sum was taken from the archive fetched on
# 2026-10-14, whose sources were the ones measured for ADR 066. Move the pin the same way: fetch,
# read the diff since the last tag, copy the sum.
LUNASVG_SHA256="1abf1472ee6c4d19797916e8cc3c2e4b628e0d81178ffac60bdb0d457e32c690"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_ROOT}/native"
SRC_DIR="${WORK_DIR}/src/lunasvg-${LUNASVG_VERSION}"
SHIM_SRC="${REPO_ROOT}/src/main/cpp/limn_svg.cpp"

ARCHS=""
CLEAN=0
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)  ARCHS="$2"; shift 2 ;;
        --jobs)  JOBS="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$CLEAN" = "1" ]; then
    echo "removing ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
    exit 0
fi

# ---------------------------------------------------------------------------- platform

HOST_OS="$(uname -s)"
case "${HOST_OS}" in
    Darwin) LIMN_OS="macos";   LIB_EXT="dylib" ;;
    Linux)  LIMN_OS="linux";   LIB_EXT="so" ;;
    MINGW*|MSYS*|CLANGARM64*|CLANG64*|CYGWIN*|UCRT*)
            LIMN_OS="windows"; LIB_EXT="dll" ;;
    *) echo "unsupported host '${HOST_OS}': this builds on macOS, Linux, and Windows under MSYS2" >&2
       exit 2 ;;
esac

CC_BIN="${CC:-}"
CXX_BIN="${CXX:-}"
if [ -z "${CC_BIN}" ]; then
    for candidate in clang cc gcc; do
        if command -v "${candidate}" >/dev/null 2>&1; then CC_BIN="${candidate}"; break; fi
    done
fi
if [ -z "${CXX_BIN}" ]; then
    for candidate in clang++ c++ g++; do
        if command -v "${candidate}" >/dev/null 2>&1; then CXX_BIN="${candidate}"; break; fi
    done
fi
if [ -z "${CC_BIN}" ] || [ -z "${CXX_BIN}" ]; then
    echo "no C and C++ compiler on PATH (looked for clang, cc, gcc and their C++ twins); set CC and CXX" >&2
    exit 2
fi

# Java's spelling of the architecture wins, because the loader names directories from os.arch.
arch_label() {
    case "$1" in
        arm64|aarch64) echo "aarch64" ;;
        x86_64|amd64)  echo "x86_64" ;;
        *) echo "$1" ;;
    esac
}

# macOS builds both slices and joins them, because the JVM that loads the library may be either
# architecture on the same Mac (an x86_64 JDK under Rosetta beside an arm64 one is ordinary).
if [ -z "${ARCHS}" ]; then
    if [ "${LIMN_OS}" = "macos" ]; then
        ARCHS="arm64,x86_64"
        echo "targeting a universal build (arm64 + x86_64): any JDK on this Mac can load it"
    else
        JAVA_BIN="java"
        if [ -n "${JAVA_HOME:-}" ]; then JAVA_BIN="${JAVA_HOME}/bin/java"; fi
        command -v "${JAVA_BIN}" >/dev/null 2>&1 || JAVA_BIN="java"
        if ! command -v "${JAVA_BIN}" >/dev/null 2>&1; then
            echo "no JVM on PATH and no JAVA_HOME: this builds a JNI shim, so it needs a JDK" >&2
            exit 2
        fi
        JVM_ARCH="$("${JAVA_BIN}" -XshowSettings:properties -version 2>&1 \
            | sed -n 's/.*os\.arch = \(.*\)/\1/p' | tr -d ' ')"
        case "${JVM_ARCH}" in
            x86_64|amd64) ARCHS="x86_64" ;;
            aarch64|arm64) ARCHS="arm64" ;;
            *) echo "cannot map JVM os.arch='${JVM_ARCH}' to a build architecture" >&2; exit 2 ;;
        esac
        echo "targeting ${ARCHS} (the JVM at ${JAVA_BIN} reports os.arch=${JVM_ARCH})"
    fi
fi

if [ -z "${JAVA_HOME:-}" ]; then
    if [ "${LIMN_OS}" = "macos" ]; then
        JAVA_HOME="$(/usr/libexec/java_home -v 17+ 2>/dev/null || /usr/libexec/java_home)"
    else
        JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    fi
elif [ "${LIMN_OS}" = "windows" ]; then
    JAVA_HOME="$(cygpath -u "${JAVA_HOME}" 2>/dev/null || echo "${JAVA_HOME}")"
fi
if [ ! -f "${JAVA_HOME}/include/jni.h" ]; then
    echo "no jni.h under JAVA_HOME=${JAVA_HOME}; a JDK is needed, not a JRE" >&2
    exit 2
fi
case "${LIMN_OS}" in
    macos)   JNI_MD_DIR="${JAVA_HOME}/include/darwin" ;;
    windows) JNI_MD_DIR="${JAVA_HOME}/include/win32" ;;
    *)       JNI_MD_DIR="${JAVA_HOME}/include/linux" ;;
esac

# ---------------------------------------------------------------------------- the source

mkdir -p "${WORK_DIR}/src"
TARBALL="${WORK_DIR}/src/lunasvg-${LUNASVG_VERSION}.tar.gz"

# THE PATCHES in patches/, applied in name order to the verified archive, each saying in its header
# what it fixes and how it was found. The source tree records which it was built with, and a tree
# extracted before a patch was added, or with another, is extracted again: a build never mixes.
PATCH_DIR="${REPO_ROOT}/patches"
PATCHES=()
for p in "${PATCH_DIR}"/*.patch; do
    [ -f "$p" ] && PATCHES+=("$p")
done
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1; else sha256sum | cut -d' ' -f1; fi
}
PATCH_STAMP="$(cat ${PATCHES[@]+"${PATCHES[@]}"} /dev/null | sha256_of)"
PATCH_MARKER="${SRC_DIR}/.limn-patches"
if [ -d "${SRC_DIR}" ] && [ "$(cat "${PATCH_MARKER}" 2>/dev/null)" != "${PATCH_STAMP}" ]; then
    echo "the source tree was not built with the patches of patches/; extracting it again"
    rm -rf "${SRC_DIR}"
fi

if [ ! -d "${SRC_DIR}" ]; then
    if [ ! -f "${TARBALL}" ]; then
        echo "fetching lunasvg ${LUNASVG_VERSION}"
        curl -fsSL --retry 3 -o "${TARBALL}.part" \
            "https://github.com/sammycage/lunasvg/archive/refs/tags/v${LUNASVG_VERSION}.tar.gz"
        mv "${TARBALL}.part" "${TARBALL}"
    fi
    echo "verifying the pin"
    if command -v shasum >/dev/null 2>&1; then
        ACTUAL="$(shasum -a 256 "${TARBALL}" | cut -d' ' -f1)"
    else
        ACTUAL="$(sha256sum "${TARBALL}" | cut -d' ' -f1)"
    fi
    if [ "${ACTUAL}" != "${LUNASVG_SHA256}" ]; then
        echo "checksum mismatch for ${TARBALL}" >&2
        echo "  expected ${LUNASVG_SHA256}" >&2
        echo "  actual   ${ACTUAL}" >&2
        echo "Refusing to build. Delete the file to re-fetch, or update the pin deliberately." >&2
        exit 1
    fi
    tar -xzf "${TARBALL}" -C "${WORK_DIR}/src"
    for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
        echo "applying $(basename "$p")"
        patch -d "${SRC_DIR}" -p1 --forward --batch --quiet < "$p"
    done
    echo "${PATCH_STAMP}" > "${PATCH_MARKER}"
fi

# The header's version must be the pin's: a tarball that says one version and holds another is
# the mistake the pin exists to catch, and the shim reports the header's.
HEADER_VERSION="$(sed -En 's/^#define LUNASVG_VERSION_(MAJOR|MINOR|MICRO) ([0-9]+)$/\2/p' \
    "${SRC_DIR}/include/lunasvg.h" | paste -sd. -)"
if [ "${HEADER_VERSION}" != "${LUNASVG_VERSION}" ]; then
    echo "lunasvg.h says ${HEADER_VERSION}, the pin says ${LUNASVG_VERSION}; refusing to build" >&2
    exit 1
fi

# ---------------------------------------------------------------------------- build, per arch

BUILD_DIR="${WORK_DIR}/build"

# plutovg's font cache is locked only where C11 <threads.h> exists or on Windows; the shim locks
# every call anyway, so this only spares plutovg's own lock where it has one to take. (The
# ${array[@]+"${array[@]}"} spelling below is how an EMPTY array expands under set -u in the bash
# 3.2 that macOS ships, which calls a plain "${array[@]}" of one unbound.)
HAVE_THREADS=()
if [ "${LIMN_OS}" = "linux" ] && printf '#include <threads.h>\nint main(void){return 0;}\n' \
        | "${CC_BIN}" -std=c11 -x c - -o /dev/null >/dev/null 2>&1; then
    HAVE_THREADS=(-DHAVE_THREADS_H)
fi

build_one_arch() {
    local arch="$1"
    local obj="${BUILD_DIR}/${arch}/obj"
    local out="${BUILD_DIR}/${arch}/liblimnsvg.${LIB_EXT}"
    rm -rf "${BUILD_DIR}/${arch}"; mkdir -p "${obj}"
    echo "building liblimnsvg for ${LIMN_OS}-$(arch_label "${arch}")"

    local common=(-O2 -DNDEBUG -fvisibility=hidden -ffunction-sections -fdata-sections
        -DPLUTOVG_BUILD -DPLUTOVG_BUILD_STATIC -DLUNASVG_BUILD -DLUNASVG_BUILD_STATIC
        -I"${SRC_DIR}/include" -I"${SRC_DIR}/source" -I"${SRC_DIR}/plutovg/include")
    if [ "${LIMN_OS}" != "windows" ]; then common=(-fPIC "${common[@]}"); fi
    if [ "${LIMN_OS}" = "macos" ]; then common=(-arch "${arch}" -mmacosx-version-min=11.0 "${common[@]}"); fi

    # gnu11 and gnu++17, not the strict dialects: lunasvg's own CMake build asks for C11 and C++17
    # with CMake's default of extensions ON, and plutovg reaches PATH_MAX, which glibc declares only
    # outside strict C. The flags follow the build the upstream source is tested with.
    # The objects are compiled in parallel, a job per file, and the build waits for all of them.
    local pids=() f
    for f in "${SRC_DIR}"/plutovg/source/*.c; do
        "${CC_BIN}" -std=gnu11 "${common[@]}" ${HAVE_THREADS[@]+"${HAVE_THREADS[@]}"} -c "$f" -o "${obj}/$(basename "$f").o" &
        pids+=($!)
        if [ "${#pids[@]}" -ge "${JOBS}" ]; then wait "${pids[0]}"; pids=("${pids[@]:1}"); fi
    done
    for f in "${SRC_DIR}"/source/*.cpp "${SHIM_SRC}"; do
        "${CXX_BIN}" -std=gnu++17 -fvisibility-inlines-hidden "${common[@]}" \
            -I"${JAVA_HOME}/include" -I"${JNI_MD_DIR}" -c "$f" -o "${obj}/$(basename "$f").o" &
        pids+=($!)
        if [ "${#pids[@]}" -ge "${JOBS}" ]; then wait "${pids[0]}"; pids=("${pids[@]:1}"); fi
    done
    local failed=0 p
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || failed=1; done
    if [ "${failed}" = "1" ]; then echo "a source file did not compile" >&2; exit 1; fi

    local link=()
    case "${LIMN_OS}" in
        macos)
            link=(-arch "${arch}" -mmacosx-version-min=11.0 -dynamiclib
                -install_name "@rpath/liblimnsvg.dylib" -Wl,-dead_strip) ;;
        linux)
            # The C++ runtime goes inside: a libstdc++ newer than the machine's is the Linux twin
            # of a DLL that is not there, and it fails the same silent way at load.
            link=(-shared -static-libstdc++ -static-libgcc -Wl,--gc-sections -Wl,--exclude-libs,ALL
                -Wl,-z,defs -lm -lpthread) ;;
        windows)
            # Everything static, the C++ runtime included, so the DLL imports Windows and nothing
            # else; verify_windows_payload refuses it otherwise.
            link=(-shared -static -Wl,--gc-sections) ;;
    esac
    "${CXX_BIN}" "${obj}"/*.o -o "${out}" "${link[@]}"
    if [ "${LIMN_OS}" = "macos" ]; then
        strip -x "${out}"
    else
        strip --strip-unneeded "${out}" 2>/dev/null || strip "${out}"
    fi
    ls -l "${out}" | awk -v a="${arch}" '{ printf "  liblimnsvg (%s) %8.0f KB\n", a, $5/1024 }'
}

IFS=',' read -r -a ARCH_LIST <<< "${ARCHS}"
for arch in "${ARCH_LIST[@]}"; do
    build_one_arch "${arch}"
done

# ---------------------------------------------------------------------------- stage the result
#
# The loader looks for limn/svg/native/<os>-<arch>/liblimnsvg.<ext> on the classpath, and the
# Gradle build adds native/dist as a resource root when it exists.

DIST="${WORK_DIR}/dist/limn/svg/native"
mkdir -p "${DIST}"

LINUX_GLIBC_FLOOR="2.28"

# Refuses a Linux library that needs a glibc newer than the floor: it would load on the machine
# that built it and on newer ones only, and nothing about the build would say so. Build in an image
# whose glibc is old enough (the manylinux_2_28 images exist for this) rather than raise the number.
verify_linux_payload() {
    local lib="$1" required
    if ! command -v objdump >/dev/null 2>&1; then
        echo "  WARNING: objdump not found, so the glibc floor was NOT verified" >&2
        return 0
    fi
    required="$(objdump -T "${lib}" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' \
                    | sort -V | tail -1)"
    if [ -n "${required}" ] && [ "$(printf '%s\n%s\n' "${LINUX_GLIBC_FLOOR}" "${required}" | sort -V | tail -1)" \
            != "${LINUX_GLIBC_FLOOR}" ]; then
        echo "  TOO NEW: liblimnsvg needs glibc ${required}, above the ${LINUX_GLIBC_FLOOR} this payload promises" >&2
        echo "  Build in quay.io/pypa/manylinux_2_28_\$(uname -m) (with a JDK for jni.h)." >&2
        exit 1
    fi
    if objdump -p "${lib}" 2>/dev/null | grep -q 'NEEDED.*libstdc++'; then
        echo "  liblimnsvg links libstdc++ dynamically; it must carry its own (-static-libstdc++)" >&2
        exit 1
    fi
    echo "  verified: nothing needs a glibc newer than ${LINUX_GLIBC_FLOOR}, and no libstdc++ is imported"
}

# Refuses a DLL that imports something Windows does not provide: there is no rpath on Windows, and
# a missing dependency fails LoadLibrary with "Can't find dependent libraries" on every machine but
# the one that built it.
verify_windows_payload() {
    local dll="$1" dep lower missing=0
    if ! command -v objdump >/dev/null 2>&1; then
        echo "  WARNING: objdump not found, so the imports were NOT verified" >&2
        return 0
    fi
    while read -r dep; do
        [ -n "${dep}" ] || continue
        lower="$(printf '%s' "${dep}" | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in
            api-ms-win-*|kernel32.dll|kernelbase.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll \
            |advapi32.dll|user32.dll|gdi32.dll|ole32.dll|shell32.dll) continue ;;
        esac
        echo "  MISSING DEPENDENCY: liblimnsvg.dll imports ${dep}, which Windows does not provide" >&2
        missing=1
    done < <(objdump -p "${dll}" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p')
    if [ "${missing}" = "1" ]; then
        echo "  Build under CLANG64 (x86_64) or CLANGARM64 (arm64), linking statically." >&2
        exit 1
    fi
    echo "  verified: every import is Windows' own"
}

stage() {
    local platform="$1" lib="$2"
    local out="${DIST}/${platform}"
    rm -rf "${out}"; mkdir -p "${out}"
    cp "${lib}" "${out}/liblimnsvg.${LIB_EXT}"
    case "${LIMN_OS}" in
        linux)   verify_linux_payload "${out}/liblimnsvg.${LIB_EXT}" ;;
        windows) verify_windows_payload "${out}/liblimnsvg.${LIB_EXT}" ;;
    esac
}

if [ "${LIMN_OS}" = "macos" ] && [ "${#ARCH_LIST[@]}" -gt 1 ]; then
    # One universal file staged under BOTH directories: the loader picks by os.arch, and either
    # JVM finds its slice inside.
    UNIVERSAL="${BUILD_DIR}/liblimnsvg.dylib"
    lipo -create $(for a in "${ARCH_LIST[@]}"; do printf '%s ' "${BUILD_DIR}/${a}/liblimnsvg.dylib"; done) \
        -output "${UNIVERSAL}"
    for a in "${ARCH_LIST[@]}"; do
        # Each platform's jar carries only its own slice: half the bytes, and nothing a reader of
        # the jar has to explain.
        stage "macos-$(arch_label "$a")" "${BUILD_DIR}/${a}/liblimnsvg.dylib"
    done
    rm -f "${UNIVERSAL}"
else
    for a in "${ARCH_LIST[@]}"; do
        stage "${LIMN_OS}-$(arch_label "$a")" "${BUILD_DIR}/${a}/liblimnsvg.${LIB_EXT}"
    done
fi

stage_licence() {
    cp "${SRC_DIR}/LICENSE" "${DIST}/LICENSE-lunasvg.txt"
    cp "${SRC_DIR}/plutovg/LICENSE" "${DIST}/LICENSE-plutovg.txt"
    cat > "${DIST}/NOTICE-lunasvg.txt" <<NOTICE
This artifact contains lunasvg ${LUNASVG_VERSION} and the plutovg it carries, compiled from the
upstream source archive https://github.com/sammycage/lunasvg/archive/refs/tags/v${LUNASVG_VERSION}.tar.gz
(SHA-256 ${LUNASVG_SHA256}) into liblimnsvg together with Limn's JNI shim. One change was made to
plutovg: a budget of splits for each curve it flattens, so that a curve far from the origin is
drawn rather than flattened without end. The change is the file patches/plutovg-flatten-split-budget.patch
of https://github.com/limn-toolkit/limn-lunasvg-natives, at the tag of this version.

lunasvg is Copyright (c) Samuel Ugochukwu and is licensed under the MIT License; see
LICENSE-lunasvg.txt. plutovg is Copyright (c) Samuel Ugochukwu and is licensed under the MIT
License; see LICENSE-plutovg.txt. The shim is part of the Limn toolkit and is licensed under the
Apache License, Version 2.0.
NOTICE
}
stage_licence

# ---------------------------------------------------------------------------- report

echo "staged under ${DIST}:"
find "${DIST}" -type f | sed "s|${WORK_DIR}/dist/||" | sort | while read -r f; do
    size="$(stat -f%z "${WORK_DIR}/dist/$f" 2>/dev/null || stat -c%s "${WORK_DIR}/dist/$f")"
    printf "  %-48s %8.0f KB\n" "$f" "$(awk -v s="$size" 'BEGIN { print s / 1024 }')"
done
