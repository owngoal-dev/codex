#!/usr/bin/env bash
#
# Cross-compile the Cargo product for iOS out of a prepared source tree, verify
# the result is really an iOS binary, and assemble a payload directory.
#
# Prints the payload directory on stdout (the last line). Its contents are
# exactly what lands in <prefix>/usr/libexec/<program>.

set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <src-dir> <scratch-dir>" >&2
    exit 64
fi

src_dir="$1"
scratch_dir="$2"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"

: "${CARGO_DIR:?}"
: "${CARGO_PACKAGE:?}"
: "${CARGO_BIN:?}"
: "${CODE_MODE_HOST_PACKAGE:?}"
: "${CODE_MODE_HOST_BIN:?}"
: "${PROGRAM:?}"
: "${MIN_IOS:?}"
: "${ARCH:?}"
: "${RUST_TOOLCHAIN:?}"

cargo_root="$src_dir/$CARGO_DIR"
[[ -f "$cargo_root/Cargo.toml" ]] || {
    echo "error: $cargo_root is not a prepared Cargo tree (run scripts/prepare-source.sh)" >&2
    exit 66
}

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
[[ -d "$sdk_path" ]] || { echo "error: no iPhoneOS SDK; install Xcode" >&2; exit 69; }

# rustc's apple-ios target is aarch64-apple-ios, not arm64-apple-ios.
case "$ARCH" in
arm64) rust_target="aarch64-apple-ios" ;;
*)     rust_target="$ARCH-apple-ios" ;;
esac

echo "building $CARGO_PACKAGE and $CODE_MODE_HOST_PACKAGE for $rust_target (iOS $MIN_IOS)" >&2
echo "  SDK:       $sdk_path" >&2
echo "  toolchain: $RUST_TOOLCHAIN" >&2

command -v rustup >/dev/null || { echo "error: rustup is not installed" >&2; exit 69; }
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal >&2
rustup target add "$rust_target" --toolchain "$RUST_TOOLCHAIN" >&2
# Homebrew can provide standalone cargo/rustc ahead of rustup's proxies.
# Cargo's child compiler must use the same toolchain that owns the iOS stdlib.
toolchain_rustc="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)"
toolchain_bin="$(dirname "$toolchain_rustc")"
export PATH="$toolchain_bin:$PATH"

export SDKROOT="$sdk_path"
export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS"
unset MACOSX_DEPLOYMENT_TARGET
# Stop pkg-config from feeding macOS .pc files into an iOS link.
export PKG_CONFIG_ALLOW_CROSS=1
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR || true

mkdir -p "$scratch_dir"
cargo_home="$scratch_dir/cargo-home"
mkdir -p "$cargo_home"
export CARGO_HOME="$cargo_home"
export CARGO_TARGET_DIR="$scratch_dir/target"
# rustc embeds source paths (panic locations, debug info) for the checkout and
# every registry crate. Remap them so the binary does not carry the build
# machine's directories. Upstream sets no rustflags for the iOS target, so
# exporting RUSTFLAGS drops nothing.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$src_dir=/src --remap-path-prefix=$scratch_dir=/build"

rusty_v8_root="$scratch_dir/rusty-v8"
"$repository_root/scripts/prepare-rusty-v8.sh" "$rusty_v8_root" >&2

locked_v8_version="$(awk '
    $0 == "name = \"v8\"" { in_v8 = 1; next }
    in_v8 && $1 == "version" { gsub(/\"/, "", $3); print $3; exit }
' "$cargo_root/Cargo.lock")"
source_v8_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$rusty_v8_root/Cargo.toml" | head -n1)"
[[ -n "$locked_v8_version" && "$source_v8_version" == "$locked_v8_version" ]] || {
    echo "error: Cargo.lock needs v8 ${locked_v8_version:-unknown}, but RUSTY_V8_REF provides ${source_v8_version:-unknown}" >&2
    exit 65
}

# Host rustc would happily emit a darwin Mach-O if the target flag is dropped.
# The vtool check below is the backstop; this is the front.
(
    cd "$cargo_root"
    rustup run "$RUST_TOOLCHAIN" cargo build \
        --release \
        --target "$rust_target" \
        --package "$CARGO_PACKAGE" \
        --bin "$CARGO_BIN"
) >&2

libclang_path="${LIBCLANG_PATH:-$(dirname "$(dirname "$(xcrun --find clang)")")/lib}"
[[ -f "$libclang_path/libclang.dylib" ]] || {
    echo "error: bindgen needs libclang 19+; set LIBCLANG_PATH to a directory containing libclang.dylib" >&2
    exit 69
}
v8_patch="patch.crates-io.v8.path=\"$rusty_v8_root\""
lock_file="$cargo_root/Cargo.lock"
lock_backup="$scratch_dir/Cargo.lock.before-code-mode-host"
/usr/bin/ditto "$lock_file" "$lock_backup"
restore_cargo_lock() {
    /usr/bin/ditto "$lock_backup" "$lock_file"
}
trap restore_cargo_lock EXIT
(
    cd "$cargo_root"
    export V8_FROM_SOURCE=1
    export GN_ARGS="ios_deployment_target=\"$MIN_IOS\""
    export LIBCLANG_PATH="$libclang_path"
    unset CLANG_BASE_PATH RUSTY_V8_ARCHIVE RUSTY_V8_MIRROR V8_FORCE_DEBUG
    rustup run "$RUST_TOOLCHAIN" cargo build \
        --release \
        --target "$rust_target" \
        --package "$CODE_MODE_HOST_PACKAGE" \
        --bin "$CODE_MODE_HOST_BIN" \
        --config "$v8_patch"
) >&2
restore_cargo_lock
trap - EXIT

binary_names=("$CARGO_BIN" "$CODE_MODE_HOST_BIN")
for binary_name in "${binary_names[@]}"; do
    executable="$CARGO_TARGET_DIR/$rust_target/release/$binary_name"
    [[ -f "$executable" ]] || { echo "error: build produced no $executable" >&2; exit 65; }

    build_version="$(vtool -show-build "$executable" 2>/dev/null)"
    grep -qE '^ *platform (IOS|2)$' <<<"$build_version" || {
        echo "error: $executable is not an iOS binary:" >&2
        sed 's/^/       /' <<<"$build_version" >&2
        exit 65
    }

    architectures="$(lipo -archs "$executable")"
    [[ "$architectures" == "$ARCH" ]] || {
        echo "error: expected a $ARCH binary, got '$architectures'" >&2
        exit 65
    }

    while read -r dependency; do
        case "$dependency" in
        @*) ;;
        /usr/lib/* | /System/Library/Frameworks/*) ;;
        *)
            echo "error: $executable depends on a path iOS does not provide: $dependency" >&2
            exit 65
            ;;
        esac
    done < <(otool -L "$executable" | tail -n +2 | awk '{print $1}')
done

payload="$scratch_dir/payload"
rm -rf -- "$payload"
mkdir -p "$payload"
for binary_name in "${binary_names[@]}"; do
    executable="$CARGO_TARGET_DIR/$rust_target/release/$binary_name"
    /usr/bin/ditto "$executable" "$payload/$binary_name"

    # Upstream release profile leaves symbols in the binary on purpose. Strip
    # the payload copy, not cargo's target dir, so the cached artifact remains
    # useful for symbolication. package-deb.sh re-signs after stripping.
    xcrun --sdk iphoneos strip -xS "$payload/$binary_name"

    build_version="$(vtool -show-build "$payload/$binary_name" 2>/dev/null)"
    grep -qE '^ *platform (IOS|2)$' <<<"$build_version" || {
        echo "error: stripped $payload/$binary_name is no longer an iOS binary" >&2
        sed 's/^/       /' <<<"$build_version" >&2
        exit 65
    }
done

{
    for binary_name in "${binary_names[@]}"; do
        echo "built $binary_name: $ARCH, iOS $MIN_IOS minimum, $(
            du -h "$payload/$binary_name" | cut -f1 | tr -d ' '
        )"
    done
    echo "payload ($(du -sh "$payload" | cut -f1 | tr -d ' ') total):"
    (cd "$payload" && find . -maxdepth 1 -mindepth 1 | sed 's|^\./|  |')
    echo "system dependencies:"
    for binary_name in "${binary_names[@]}"; do
        echo "  $binary_name:"
        otool -L "$payload/$binary_name" | tail -n +2 | awk '{print "    " $1}'
    done
} >&2

printf '%s\n' "$payload"
