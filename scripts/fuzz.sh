#!/usr/bin/env bash
#
# Fuzzes the lunasvg this repository packages, as ADR 066 in limn-toolkit asks of each version:
# damaged copies of the seeds in src/test/fuzz/seeds, each opened, changed and drawn in a child
# process. Fails on any crash or any case that runs past its time.
#
# Run after scripts/build-lunasvg.sh, which leaves the release objects this links against: the
# same flags, NDEBUG included, that went into the shipped library, without the JNI shim.
#
#   ./scripts/fuzz.sh                 # 6,000 cases, seed 1, 5 seconds a case
#   ./scripts/fuzz.sh 20000 7 5       # cases, seed, seconds
#
# POSIX only (fork, alarm): it runs on the macOS and Linux slices, which share every line of
# lunasvg's code with the Windows ones.

set -euo pipefail
export LC_ALL=C

CASES="${1:-6000}"
SEED="${2:-1}"
SECONDS_PER_CASE="${3:-5}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x86_64" ;;
    *) echo "unknown machine $(uname -m)" >&2; exit 2 ;;
esac
OBJ="${REPO_ROOT}/native/build/${ARCH}/obj"
SRC="$(ls -d "${REPO_ROOT}"/native/src/lunasvg-*/ 2>/dev/null | head -1)"
if [ ! -d "${OBJ}" ] || [ -z "${SRC}" ]; then
    echo "no release objects for ${ARCH}: run scripts/build-lunasvg.sh first" >&2
    exit 2
fi

CXX_BIN="${CXX:-}"
if [ -z "${CXX_BIN}" ]; then
    for candidate in clang++ c++ g++; do
        if command -v "${candidate}" >/dev/null 2>&1; then CXX_BIN="${candidate}"; break; fi
    done
fi

OUT="${REPO_ROOT}/native/fuzz"
mkdir -p "${OUT}"
LIBS=()
if [ "$(uname -s)" = "Linux" ]; then LIBS=(-lm -lpthread); fi
OBJECTS=()
for o in "${OBJ}"/*.o; do
    case "$(basename "$o")" in limn_svg.cpp.o) continue ;; esac
    OBJECTS+=("$o")
done
"${CXX_BIN}" -std=gnu++17 -O2 -DNDEBUG -DLUNASVG_BUILD_STATIC -DPLUTOVG_BUILD_STATIC \
    -I"${SRC}/include" "${REPO_ROOT}/src/test/fuzz/fuzz.cpp" "${OBJECTS[@]}" \
    ${LIBS[@]+"${LIBS[@]}"} -o "${OUT}/fuzz"

cd "${OUT}"
echo "fuzzing lunasvg ($(basename "${SRC}")) on ${ARCH}: ${CASES} cases, seed ${SEED}, ${SECONDS_PER_CASE} s a case"
"${OUT}/fuzz" "${CASES}" "${SEED}" "${SECONDS_PER_CASE}" "${REPO_ROOT}"/src/test/fuzz/seeds/*.svg
