#!/bin/bash
# Starts a new recovery case: copies cases/_template/ to cases/<case-id>/ (move.sh,
# signatures.json, README.md) and tells you what to fill in next.
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
echo "  1. Fill in cases/${case_id}/move.sh (the simulated recovery): it moves your locked funds"
echo "     into the bridge (bridgeAsset / bridgeMessage)."
echo "  2. Run ./submission/prepare-submission.sh cases/${case_id} — it writes"
echo "     cases/${case_id}/recovery.json from the BridgeEvents of move.sh. Check it."
echo "  3. Once recovery.json and move.sh are FINAL, fill in cases/${case_id}/signatures.json: one"
echo "     signature, made with ownership-proof/sign-message.sh (same NONCE for all), for every EOA"
echo "     that move.sh impersonates. The signed message includes a hash of recovery.json and"
echo "     move.sh: if either changes later, sign everything again."
echo "  4. Run ./submission/prepare-submission.sh cases/${case_id} again — it checks everything and"
echo "     builds the .tgz. Full walkthrough: cases/${case_id}/README.md."
