#!/bin/bash
# Packs a directory written by helpers/generate.sh (manifest.json, recovery.json, move.sh,
# signatures.json, fork.log, run.log[, etherscan-links.txt]) into
# <output-dir>/<case-id>-<UTC timestamp>.tgz, with everything under a <case-id>/ folder, and
# prints the path of the .tgz on stdout. Called by submission/prepare-submission.sh.
#
# Requires: tar.
#
# Usage: submission/helpers/package.sh <generated-dir> <case-id> <output-dir>
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <generated-dir> <case-id> <output-dir>" >&2
    exit 1
fi
generated_dir="$1"
case_id="$2"
output_dir="$3"

command -v tar >/dev/null 2>&1 || { echo "Error: 'tar' not found in \$PATH." >&2; exit 1; }
[[ "${case_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "Error: invalid case id '${case_id}'." >&2; exit 1; }
[ -f "${generated_dir}/manifest.json" ] || { echo "Error: ${generated_dir}/manifest.json not found — run helpers/generate.sh first." >&2; exit 1; }

mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

mkdir -p "${work_dir}/${case_id}"
for name in manifest.json recovery.json move.sh signatures.json fork.log run.log etherscan-links.txt; do
    [ ! -f "${generated_dir}/${name}" ] || cp "${generated_dir}/${name}" "${work_dir}/${case_id}/${name}"
done

out_file="${output_dir}/${case_id}-$(date -u +%Y%m%dT%H%M%SZ).tgz"
tar -czf "${out_file}" -C "${work_dir}" "${case_id}"
printf '%s\n' "${out_file}"
