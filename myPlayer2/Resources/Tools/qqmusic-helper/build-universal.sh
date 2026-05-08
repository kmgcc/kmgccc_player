#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build-universal"
ARM_PYTHON="${QQMUSIC_HELPER_ARM_PYTHON:-/opt/homebrew/bin/python3.12}"
X86_PYTHON="${QQMUSIC_HELPER_X86_PYTHON:-/usr/local/bin/python3.11}"
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

merge_universal() {
  local arm_dir="${BUILD_DIR}/dist-arm64/${APP_NAME}"
  local x86_dir="${BUILD_DIR}/dist-x86_64/${APP_NAME}"
  local final_dir="${BUILD_DIR}/universal/${APP_NAME}"

  rm -rf "${BUILD_DIR}/universal"
  mkdir -p "${final_dir}"
  ditto --noextattr --norsrc "${arm_dir}/" "${final_dir}/"

  while IFS= read -r -d '' x86_file; do
    local rel="${x86_file#${x86_dir}/}"
    local arm_file="${arm_dir}/${rel}"
    local final_file="${final_dir}/${rel}"
    mkdir -p "$(dirname "${final_file}")"

    if [[ ! -e "${arm_file}" ]]; then
      ditto --noextattr --norsrc "${x86_file}" "${final_file}"
      continue
    fi

    if [[ -f "${arm_file}" && -f "${x86_file}" ]] && is_macho "${arm_file}" && is_macho "${x86_file}"; then
      lipo -create "${arm_file}" "${x86_file}" -output "${final_file}"
    fi
  done < <(find "${x86_dir}" -type f -print0)

  rm -rf "${FINAL_EXE}" "${FINAL_INTERNAL}" "${SCRIPT_DIR}/_internal"
  ditto --noextattr --norsrc "${final_dir}/${APP_NAME}" "${FINAL_EXE}"
  if [[ -d "${final_dir}/${INTERNAL_DIR_NAME}" ]]; then
    ditto --noextattr --norsrc "${final_dir}/${INTERNAL_DIR_NAME}" "${FINAL_INTERNAL}"
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
  if ! file "${FINAL_EXE}" | grep -q 'x86_64' || ! file "${FINAL_EXE}" | grep -q 'arm64'; then
    echo "error: ${FINAL_EXE} is not universal arm64 + x86_64" >&2
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
require_python x86_64 "${X86_PYTHON}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
install_and_build_arch arm64 "${ARM_PYTHON}"
install_and_build_arch x86_64 "${X86_PYTHON}"
merge_universal
chmod 755 "${FINAL_EXE}"
sign_outputs
smoke_test
if [[ "${KEEP_QQMUSIC_HELPER_BUILD:-0}" != "1" ]]; then
  rm -rf "${BUILD_DIR}"
fi
log "built ${FINAL_EXE}"
