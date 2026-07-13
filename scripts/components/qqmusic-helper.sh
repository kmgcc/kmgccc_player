#!/usr/bin/env bash

QQMUSIC_COMPONENT="QQMusicHelper"
QQMUSIC_SOURCE="$ROOT/Tools/QQMusicHelper"
QQMUSIC_PRODUCT="$PRODUCTS_DIR/qqmusic-helper"
QQMUSIC_BUILD_DIR="$WORK_DIR/qqmusic-helper"
QQMUSIC_API_VERSION="0.5.3"
QQMUSIC_PYINSTALLER_VERSION="6.21.0"

qqmusic_stamp_value() {
  printf 'source=%s\nqqmusic-api-python=%s\npython=%s\npyinstaller=%s\narch=arm64' \
    "$(hash_inputs "$QQMUSIC_SOURCE/main.py" "$QQMUSIC_SOURCE/requirements.txt" "$QQMUSIC_SOURCE/build-universal.sh")" \
    "$QQMUSIC_API_VERSION" \
    "$($PYTHON_BIN --version 2>&1)" \
    "$QQMUSIC_PYINSTALLER_VERSION"
}

qqmusic_ready() {
  [[ -x "$QQMUSIC_PRODUCT/qqmusic-helper" ]] \
    && [[ -d "$QQMUSIC_PRODUCT/_internal.bundle" ]] \
    && is_arm64_macho "$QQMUSIC_PRODUCT/qqmusic-helper" \
    && stamp_matches "$QQMUSIC_PRODUCT" "$(qqmusic_stamp_value)"
}

qqmusic_check() {
  qqmusic_ready \
    || bootstrap_fail "$QQMUSIC_COMPONENT" "Build product is missing or stale." "Run ./scripts/bootstrap.sh --component qqmusic-helper"
  component_log "$QQMUSIC_COMPONENT" "ready"
}

qqmusic_prepare() {
  if ((BOOTSTRAP_FORCE == 0)) && qqmusic_ready; then
    component_log "$QQMUSIC_COMPONENT" "cached"
    return 0
  fi
  [[ -x "$QQMUSIC_SOURCE/build-universal.sh" ]] \
    || bootstrap_fail "$QQMUSIC_COMPONENT" "Build entry is missing." "Expected $QQMUSIC_SOURCE/build-universal.sh"

  run_logged "$QQMUSIC_COMPONENT" build 1800 \
    /usr/bin/env QQMUSIC_HELPER_ARM_PYTHON="$PYTHON_BIN" \
      QQMUSIC_HELPER_BUILD_DIR="$QQMUSIC_BUILD_DIR" \
      QQMUSIC_HELPER_OUTPUT_DIR="$QQMUSIC_PRODUCT" \
      QQMUSIC_HELPER_SKIP_SMOKE_TEST=1 \
      "$QQMUSIC_SOURCE/build-universal.sh"
  write_stamp "$QQMUSIC_PRODUCT" "$(qqmusic_stamp_value)"
  qqmusic_ready \
    || bootstrap_fail "$QQMUSIC_COMPONENT" "ARM64 product failed validation." "Run ./scripts/bootstrap.sh --force --component qqmusic-helper"

  run_logged "$QQMUSIC_COMPONENT" "protocol smoke test" 30 \
    /bin/bash -c 'printf "%s\n" '\''{"id":"bootstrap","method":"unsupported","params":{}}'\'' | "$1" | /usr/bin/grep -q '\''"ok":false'\''' _ "$QQMUSIC_PRODUCT/qqmusic-helper"
  component_log "$QQMUSIC_COMPONENT" "ready"
}

qqmusic_clean() {
  rm -rf "$QQMUSIC_PRODUCT" "$QQMUSIC_BUILD_DIR"
}
