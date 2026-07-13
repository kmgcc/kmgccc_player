#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_MODE="prepare"
BOOTSTRAP_FORCE=0
SELECTED_COMPONENT=""

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap.sh [--check] [--force] [--component NAME]

Components: amll, lddc, qqmusic-helper, mediaremote, sacad
  --check           Validate products without downloading or building.
  --force           Rebuild selected generated products.
  --component NAME  Prepare or check only one component.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      BOOTSTRAP_MODE="check"
      ;;
    --force)
      BOOTSTRAP_FORCE=1
      ;;
    --component)
      [[ $# -ge 2 ]] || { echo "error: --component requires a name" >&2; exit 2; }
      SELECTED_COMPONENT="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$SELECTED_COMPONENT" in
  ""|amll|lddc|qqmusic-helper|mediaremote|sacad) ;;
  *)
    echo "error: unknown component: $SELECTED_COMPONENT" >&2
    usage >&2
    exit 2
    ;;
esac

export BOOTSTRAP_MODE BOOTSTRAP_FORCE
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
trap bootstrap_cleanup EXIT
trap 'bootstrap_cleanup; exit 130' INT TERM

PYTHON_BIN="${KMGCCC_ARM_PYTHON:-${LDDC_ARM_PYTHON:-${QQMUSIC_HELPER_ARM_PYTHON:-$(command -v python3.12 || true)}}}"
export PYTHON_BIN

component_selected() {
  [[ -z "$SELECTED_COMPONENT" || "$SELECTED_COMPONENT" == "$1" ]]
}

check_environment() {
  [[ "$(uname -s)" == "Darwin" ]] \
    || bootstrap_fail Environment "bootstrap requires macOS."
  [[ "$(uname -m)" == "arm64" ]] \
    || bootstrap_fail Environment "bootstrap requires an ARM64 Mac."
  require_command shasum "Install the Xcode command line tools."
  require_command lipo "Install Xcode 26 or newer."

  if component_selected amll; then
    require_command git "Install the Xcode command line tools."
    require_command node "Install Node.js 22."
    require_command corepack "Install Node.js 22 with Corepack."
  fi
  if component_selected lddc || component_selected qqmusic-helper; then
    [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] \
      || bootstrap_fail Environment "ARM64 Python 3.12 is unavailable." "Install Python 3.12 or set KMGCCC_ARM_PYTHON."
    [[ "$(arch -arm64 "$PYTHON_BIN" -c 'import platform; print(platform.machine())')" == "arm64" ]] \
      || bootstrap_fail Environment "Python must run as arm64: $PYTHON_BIN" "Set KMGCCC_ARM_PYTHON to an ARM64 Python 3.12 executable."
    [[ "$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" == "3.12" ]] \
      || bootstrap_fail Environment "Python 3.12 is required: $PYTHON_BIN"
  fi
  if component_selected mediaremote; then
    require_command cmake "Install CMake 3.15 or newer."
    require_command xcodebuild "Install Xcode 26 or newer."
    require_command patch "Install the Xcode command line tools."
  fi
  if [[ "$BOOTSTRAP_MODE" == "prepare" ]] \
    && { component_selected mediaremote || component_selected sacad; }; then
    require_command curl "Install curl."
  fi
  component_log Environment "ready"
}

# shellcheck source=scripts/components/amll.sh
source "$ROOT/scripts/components/amll.sh"
# shellcheck source=scripts/components/lddc.sh
source "$ROOT/scripts/components/lddc.sh"
# shellcheck source=scripts/components/qqmusic-helper.sh
source "$ROOT/scripts/components/qqmusic-helper.sh"
# shellcheck source=scripts/components/mediaremote.sh
source "$ROOT/scripts/components/mediaremote.sh"
# shellcheck source=scripts/components/sacad.sh
source "$ROOT/scripts/components/sacad.sh"

run_component() {
  local name="$1"
  local function_prefix="$2"
  component_selected "$name" || return 0
  if [[ "$BOOTSTRAP_MODE" == "check" ]]; then
    "${function_prefix}_check"
  else
    "${function_prefix}_prepare"
  fi
}

check_environment
run_component amll amll
run_component lddc lddc
run_component qqmusic-helper qqmusic
run_component mediaremote mediaremote
run_component sacad sacad

if [[ "$BOOTSTRAP_MODE" == "check" ]]; then
  printf '\nDependency check complete.\n'
else
  printf '\nBootstrap complete. Products: %s\n' "$PRODUCTS_DIR"
fi
