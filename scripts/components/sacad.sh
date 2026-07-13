#!/usr/bin/env bash

SACAD_COMPONENT="SACAD"
SACAD_VERSION="3.0.1"
SACAD_ARCHIVE_SHA256="6d0fe6e1f3e494be88a7a3fcf6ae88c998c3c70194d2b4b3749c7fc150c162f7"
SACAD_URL="https://github.com/desbma/sacad/releases/download/$SACAD_VERSION/sacad_${SACAD_VERSION}_macos_aarch64.tar.gz"
SACAD_ARCHIVE="$DOWNLOADS_DIR/sacad/sacad_${SACAD_VERSION}_macos_aarch64.tar.gz"
SACAD_PRODUCT="$PRODUCTS_DIR/sacad"

sacad_stamp_value() {
  printf 'version=%s\narchive=%s\narch=arm64' "$SACAD_VERSION" "$SACAD_ARCHIVE_SHA256"
}

sacad_ready() {
  [[ -x "$SACAD_PRODUCT/sacad" ]] \
    && is_arm64_macho "$SACAD_PRODUCT/sacad" \
    && stamp_matches "$SACAD_PRODUCT" "$(sacad_stamp_value)"
}

sacad_check() {
  sacad_ready \
    || bootstrap_fail "$SACAD_COMPONENT" "Build product is missing or stale." "Run ./scripts/bootstrap.sh --component sacad"
  component_log "$SACAD_COMPONENT" "ready"
}

sacad_prepare() {
  local staging
  if ((BOOTSTRAP_FORCE == 0)) && sacad_ready; then
    component_log "$SACAD_COMPONENT" "cached"
    return 0
  fi

  download_checked "$SACAD_COMPONENT" "$SACAD_URL" "$SACAD_ARCHIVE_SHA256" "$SACAD_ARCHIVE"
  staging="$WORK_DIR/sacad/product.$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  /usr/bin/tar -xzf "$SACAD_ARCHIVE" -C "$staging" sacad
  chmod 755 "$staging/sacad"
  write_stamp "$staging" "$(sacad_stamp_value)"
  rm -rf "$SACAD_PRODUCT"
  mkdir -p "$(dirname "$SACAD_PRODUCT")"
  mv "$staging" "$SACAD_PRODUCT"
  sacad_ready \
    || bootstrap_fail "$SACAD_COMPONENT" "ARM64 product failed validation." "Run ./scripts/bootstrap.sh --force --component sacad"
  component_log "$SACAD_COMPONENT" "ready"
}

sacad_clean() {
  rm -rf "$SACAD_PRODUCT"
}
