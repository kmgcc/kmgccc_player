#!/usr/bin/env bash

LDDC_COMPONENT="LDDC"
LDDC_SOURCE="$ROOT/Dependencies/Sources/LDDCFetchCore"
LDDC_PRODUCT="$PRODUCTS_DIR/lddc"
LDDC_BUILD_DIR="$WORK_DIR/lddc"
LDDC_PYINSTALLER_VERSION="6.21.0"

lddc_stamp_value() {
  printf 'source=%s\npython=%s\npyinstaller=%s\narch=arm64' \
    "$(hash_inputs "$LDDC_SOURCE/src" "$LDDC_SOURCE/pyproject.toml" "$LDDC_SOURCE/lddc_server_entry.py" "$LDDC_SOURCE/build_pyinstaller.sh")" \
    "$($PYTHON_BIN --version 2>&1)" \
    "$LDDC_PYINSTALLER_VERSION"
}

lddc_ready() {
  [[ -x "$LDDC_PRODUCT/lddc-server" ]] \
    && [[ -d "$LDDC_PRODUCT/_internal" ]] \
    && is_arm64_macho "$LDDC_PRODUCT/lddc-server" \
    && stamp_matches "$LDDC_PRODUCT" "$(lddc_stamp_value)"
}

lddc_check() {
  lddc_ready \
    || bootstrap_fail "$LDDC_COMPONENT" "Build product is missing or stale." "Run ./scripts/bootstrap.sh --component lddc"
  component_log "$LDDC_COMPONENT" "ready"
}

lddc_prepare() {
  if ((BOOTSTRAP_FORCE == 0)) && lddc_ready; then
    component_log "$LDDC_COMPONENT" "cached"
    return 0
  fi
  [[ -x "$LDDC_SOURCE/build_pyinstaller.sh" ]] \
    || bootstrap_fail "$LDDC_COMPONENT" "Build entry is missing." "Expected $LDDC_SOURCE/build_pyinstaller.sh"

  run_logged "$LDDC_COMPONENT" build 1800 \
    /usr/bin/env LDDC_ARM_PYTHON="$PYTHON_BIN" \
      LDDC_BUILD_DIR="$LDDC_BUILD_DIR" \
      LDDC_OUTPUT_DIR="$LDDC_PRODUCT" \
      "$LDDC_SOURCE/build_pyinstaller.sh"
  write_stamp "$LDDC_PRODUCT" "$(lddc_stamp_value)"
  lddc_ready \
    || bootstrap_fail "$LDDC_COMPONENT" "ARM64 product failed validation." "Run ./scripts/bootstrap.sh --force --component lddc"
  component_log "$LDDC_COMPONENT" "ready"
}

lddc_clean() {
  rm -rf "$LDDC_PRODUCT" "$LDDC_BUILD_DIR"
}
