#!/usr/bin/env bash

AMLL_COMPONENT="AMLL"
AMLL_SOURCE_REL="Dependencies/Submodules/AMLLIntegration"
AMLL_SOURCE="$ROOT/$AMLL_SOURCE_REL"
AMLL_PRODUCT="$PRODUCTS_DIR/amll"
AMLL_RUNTIME="$ROOT/kmgccc_player/Resources/AMLL"
AMLL_PNPM_VERSION="11.1.0"
AMLL_NODE_MAJOR="22"
AMLL_RUNTIME_FILES=(amll-core.js amll-lyric.js amll-background.js style.css)

amll_expected_sha() {
  git -C "$ROOT" ls-files -s -- "$AMLL_SOURCE_REL" | /usr/bin/awk '$1 == "160000" {print $2}'
}

amll_stamp_value() {
  printf 'source=%s\ninputs=%s\nnode=%s\npnpm=%s\narch=arm64' \
    "$(amll_expected_sha)" \
    "$(hash_inputs "$AMLL_SOURCE/package.json" "$AMLL_SOURCE/pnpm-lock.yaml" "$ROOT/scripts/sync-amll-from-fork.sh")" \
    "$(node --version 2>/dev/null || true)" \
    "$AMLL_PNPM_VERSION"
}

amll_submodule_ready() {
  local expected actual
  expected="$(amll_expected_sha)"
  actual="$(git -C "$AMLL_SOURCE" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$expected" && "$actual" == "$expected" && -f "$AMLL_SOURCE/package.json" ]]
}

amll_files_ready() {
  local file
  for file in "${AMLL_RUNTIME_FILES[@]}"; do
    [[ -s "$AMLL_PRODUCT/$file" ]] || return 1
    [[ -s "$AMLL_RUNTIME/$file" ]] || return 1
    /usr/bin/cmp -s "$AMLL_PRODUCT/$file" "$AMLL_RUNTIME/$file" || return 1
  done
}

amll_ready() {
  amll_submodule_ready \
    && stamp_matches "$AMLL_PRODUCT" "$(amll_stamp_value)" \
    && amll_files_ready
}

amll_check() {
  amll_submodule_ready \
    || bootstrap_fail "$AMLL_COMPONENT" "Submodule is missing or at the wrong commit." "Run git submodule update --init --recursive"
  amll_ready \
    || bootstrap_fail "$AMLL_COMPONENT" "Generated AMLL product is missing or stale." "Run ./scripts/bootstrap.sh --component amll"
  component_log "$AMLL_COMPONENT" "ready"
}

amll_prepare() {
  local node_major file
  if ! amll_submodule_ready; then
    run_logged "$AMLL_COMPONENT" "submodule initialization" 300 \
      git -C "$ROOT" submodule update --init --recursive -- "$AMLL_SOURCE_REL"
  fi
  amll_submodule_ready \
    || bootstrap_fail "$AMLL_COMPONENT" "Submodule does not match the recorded commit." "Run git submodule status"

  if ((BOOTSTRAP_FORCE == 0)) && amll_ready; then
    component_log "$AMLL_COMPONENT" "cached"
    return 0
  fi

  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  [[ "$node_major" == "$AMLL_NODE_MAJOR" ]] \
    || bootstrap_fail "$AMLL_COMPONENT" "Node.js $AMLL_NODE_MAJOR is required; found $(node --version)." "Install Node.js $AMLL_NODE_MAJOR and rerun ./scripts/bootstrap.sh"

  run_logged "$AMLL_COMPONENT" "dependency install" 1800 \
    /bin/bash -c 'cd "$1" && corepack "pnpm@'$AMLL_PNPM_VERSION'" install --frozen-lockfile' _ "$AMLL_SOURCE"

  rm -rf "$AMLL_PRODUCT"
  mkdir -p "$AMLL_PRODUCT"
  run_logged "$AMLL_COMPONENT" build 1800 \
    /usr/bin/env AMLL_SOURCE="$AMLL_SOURCE" AMLL_OUTPUT_DIR="$AMLL_PRODUCT" \
      "$ROOT/scripts/sync-amll-from-fork.sh"

  for file in "${AMLL_RUNTIME_FILES[@]}"; do
    install_if_changed "$AMLL_PRODUCT/$file" "$AMLL_RUNTIME/$file"
  done
  write_stamp "$AMLL_PRODUCT" "$(amll_stamp_value)"
  amll_ready \
    || bootstrap_fail "$AMLL_COMPONENT" "Generated AMLL files failed validation." "Run ./scripts/bootstrap.sh --force --component amll"
  component_log "$AMLL_COMPONENT" "ready"
}

amll_clean() {
  rm -rf "$AMLL_PRODUCT"
}
