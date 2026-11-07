#!/bin/sh

set -eu

worker_configuration="${CONFIGURATION:-Debug}"
worker_derived_data="$DERIVED_FILE_DIR/OhiaWorkerXcodeBuild"
worker_products="$worker_derived_data/Build/Products/$worker_configuration"
services_root="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices"
sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
current_arch="${CURRENT_ARCH:-}"

# Release builds are distributed and notarized, which requires a secure
# timestamp on every signature; Debug builds sign offline.
timestamp_flag="--timestamp=none"
if [ "$worker_configuration" = "Release" ]; then
    timestamp_flag="--timestamp"
fi

if [ -z "$current_arch" ] || [ "$current_arch" = "undefined_arch" ]; then
    current_arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"
fi

required_resource_bundles="
OhiaPackages_OhiaML.bundle
ZIPFoundation_ZIPFoundation.bundle
mlx-swift_Cmlx.bundle
swift-nio_NIOPosix.bundle
swift-transformers_Hub.bundle
"

/bin/mkdir -p "$worker_products"
"${CC:-/usr/bin/clang}" \
    -arch "$current_arch" \
    -isysroot "$SDKROOT" \
    -x c \
    -c /dev/null \
    -o "$worker_products/CNumKong.o"

/bin/rm -f \
    "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/OhiaMessagesReader" \
    "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/OhiaRetrievalWorker" \
    "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/OhiaGenerativeWorker"

build_service() {
    product="$1"
    plist="$2"
    entitlements="$3"
    includes_package_resources="$4"
    bundle="$services_root/$product.xpc"
    contents="$bundle/Contents"
    executable_dir="$contents/MacOS"

    # MLX's Swift/C++ dispatch is on the token-by-token inference path. Keep
    # Debug diagnostics enabled, but optimize the generative worker and its
    # dependencies even when the development app uses a Debug configuration.
    # The other helpers retain their requested configuration unchanged.
    if [ "$product" = "OhiaGenerativeWorker" ]; then
        set -- SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=3
    else
        set --
    fi

    /usr/bin/env -i \
        HOME="$HOME" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        TMPDIR="${TMPDIR:-/tmp}" \
        DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        /usr/bin/xcodebuild \
        -project "$SRCROOT/Ohia.xcodeproj" \
        -scheme "$product" \
        -configuration "$worker_configuration" \
        -destination "platform=macOS,arch=$current_arch" \
        -derivedDataPath "$worker_derived_data" \
        -skipPackageUpdates \
        -onlyUsePackageVersionsFromResolvedFile \
        COMPILER_INDEX_STORE_ENABLE=NO \
        "$@" \
        build

    worker="$worker_products/$product"
    if [ ! -x "$worker" ]; then
        echo "error: missing worker executable at $worker" >&2
        exit 1
    fi

    /bin/rm -rf "$bundle"
    /bin/mkdir -p "$executable_dir"
    /bin/cp -f "$plist" "$contents/Info.plist"
    # Workers carry the app's version, whose single source is the Ohia
    # target's MARKETING_VERSION and CURRENT_PROJECT_VERSION build settings.
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
        -c "Set :CFBundleVersion $CURRENT_PROJECT_VERSION" \
        "$contents/Info.plist"
    /bin/cp -f "$worker" "$executable_dir/$product"
    /bin/chmod 755 "$executable_dir/$product"

    if [ "$includes_package_resources" = "1" ]; then
        /bin/mkdir -p "$contents/Resources"
        for resource_name in $required_resource_bundles; do
            resource_bundle="$worker_products/$resource_name"
            if [ ! -d "$resource_bundle" ]; then
                echo "error: missing worker resource bundle at $resource_bundle" >&2
                exit 1
            fi
            /usr/bin/ditto "$resource_bundle" "$contents/Resources/$resource_name"
        done
    fi

    /usr/bin/codesign \
        --force \
        --sign "$sign_identity" \
        --options runtime \
        --entitlements "$entitlements" \
        "$timestamp_flag" \
        "$bundle"
}

build_service \
    OhiaMessagesReader \
    "$SRCROOT/Packages/XPCServices/OhiaMessagesReader-Info.plist" \
    "$SRCROOT/Ohia/OhiaMessagesReader.entitlements" \
    0
build_service \
    OhiaRetrievalWorker \
    "$SRCROOT/Packages/XPCServices/OhiaRetrievalWorker-Info.plist" \
    "$SRCROOT/Ohia/OhiaRetrievalWorker.entitlements" \
    1
build_service \
    OhiaGenerativeWorker \
    "$SRCROOT/Packages/XPCServices/OhiaGenerativeWorker-Info.plist" \
    "$SRCROOT/Ohia/OhiaGenerativeWorker.entitlements" \
    1
