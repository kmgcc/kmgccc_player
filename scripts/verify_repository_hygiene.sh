#!/usr/bin/env bash
# Strict repository hygiene verification across all refs.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

has_selected_ref=0
for argument in "$@"; do
  if [[ "$argument" == "--ref" ]]; then
    has_selected_ref=1
  fi
done

if ((has_selected_ref)); then
  "$script_dir/verify_textual_hygiene.sh" || exit $?
  exec "$script_dir/audit_release_contents.sh" --reflogs "$@"
fi

"$script_dir/verify_textual_hygiene.sh" || exit $?
exec "$script_dir/audit_release_contents.sh" --all-refs --reflogs "$@"
