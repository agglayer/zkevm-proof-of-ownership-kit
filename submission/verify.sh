#!/bin/bash
# Polygon side: verifies a submission .tgz and applies it on top of the state left by the
# recoveries already processed, giving what goes into the certificate.
#
# What it does:
#   1. runs submission/verify-submission.sh on (a private copy of) the .tgz: the package, its
#      files, signatures and manifest, on a fresh fork. Exit 3 there (manual review required)
#      carries on and is returned at the end;
#   2. finds the latest state: in the archive (STATE_URI), the run folder with the highest height
#      under <STATE_URI>/[<STATE_NETWORK_ID>/] (the layout of aggkit's exit_certificate archive:
#      <height> zero-padded to 10 digits, files stored zstd-compressed as <path>.zst and listed in
#      archive-manifest.json), and downloads its Anvil state dump (STATE_FILE), checked against the
#      manifest (size and sha256). The first submission of all has no previous state: then the
#      archive must be empty and --no-previous-state given (the plain fork is used);
#   3. runs the case again (submission/helpers/generate.sh) on a fork that loads that state:
#      move.sh must still give exactly the packaged recovery.json, with valid signatures;
#   4. writes to the output directory:
#        recovery-verify.json  the packaged recovery.json with, in each output, the deposit_count
#                              its BridgeEvent got on that state, plus a top-level "metadata"
#                              ({"case_hash": the case hash the signatures cover,
#                              ownership-proof/case-hash.sh});
#        anvil-state-<id>.json the state after move.sh (Anvil dump, JSON): the state the next
#                              case starts from, once archived. <id> is the first 8 bytes of the
#                              case hash (16 hex chars).
#   5. with --upload, stores them in the archive as the next run, <latest height + 1> (1 for the
#      first), in the same layout: <STATE_FILE>.zst (the new state) and recovery-verify.json.zst
#      next to it,
#      then archive-manifest.json last (version 1, zstd; per file size, sha256, object size and
#      CRC32C; info: case_id, case_hash, previous_run...). Write-once: an existing run is never
#      overwritten. Without --upload nothing is uploaded.
#   Exit code 0 = verified, 1 = not, 3 = verified but MANUAL REVIEW IS REQUIRED (see
#   verify-submission.sh).
#
# Requires: docker (with its daemon running), cast (Foundry), jq, curl, bc, tar, zstd, xxd, gzip,
# perl, and gcloud (authenticated, with read access to the bucket, and object create for --upload)
# for a gs:// STATE_URI.
#
# Usage (from the repo root):
#   submission/verify.sh <submission.tgz> [--out-dir <dir>] [--no-previous-state] [--upload]
#                        [--allow-test-fork]
#
# Options:
#   --out-dir <dir>       where to write recovery-verify.json and anvil-state-<id>.json (default:
#                         verify-out/<case-id>). Existing files there are overwritten.
#   --no-previous-state   the first submission: the archive must hold no run yet, and the case
#                         runs on the plain fork
#   --upload              store the result in the archive as the next run (step 5)
#   --allow-test-fork     TESTING ONLY: see verify-submission.sh
#
# Env overrides:
#   STATE_URI         the archive: gs://<bucket>/<prefix>, or a local directory with the same
#                     layout (default gs://polygonlabs-zkevm-prod-let-archive/runs)
#   STATE_NETWORK_ID  a network folder between STATE_URI and the heights (default: none, runs are
#                     <STATE_URI>/<height>/)
#   STATE_FILE        the state dump's path in a run, as listed in archive-manifest.json (default
#                     metadata/anvil-state.json: the exit_certificate tool stores it among its
#                     metadata files)
#   RPC_URL, FORK_LOG and the settings of setup/fork.sh, as in verify-submission.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
STATE_URI="${STATE_URI:-gs://polygonlabs-zkevm-prod-let-archive/runs}"
STATE_NETWORK_ID="${STATE_NETWORK_ID:-}"
STATE_FILE="${STATE_FILE:-metadata/anvil-state.json}"

usage() {
    echo "Usage: $0 <submission.tgz> [--out-dir <dir>] [--no-previous-state] [--upload] [--allow-test-fork]" >&2
}

die() {
    echo >&2
    echo "FAIL: $*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

tgz=""
out_dir=""
gen_flags=""
no_previous=0
upload=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --no-previous-state)
        no_previous=1
        shift
        ;;
    --upload)
        upload=1
        shift
        ;;
    --out-dir)
        [ "$#" -ge 2 ] || die "--out-dir requires a directory."
        out_dir="$2"
        shift 2
        ;;
    --allow-test-fork)
        gen_flags="${gen_flags} --allow-test-fork"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        echo "Error: unknown option '$1'." >&2
        exit 1
        ;;
    *)
        [ -z "${tgz}" ] || {
            usage
            echo "Error: only one .tgz is accepted." >&2
            exit 1
        }
        tgz="$1"
        shift
        ;;
    esac
done
if [ -z "${tgz}" ]; then
    usage
    exit 1
fi
[ -f "${tgz}" ] || { echo "Error: ${tgz} not found." >&2; exit 1; }

# The archive: gs:// through gcloud, anything else a local directory (file:// accepted).
state_base="${STATE_URI%/}"
case "${state_base}" in
gs://*) store=gcs ;;
*)
    store=local
    state_base="${state_base#file://}"
    ;;
esac
[[ "${STATE_NETWORK_ID}" =~ ^[0-9]*$ ]] || { echo "Error: STATE_NETWORK_ID must be a number (or empty)." >&2; exit 1; }
[[ "${STATE_FILE}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/${STATE_FILE}/" != */../* ]] \
    || { echo "Error: STATE_FILE must be a relative path inside a run." >&2; exit 1; }

missing_tools=""
for bin in cast jq curl bc tar zstd xxd gzip perl; do
    command -v "${bin}" >/dev/null 2>&1 || missing_tools="${missing_tools} ${bin}"
done
[ "${store}" != gcs ] || command -v gcloud >/dev/null 2>&1 || missing_tools="${missing_tools} gcloud"
if command -v sha256sum >/dev/null 2>&1; then
    sha256_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    sha256_cmd="shasum -a 256"
else
    missing_tools="${missing_tools} sha256sum"
fi
if [ -n "${missing_tools}" ]; then
    echo "Error: missing required tool(s):${missing_tools}" >&2
    exit 1
fi
sha256_of() { ${sha256_cmd} "$1" | awk '{print $1}'; }
size_of() { wc -c <"$1" | tr -d ' '; }

# store_ls <prefix>: the names directly under it, one per line (nothing when the prefix does not
# exist). store_get <object> <file>. store_put <file> <object>: write-once.
store_ls() {
    if [ "${store}" = gcs ]; then
        local out
        if ! out="$(gcloud storage ls "$1/" 2>&1)"; then
            case "${out}" in *"matched no objects"*) return 0 ;; esac
            printf '%s\n' "${out}" >&2
            return 1
        fi
        printf '%s\n' "${out}" | sed -e 's#/$##' -e 's#.*/##'
    else
        [ -d "$1" ] || return 0
        ls -1 "$1"
    fi
}
store_put() {
    if [ "${store}" = gcs ]; then
        gcloud storage cp --if-generation-match=0 "$1" "$2" >/dev/null
    else
        [ ! -e "$2" ] || return 1
        mkdir -p "$(dirname "$2")"
        cp "$1" "$2"
    fi
}
# CRC32C of a file, as an unsigned integer (0 when gcloud, which computes it, is not installed;
# only possible with a local archive).
crc32c_of() {
    local hex
    command -v gcloud >/dev/null 2>&1 || { echo 0; return; }
    hex="$(gcloud storage hash "$1" --hex --skip-md5 2>/dev/null | sed -n 's/^crc32c_hash: *//p')"
    [[ "${hex}" =~ ^[0-9a-fA-F]{8}$ ]] || { echo 0; return; }
    echo $((16#${hex}))
}
store_get() {
    if [ "${store}" = gcs ]; then
        gcloud storage cat "$1" >"$2"
    else
        cp "$1" "$2"
    fi
}

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
# A private copy: the file checked in step 1 is the one used afterwards.
cp "${tgz}" "${work_dir}/submission.tgz"

# --- 1. The package ----------------------------------------------------------------------------

step "1. Verifying the package on a fresh fork (submission/verify-submission.sh)"
set +e
# gen_flags is unquoted on purpose: empty or a list of plain flags.
# shellcheck disable=SC2086
"${script_dir}/verify-submission.sh" "${work_dir}/submission.tgz" ${gen_flags}
verify_status=$?
set -e
case "${verify_status}" in
0 | 3) ;;
*) die "the package does not verify — see above." ;;
esac
# verify-submission.sh checked the package (paths, file types, hashes): unpack it again here.
case_id="$(tar -tzf "${work_dir}/submission.tgz" | head -n 1 | cut -d/ -f1)"
mkdir "${work_dir}/pkg"
tar -xzf "${work_dir}/submission.tgz" -C "${work_dir}/pkg" --no-same-owner
case_dir="${work_dir}/pkg/${case_id}"
[ -n "${out_dir}" ] || out_dir="verify-out/${case_id}"
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"

# --- 2. The latest state -----------------------------------------------------------------------

network_base="${state_base}${STATE_NETWORK_ID:+/${STATE_NETWORK_ID}}"
step "2. Fetching the latest state from ${network_base}"
heights="$(store_ls "${network_base}")" || die "could not list ${network_base}."
height="$(printf '%s\n' "${heights}" | grep -E '^[0-9]{10}$' | sort | tail -n 1 || true)"
state_json=""
if [ "${no_previous}" -eq 1 ]; then
    [ -z "${height}" ] || die "--no-previous-state is only for the first submission, but ${network_base} already has runs (latest: height $((10#${height})))."
    echo "No previous state (--no-previous-state, the archive is empty): the case runs on the plain fork."
else
    [ -n "${height}" ] || die "no run folder (10-digit height) under ${network_base}. If this is the very first submission, run again with --no-previous-state."
    run_base="${network_base}/${height}"
    echo "Latest run: height $((10#${height})) (${run_base})"
    manifest="${work_dir}/archive-manifest.json"
    store_get "${run_base}/archive-manifest.json" "${manifest}" \
        || die "${run_base} has no archive-manifest.json: the run is incomplete (still uploading?)."
    jq -e '.version == 1 and .compression == "zstd" and (.files | type) == "array"' "${manifest}" >/dev/null 2>&1 \
        || die "unexpected archive-manifest.json in ${run_base} (expected version 1, zstd)."
    entry="$(jq -c --arg p "${STATE_FILE}" '[.files[] | select(.path == $p)] | if length == 1 then .[0] else null end' "${manifest}")"
    [ "${entry}" != "null" ] || die "the run at ${run_base} has no ${STATE_FILE} (archive-manifest.json does not list it)."
    object="$(jq -r '.object' <<<"${entry}")"
    want_size="$(jq -r '.size' <<<"${entry}")"
    want_sha="$(jq -r '.sha256' <<<"${entry}")"
    [[ "${object}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/${object}/" != */../* ]] || die "unsafe object name in archive-manifest.json: ${object}"
    [[ "${want_size}" =~ ^[0-9]+$ && "${want_sha}" =~ ^[0-9a-f]{64}$ ]] || die "bad size or sha256 for ${STATE_FILE} in archive-manifest.json."
    store_get "${run_base}/${object}" "${work_dir}/state.json.zst" || die "could not download ${run_base}/${object}."
    zstd -q -d -c "${work_dir}/state.json.zst" >"${work_dir}/state.json" || die "${run_base}/${object} is not valid zstd."
    [ "$(size_of "${work_dir}/state.json")" = "${want_size}" ] || die "${STATE_FILE}: size differs from archive-manifest.json."
    [ "$(sha256_of "${work_dir}/state.json")" = "${want_sha}" ] || die "${STATE_FILE}: sha256 differs from archive-manifest.json."
    jq -e 'type == "object" and has("accounts")' "${work_dir}/state.json" >/dev/null 2>&1 || die "${STATE_FILE} is not an Anvil state dump."
    echo "OK   ${STATE_FILE} (sha256 ${want_sha})"
    state_json="${work_dir}/state.json"
fi

# --- 3. The case on that state -----------------------------------------------------------------

step "3. Running ${case_id} on a fork that loads that state (or the plain fork, first submission)"
# gen_flags is unquoted on purpose: empty or a list of plain flags.
# shellcheck disable=SC2086
FORK_LOG="${FORK_LOG:-${work_dir}/fork.log}" LOAD_STATE="${state_json}" \
    STATE_OUT="${work_dir}/state-after.json" DEPOSIT_COUNTS_OUT="${work_dir}/deposit-counts.json" \
    "${script_dir}/helpers/generate.sh" "${case_dir}" --out-dir "${work_dir}/generated" ${gen_flags} \
    || die "the case does not hold up on the latest state — see above."

# --- 4. recovery-verify.json and the new state -------------------------------------------------

step "4. Writing ${out_dir}"
case_hash="$("${repo_root}/ownership-proof/case-hash.sh" "${case_dir}")"
[[ "${case_hash}" =~ ^[0-9a-f]{64}$ ]] || die "unexpected case hash: ${case_hash}"
jq -e --slurpfile dc "${work_dir}/deposit-counts.json" '($dc[0] | length) == (.outputs | length)' "${case_dir}/recovery.json" >/dev/null \
    || die "the deposit counts do not match the outputs of recovery.json."
jq --slurpfile dc "${work_dir}/deposit-counts.json" --arg h "${case_hash}" \
    '{version, metadata: {case_hash: $h},
      outputs: [.outputs | to_entries[] | .value + {deposit_count: $dc[0][.key]}],
      origin_SC_funds}' "${case_dir}/recovery.json" >"${out_dir}/recovery-verify.json"
state_name="anvil-state-${case_hash:0:16}.json"
cp "${work_dir}/state-after.json" "${out_dir}/${state_name}"
echo "  recovery-verify.json  (deposit counts $(jq -r '[.outputs[].deposit_count] | map(tostring) | join(", ")' "${out_dir}/recovery-verify.json"); case hash ${case_hash})"
echo "  ${state_name}  (the state after move.sh, sha256 $(sha256_of "${out_dir}/${state_name}"))"

# --- 5. Store it in the archive (--upload) -----------------------------------------------------

if [ "${upload}" -eq 1 ]; then
    if [ -z "${height}" ]; then next=1; else next=$((10#${height} + 1)); fi
    next_name="$(printf '%010d' "${next}")"
    new_run="${network_base}/${next_name}"
    step "5. Storing the result as run ${next} (${new_run})"
    up="${work_dir}/upload"
    mkdir -p "${up}"
    files_json="[]"
    meta_dir="$(dirname "${STATE_FILE}")"
    [ "${meta_dir}" != "." ] || meta_dir=""
    for pair in "${STATE_FILE}:${out_dir}/${state_name}" "${meta_dir:+${meta_dir}/}recovery-verify.json:${out_dir}/recovery-verify.json"; do
        rel="${pair%%:*}"
        src="${pair#*:}"
        obj="${up}/$(printf '%s' "${rel}" | tr '/' '_').zst"
        zstd -q -f "${src}" -o "${obj}"
        files_json="$(jq -c --arg path "${rel}" --argjson size "$(size_of "${src}")" --arg sha "$(sha256_of "${src}")" \
            --arg object "${rel}.zst" --argjson osize "$(size_of "${obj}")" --argjson crc "$(crc32c_of "${obj}")" \
            '. + [{path: $path, size: $size, sha256: $sha, object: $object, objectSize: $osize, objectCrc32c: $crc}]' <<<"${files_json}")"
        store_put "${obj}" "${new_run}/${rel}.zst" || die "could not store ${new_run}/${rel}.zst (does run ${next} exist already? the archive is write-once)."
        echo "OK   ${rel}.zst"
    done
    jq -n --argjson files "${files_json}" --arg case_id "${case_id}" --arg case_hash "${case_hash}" \
        --arg prev "${height:+$((10#${height}))}" --arg commit "$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: 1, compression: "zstd",
          info: {tool: "zkevm-proof-of-ownership-kit submission/verify.sh", toolVersion: $commit,
                 case_id: $case_id, case_hash: $case_hash, previous_run: $prev, createdAt: $created},
          files: $files}' >"${up}/archive-manifest.json"
    store_put "${up}/archive-manifest.json" "${new_run}/archive-manifest.json" \
        || die "could not store ${new_run}/archive-manifest.json."
    echo "OK   archive-manifest.json (stored last: the run is complete)"
fi

if [ -z "${height}" ]; then applied="ON THE PLAIN FORK (first submission)"; else applied="ON THE LATEST STATE (height $((10#${height})))"; fi
echo
if [ "${verify_status}" -eq 3 ]; then
    echo "APPLIED ${applied} — MANUAL REVIEW REQUIRED: ${tgz##*/} (case ${case_id}); see step 1."
    exit 3
fi
echo "VERIFIED AND APPLIED ${applied}: ${tgz##*/} (case ${case_id})"
