#!/usr/bin/env bash
# Strict release gate for a clean public clone.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

has_selected_ref=0
for argument in "$@"; do
  if [[ "$argument" == "--ref" ]]; then
    has_selected_ref=1
  fi
done

if ((has_selected_ref)); then
  exec "$script_dir/audit_public_release.sh" --reflogs "$@"
fi

exec "$script_dir/audit_public_release.sh" --all-refs --reflogs "$@"
