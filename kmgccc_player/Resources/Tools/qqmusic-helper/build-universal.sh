#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build-arm64"
ARM_PYTHON="${QQMUSIC_HELPER_ARM_PYTHON:-/opt/homebrew/bin/python3.12}"
APP_NAME="qqmusic-helper"
INTERNAL_DIR_NAME="_internal.bundle"
FINAL_EXE="${SCRIPT_DIR}/${APP_NAME}"
FINAL_INTERNAL="${SCRIPT_DIR}/${INTERNAL_DIR_NAME}"

log() {
  printf '[QQMusicHelperBuild] %s\n' "$*"
}

require_python() {
  local arch="$1"
  local python_bin="$2"
  if [[ ! -x "${python_bin}" ]]; then
    echo "error: ${arch} Python not executable: ${python_bin}" >&2
    exit 1
  fi
  arch "-${arch}" "${python_bin}" - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

install_and_build_arch() {
  local arch_name="$1"
  local python_bin="$2"
  local venv_dir="${BUILD_DIR}/venv-${arch_name}"
  local dist_root="${BUILD_DIR}/dist-${arch_name}"
  local work_root="${BUILD_DIR}/work-${arch_name}"

  log "building ${arch_name} with ${python_bin}"
  rm -rf "${venv_dir}" "${dist_root}" "${work_root}"
  arch "-${arch_name}" "${python_bin}" -m venv "${venv_dir}"
  arch "-${arch_name}" "${venv_dir}/bin/python" -m pip install --upgrade pip
  arch "-${arch_name}" "${venv_dir}/bin/python" -m pip install -r "${SCRIPT_DIR}/requirements.txt" pyinstaller
  arch "-${arch_name}" "${venv_dir}/bin/python" -m PyInstaller \
    --noconfirm \
    --clean \
    --onedir \
    --contents-directory "${INTERNAL_DIR_NAME}" \
    --name "${APP_NAME}" \
    --distpath "${dist_root}" \
    --workpath "${work_root}" \
    --specpath "${BUILD_DIR}" \
    --collect-all qqmusic_api \
    --collect-all tarsio \
    --collect-all pydantic \
    --collect-all httpx \
    --collect-all httpcore \
    --hidden-import qqmusic_api.core.client \
    --hidden-import qqmusic_api.modules.search \
    --hidden-import qqmusic_api.models.search \
    "${SCRIPT_DIR}/main.py"
}

is_macho() {
  file "$1" | grep -q 'Mach-O'
}

install_arm64_output() {
  local arm_dir="${BUILD_DIR}/dist-arm64/${APP_NAME}"

  rm -rf "${FINAL_EXE}" "${FINAL_INTERNAL}" "${SCRIPT_DIR}/_internal"
  find "${SCRIPT_DIR}" -maxdepth 1 -type d -name '_internal *.bundle' -exec rm -rf {} +
  find "${SCRIPT_DIR}" -maxdepth 1 -type f -name 'qqmusic-helper [0-9]*' -exec rm -f {} +
  ditto --noextattr --norsrc "${arm_dir}/${APP_NAME}" "${FINAL_EXE}"
  if [[ -d "${arm_dir}/${INTERNAL_DIR_NAME}" ]]; then
    ditto --noextattr --norsrc "${arm_dir}/${INTERNAL_DIR_NAME}" "${FINAL_INTERNAL}"
  fi
}

sign_outputs() {
  xattr -dr com.apple.quarantine "${FINAL_EXE}" "${FINAL_INTERNAL}" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "${FINAL_EXE}" "${FINAL_INTERNAL}" 2>/dev/null || true
  xattr -dr com.apple.fileprovider.fpfs#P "${FINAL_EXE}" "${FINAL_INTERNAL}" 2>/dev/null || true
  xattr -dr com.apple.provenance "${FINAL_EXE}" "${FINAL_INTERNAL}" 2>/dev/null || true
  xattr -cr "${FINAL_EXE}" "${FINAL_INTERNAL}" 2>/dev/null || true

  while IFS= read -r -d '' item; do
    if is_macho "${item}"; then
      codesign --force --sign - "${item}" >/dev/null
    fi
  done < <(find "${FINAL_EXE}" "${FINAL_INTERNAL}" -type f -print0 2>/dev/null)

  codesign --force --deep --sign - "${FINAL_EXE}" >/dev/null
}

smoke_test() {
  log "$(file "${FINAL_EXE}")"
  if ! lipo -info "${FINAL_EXE}" 2>/dev/null | grep -q 'arm64'; then
    echo "error: ${FINAL_EXE} is not arm64" >&2
    exit 1
  fi
  if lipo -info "${FINAL_EXE}" 2>/dev/null | grep -q 'x86_64'; then
    echo "error: ${FINAL_EXE} still contains x86_64" >&2
    exit 1
  fi

  log "smoke testing ${FINAL_EXE}"
  local response
  response="$(printf '%s\n' '{"id":"smoke-track","method":"search_track_artwork","params":{"title":"七里香","artist":"周杰伦","album":"七里香","duration":299,"limit":2}}' | "${FINAL_EXE}")"
  printf '%s\n' "${response}"
  if ! printf '%s' "${response}" | grep -q '"ok":true'; then
    echo "error: smoke test failed" >&2
    exit 1
  fi
}

require_python arm64 "${ARM_PYTHON}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
install_and_build_arch arm64 "${ARM_PYTHON}"
install_arm64_output
chmod 755 "${FINAL_EXE}"
sign_outputs
smoke_test
if [[ "${KEEP_QQMUSIC_HELPER_BUILD:-0}" != "1" ]]; then
  rm -rf "${BUILD_DIR}"
fi
log "built ${FINAL_EXE}"
