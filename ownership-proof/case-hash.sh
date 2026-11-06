#!/bin/bash
# Prints the "case hash" of a case directory: the value that goes into the signed message
# (message-template.txt, <case_hash>) so that a signature only counts for those exact files.
# Any change to recovery.json or move.sh — even a space — gives another hash and invalidates the
# signatures already made.
#
# It is the sha256 of these two lines (the sha256 of each file's exact bytes, two spaces, the name):
#
#   <sha256 of recovery.json>  recovery.json
#   <sha256 of move.sh>  move.sh
#
# (each line ends with a newline). By hand, with GNU coreutils:
#   (cd cases/<case-id> && sha256sum recovery.json move.sh | sha256sum)
#
# Requires: sha256sum or shasum.
#
# Usage: ownership-proof/case-hash.sh cases/<case-id>
set -euo pipefail

case_dir="${1:?Usage: ownership-proof/case-hash.sh <case-dir>}"
case_dir="${case_dir%/}"

if command -v sha256sum >/dev/null 2>&1; then
    sha256_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    sha256_cmd="shasum -a 256"
else
    echo "Error: sha256sum or shasum is required." >&2
    exit 1
fi

for f in recovery.json move.sh; do
    if [ ! -f "${case_dir}/${f}" ]; then
        echo "Error: ${case_dir}/${f} not found — the signed message covers recovery.json and move.sh, so both must exist (and be final) before signing." >&2
        exit 1
    fi
done

recovery_sum="$(${sha256_cmd} "${case_dir}/recovery.json" | awk '{print $1}')"
move_sum="$(${sha256_cmd} "${case_dir}/move.sh" | awk '{print $1}')"
printf '%s  recovery.json\n%s  move.sh\n' "${recovery_sum}" "${move_sum}" | ${sha256_cmd} | awk '{print $1}'
