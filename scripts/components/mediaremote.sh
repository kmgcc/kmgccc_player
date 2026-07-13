#!/usr/bin/env bash

MEDIAREMOTE_COMPONENT="MediaRemote"
MEDIAREMOTE_COMMIT="3ac3d4bdf862c7b5399b4fba4df5689f5c38609a"
MEDIAREMOTE_ARCHIVE_SHA256="111e285e7a8acfb05b7339883e303a360f8a7a9b7acb4f0f5c01b647deb8ceb5"
MEDIAREMOTE_URL="https://codeload.github.com/ungive/mediaremote-adapter/tar.gz/$MEDIAREMOTE_COMMIT"
MEDIAREMOTE_ARCHIVE="$DOWNLOADS_DIR/mediaremote/$MEDIAREMOTE_COMMIT.tar.gz"
MEDIAREMOTE_SOURCE="$SOURCES_DIR/mediaremote/$MEDIAREMOTE_COMMIT"
MEDIAREMOTE_BUILD="$WORK_DIR/mediaremote/$MEDIAREMOTE_COMMIT"
MEDIAREMOTE_PRODUCT="$PRODUCTS_DIR/mediaremote"
MEDIAREMOTE_PATCH="$ROOT/Tools/MediaRemoteAdapter/unbuffered-output.patch"

mediaremote_stamp_value() {
  printf 'source=%s\narchive=%s\npatch=%s\ncmake=%s\nxcode=%s\narch=arm64' \
    "$MEDIAREMOTE_COMMIT" \
    "$MEDIAREMOTE_ARCHIVE_SHA256" \
    "$(sha256_file "$MEDIAREMOTE_PATCH")" \
    "$(cmake --version | /usr/bin/head -1)" \
    "$(xcodebuild -version | /usr/bin/tr '\n' ' ')"
}

mediaremote_ready() {
  local framework="$MEDIAREMOTE_PRODUCT/build/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
  local client="$MEDIAREMOTE_PRODUCT/build/MediaRemoteAdapterTestClient"
  [[ -f "$MEDIAREMOTE_PRODUCT/bin/mediaremote-adapter.pl" ]] \
    && [[ -f "$MEDIAREMOTE_PRODUCT/LICENSE" ]] \
    && is_arm64_macho "$framework" \
    && [[ -x "$client" ]] \
    && is_arm64_macho "$client" \
    && stamp_matches "$MEDIAREMOTE_PRODUCT" "$(mediaremote_stamp_value)"
}

mediaremote_check() {
  mediaremote_ready \
    || bootstrap_fail "$MEDIAREMOTE_COMPONENT" "Build product is missing or stale." "Run ./scripts/bootstrap.sh --component mediaremote"
  component_log "$MEDIAREMOTE_COMPONENT" "ready"
}

mediaremote_prepare() {
  local staging
  if ((BOOTSTRAP_FORCE == 0)) && mediaremote_ready; then
    component_log "$MEDIAREMOTE_COMPONENT" "cached"
    return 0
  fi

  download_checked "$MEDIAREMOTE_COMPONENT" "$MEDIAREMOTE_URL" "$MEDIAREMOTE_ARCHIVE_SHA256" "$MEDIAREMOTE_ARCHIVE"
  rm -rf "$MEDIAREMOTE_SOURCE" "$MEDIAREMOTE_BUILD"
  mkdir -p "$MEDIAREMOTE_SOURCE" "$MEDIAREMOTE_BUILD"
  /usr/bin/tar -xzf "$MEDIAREMOTE_ARCHIVE" -C "$MEDIAREMOTE_SOURCE" --strip-components=1
  run_logged "$MEDIAREMOTE_COMPONENT" "apply integration patch" 60 \
    /bin/bash -c 'cd "$1" && /usr/bin/patch -p1 < "$2"' _ "$MEDIAREMOTE_SOURCE" "$MEDIAREMOTE_PATCH"
  run_logged "$MEDIAREMOTE_COMPONENT" configure 180 \
    cmake -G Xcode -S "$MEDIAREMOTE_SOURCE" -B "$MEDIAREMOTE_BUILD"
  run_logged "$MEDIAREMOTE_COMPONENT" build 900 \
    xcodebuild -quiet \
      -project "$MEDIAREMOTE_BUILD/MediaRemoteAdapter.xcodeproj" \
      -configuration Release \
      -target MediaRemoteAdapter \
      -target MediaRemoteAdapterTestClient \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

  staging="$WORK_DIR/mediaremote/product.$$"
  rm -rf "$staging"
  mkdir -p "$staging/bin" "$staging/build"
  COPYFILE_DISABLE=1 /usr/bin/ditto \
    "$MEDIAREMOTE_BUILD/Release/MediaRemoteAdapter.framework" \
    "$staging/build/MediaRemoteAdapter.framework"
  COPYFILE_DISABLE=1 /bin/cp -f \
    "$MEDIAREMOTE_BUILD/Release/MediaRemoteAdapterTestClient" \
    "$staging/build/MediaRemoteAdapterTestClient"
  COPYFILE_DISABLE=1 /bin/cp -f "$MEDIAREMOTE_SOURCE/bin/mediaremote-adapter.pl" "$staging/bin/mediaremote-adapter.pl"
  COPYFILE_DISABLE=1 /bin/cp -f "$MEDIAREMOTE_SOURCE/LICENSE" "$staging/LICENSE"
  chmod 755 "$staging/bin/mediaremote-adapter.pl" "$staging/build/MediaRemoteAdapterTestClient"
  write_stamp "$staging" "$(mediaremote_stamp_value)"
  rm -rf "$MEDIAREMOTE_PRODUCT"
  mv "$staging" "$MEDIAREMOTE_PRODUCT"

  mediaremote_ready \
    || bootstrap_fail "$MEDIAREMOTE_COMPONENT" "ARM64 product failed validation." "Run ./scripts/bootstrap.sh --force --component mediaremote"
  component_log "$MEDIAREMOTE_COMPONENT" "ready"
}

mediaremote_clean() {
  rm -rf "$MEDIAREMOTE_PRODUCT" "$MEDIAREMOTE_SOURCE" "$MEDIAREMOTE_BUILD"
}
