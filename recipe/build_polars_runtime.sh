#!/usr/bin/env bash

set -euxo pipefail

cd $PKG_NAME

# Remove this wrapper once https://github.com/conda-forge/rust-activation-feedstock/pull/79 is merged
mkdir -p ${BUILD_PREFIX}/bin
cp ${RECIPE_DIR}/cargo-auditable-wrapper.sh ${BUILD_PREFIX}/bin/cargo-auditable-wrapper
export CARGO="cargo-auditable-wrapper"
export CARGO_PROFILE_RELEASE_STRIP=none
export CARGO_PROFILE_RELEASE_DEBUG=full

# see https://github.com/pola-rs/polars/blob/main/.github/workflows/release-python.yml
COMPAT_TUNE_CPU=''
COMPAT_FEATURES='+sse3,+ssse3,+sse4.1,+sse4.2,+popcnt,+cmpxchg16b'
COMPAT_CC_FEATURES='-msse3 -mssse3 -msse4.1 -msse4.2 -mpopcnt -mcx16'

NONCOMPAT_TUNE_CPU='skylake'
NONCOMPAT_FEATURES='+sse3,+ssse3,+sse4.1,+sse4.2,+popcnt,+cmpxchg16b,+avx,+avx2,+fma,+bmi1,+bmi2,+lzcnt,+pclmulqdq,+movbe'
NONCOMPAT_CC_FEATURES='-msse3 -mssse3 -msse4.1 -msse4.2 -mpopcnt -mcx16 -mavx -mavx2 -mfma -mbmi -mbmi2 -mlzcnt -mpclmul -mmovbe'


case "${target_platform}" in
  linux-aarch64|osx-arm64)
    arch="aarch64"
    ;;
  *)
    arch="x86_64"
    ;;
esac

if [[ $arch == "x86_64" ]]; then
  if [[ $PKG_NAME == "polars-runtime-compat" ]]; then
    TUNE_CPU="$COMPAT_TUNE_CPU"
    FEATURES="$COMPAT_FEATURES"
    CC_FEATURES="$COMPAT_CC_FEATURES"
  else
    TUNE_CPU="$NONCOMPAT_TUNE_CPU"
    FEATURES="$NONCOMPAT_FEATURES"
    CC_FEATURES="$NONCOMPAT_CC_FEATURES"
  fi

  if [[ $PKG_NAME == polars-runtime-compat ]]; then
    CFG='--cfg allocator="default"'
  fi

  if [[ -z "${TUNE_CPU:-}" ]]; then
    export RUSTFLAGS="-C target-feature=$FEATURES ${CFG:-}"
    export CFLAGS="$CFLAGS $CC_FEATURES"
  else
    export RUSTFLAGS="-C target-feature=$FEATURES -Z tune-cpu=$TUNE_CPU ${CFG:-}"
    export CFLAGS="$CFLAGS $CC_FEATURES -mtune=$TUNE_CPU"
  fi
fi



if [[ $target_platform == "linux-aarch64" ]]; then
  export JEMALLOC_SYS_WITH_LG_PAGE=16
fi

$PYTHON -m pip install . -vv

runtime_variant="${PKG_NAME#polars-runtime-}"
ext_path="${SP_DIR}/_polars_runtime_${runtime_variant}/_polars_runtime.abi3.so"

if [[ "${target_platform}" == linux-* ]]; then
  objcopy_bin="${OBJCOPY:-${HOST}-objcopy}"
  command -v "${objcopy_bin}" >/dev/null 2>&1 || objcopy_bin="objcopy"
  if [[ ! -f "${ext_path}" ]]; then
    echo "could not find built _polars_runtime shared object at ${ext_path}" >&2
    exit 1
  fi
  command -v "${objcopy_bin}" >/dev/null 2>&1 || {
    echo "objcopy not found for split debug packaging" >&2
    exit 1
  }
  rel_ext_path="${ext_path#${PREFIX}/}"
  debug_file="${PREFIX}/lib/debug/${rel_ext_path}.debug"
  mkdir -p "$(dirname "${debug_file}")"
  "${objcopy_bin}" --only-keep-debug "${ext_path}" "${debug_file}"
  chmod 664 "${debug_file}"
  "${objcopy_bin}" --strip-debug "${ext_path}"
  "${objcopy_bin}" --add-gnu-debuglink="${debug_file}" "${ext_path}"
elif [[ "${target_platform}" == osx-* ]]; then
  debug_dir="${PREFIX}/share/${PKG_NAME}/debug"
  mkdir -p "${debug_dir}"
  echo "Debug artifacts for ${PKG_NAME}" > "${debug_dir}/README.txt"
  if [[ ! -f "${ext_path}" ]]; then
    echo "could not find built _polars_runtime shared object at ${ext_path}" >&2
    exit 1
  fi
  command -v dsymutil >/dev/null 2>&1 || {
    echo "dsymutil not found for split debug packaging" >&2
    exit 1
  }
  dsymutil "${ext_path}" -o "${debug_dir}/$(basename "${ext_path}").dSYM"
  strip -x "${ext_path}"
fi

# The root level Cargo.toml is part of an incomplete workspace
# we need to use the manifest inside the py-polars
cd py-polars/runtime
cargo-bundle-licenses --format yaml --output ../../THIRDPARTY.yml
