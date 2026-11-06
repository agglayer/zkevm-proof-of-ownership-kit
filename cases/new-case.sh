#!/bin/bash
# Starts a new recovery case: copies cases/_template/ to cases/<case-id>/ (move.sh,
# recovery.json, signatures.json, README.md) and tells you what to fill in next.
#
# <case-id> is anything easy to reference back to your support conversation (a Slack
# thread id, your project name...): letters, digits, '.', '_' and '-'.
#
# Usage (from the repo root):
#   cases/new-case.sh <case-id>
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <case-id>" >&2
    exit 1
fi
case_id="$1"

if ! [[ "${case_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: invalid case id '${case_id}' — use letters, digits, '.', '_' and '-', starting with a letter or digit." >&2
    exit 1
fi

case_dir="${script_dir}/${case_id}"
if [ -e "${case_dir}" ]; then
    echo "Error: ${case_dir} already exists — pick another case id, or remove it first." >&2
    exit 1
fi

cp -R "${script_dir}/_template" "${case_dir}"

echo "Created cases/${case_id}/. Next:"
echo "  1. Fill in cases/${case_id}/recovery.json — which funds you want to recover from"
echo "     which locked contract, and to which final wallet — and check it with:"
echo "       ./recovery-tx/validate-recovery.sh cases/${case_id}/recovery.json"
echo "  2. Fill in cases/${case_id}/move.sh (the simulated recovery)."
echo "  3. Fill in cases/${case_id}/signatures.json: one signature, made with"
echo "     ownership-proof/sign-message.sh (same NONCE for all), for every EOA that move.sh"
echo "     impersonates and for your destination wallet."
echo "  4. Run ./submission/prepare-submission.sh cases/${case_id} — it checks everything and"
echo "     builds the .tgz. Full walkthrough: cases/${case_id}/README.md."
