#!/bin/bash
# Verifies a submission .tgz built by submission/prepare-submission.sh — what Polygon does on
# receiving it, and what you can run yourself before sending it.
#
# What it does:
#   1. unpacks the .tgz safely (it is untrusted input: single <case-id>/ folder, regular files
#      only, no absolute or '..' paths) and checks the files in manifest.json against their sha256;
#   2. starts a fresh shadow-fork (the same one setup/fork.sh gives anyone: pinned to the halt
#      block) and runs the packaged move.sh on it, checking the result against the packaged
#      recovery.json and that signatures.json holds a valid signature for every EOA that
#      move.sh impersonates plus the destination (submission/helpers/generate.sh);
#   3. compares what it found on its own fork with what the manifest claims: locked contract,
#      destination, nonce, fork block, impersonated addresses (EOA and contract), and the
#      amounts moved. (Transaction hashes and gas are not compared: they depend on the run.)
#   The fork is stopped at the end. Exit code 0 = verified, 1 = not.
#
# NOTE: step 2 executes the packaged move.sh (a Bash script written by the submitter), but inside
# a sandbox container that only reaches the fork (see recovery-tx/run.sh): no internet, nothing
# of your machine, read-only filesystem, resource limits. It is still worth reading it first
# (`tar -xzOf <tgz> <case-id>/move.sh`).
#
# Requires: docker (with its daemon running), cast (Foundry), jq, curl, bc, tar.
#
# Usage (from the repo root):
#   submission/verify-submission.sh <submission.tgz> [--allow-test-fork]
#
# Options:
#   --allow-test-fork   TESTING ONLY: accept a package built on a test fork (manifest
#                       test_fork=true) and a fork that is not at the halt block
#
# Env overrides: RPC_URL (default http://127.0.0.1:8545; nothing may answer there, the fork is
# started on that port), FORK_LOG (default: a temp file) and the settings of setup/fork.sh
# (L2_RPC_URL, ...: `source setup/.env` first if you use one).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

usage() {
    echo "Usage: $0 <submission.tgz> [--allow-test-fork]" >&2
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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

tgz=""
gen_flags=""
allow_test_fork=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --allow-test-fork)
        allow_test_fork=1
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

missing_tools=""
for bin in cast jq curl bc tar; do
    command -v "${bin}" >/dev/null 2>&1 || missing_tools="${missing_tools} ${bin}"
done
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
[ -f "${tgz}" ] || { echo "Error: ${tgz} not found." >&2; exit 1; }
tgz="$(cd "$(dirname "${tgz}")" && pwd)/$(basename "${tgz}")"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

# --- 1. Unpack and check the files -----------------------------------------------------------

step "1. Unpacking ${tgz##*/} and checking its files"
listing="$(tar -tzf "${tgz}" 2>/dev/null)" || die "${tgz} is not a readable .tgz."
[ -n "${listing}" ] || die "the package is empty."
case_id="$(printf '%s\n' "${listing}" | head -n 1 | cut -d/ -f1)"
[[ "${case_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unexpected top-level name '${case_id}' in the package."
while IFS= read -r entry; do
    case "${entry}" in
    "${case_id}" | "${case_id}/" | "${case_id}/"*) ;;
    *) die "the package has an entry outside ${case_id}/: ${entry}" ;;
    esac
    case "${entry}" in /* | *..*) die "unsafe path in the package: ${entry}" ;; esac
done <<<"${listing}"
# Only regular files and directories (tar -tv shows the type as the first character).
if tar -tvzf "${tgz}" | cut -c1 | grep -qv '^[-d]$'; then
    die "the package contains links or special files; only regular files are allowed."
fi
tar -xzf "${tgz}" -C "${work_dir}" --no-same-owner
case_dir="${work_dir}/${case_id}"
for f in manifest.json recovery.json move.sh signatures.json fork.log run.log; do
    [ -f "${case_dir}/${f}" ] || die "the package lacks ${f}."
done
manifest="${case_dir}/manifest.json"
jq -e 'type == "object"' "${manifest}" >/dev/null 2>&1 || die "manifest.json is not valid JSON."
[ "$(jq -r '.case_id' "${manifest}")" = "${case_id}" ] || die "manifest case_id does not match the package folder (${case_id})."

hash_failed=0
while IFS=$'\t' read -r name want; do
    [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "manifest lists an unsafe file name: ${name}"
    [ -f "${case_dir}/${name}" ] || die "manifest lists ${name} but the package lacks it."
    got="$(${sha256_cmd} "${case_dir}/${name}" | awk '{print $1}')"
    if [ "${got}" = "${want}" ]; then
        echo "OK   ${name} matches its manifest sha256"
    else
        echo "FAIL ${name}: sha256 differs from the manifest" >&2
        hash_failed=1
    fi
done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' "${manifest}")
[ "${hash_failed}" -eq 0 ] || die "some files do not match manifest.json."
for f in recovery.json move.sh signatures.json; do
    jq -e --arg f "${f}" '.files[$f] != null' "${manifest}" >/dev/null || die "manifest.json does not cover ${f}."
done

if jq -e '.test_fork == true' "${manifest}" >/dev/null; then
    [ "${allow_test_fork}" -eq 1 ] || die "the package was built on a TEST fork (manifest test_fork=true); it is not valid. Use --allow-test-fork only for testing."
fi

# --- 2. Re-run it on a fresh fork ------------------------------------------------------------

step "2. Re-running the case on a fresh fork (recovery.json, impersonated addresses, signatures)"
export FORK_LOG="${FORK_LOG:-${work_dir}/fork.log}"
generated="${work_dir}/generated"
# gen_flags is unquoted on purpose: empty or a list of plain flags.
# shellcheck disable=SC2086
"${script_dir}/helpers/generate.sh" "${case_dir}" --out-dir "${generated}" ${gen_flags} \
    || die "the case does not hold up on a fresh fork — see above."

# --- 3. Compare with what the manifest claims ------------------------------------------------

step "3. Comparing with manifest.json"
# What must be the same on any run. Addresses are lowercased and lists sorted. Tx hashes,
# gas and block numbers of the head are left out: they depend on when the run happens.
normalize='{
    locked_contract: (.locked_contract | ascii_downcase),
    destination: (.destination | ascii_downcase),
    nonce: .nonce,
    fork_block: .fork_block,
    chain_id: .chain_id,
    test_fork: .test_fork,
    eoa_senders: ([.eoa_senders[] | ascii_downcase] | sort),
    contract_senders: ([.contract_senders[] | ascii_downcase] | sort),
    required_signers: ([.required_signers[] | ascii_downcase] | sort),
    balances: [.balances[] | {token: (.token | ascii_downcase), amount, locked_before, locked_after, destination_before}]
}'
claimed="$(jq -S "${normalize}" "${manifest}")" || die "manifest.json lacks fields the verifier needs."
found="$(jq -S "${normalize}" "${generated}/manifest.json")"

compare_failed=0
for key in locked_contract destination nonce fork_block chain_id test_fork eoa_senders contract_senders required_signers balances; do
    c="$(jq -c --arg k "${key}" '.[$k]' <<<"${claimed}")"
    f="$(jq -c --arg k "${key}" '.[$k]' <<<"${found}")"
    if [ "${c}" = "${f}" ]; then
        echo "OK   ${key}"
    else
        echo "FAIL ${key}: the manifest says ${c}, a fresh run gives ${f}" >&2
        compare_failed=1
    fi
done
[ "${compare_failed}" -eq 0 ] || die "the manifest does not match what the case does on a fresh fork."

# The submitter's kit may differ from this one (scripts, images): not a failure, but worth knowing.
claimed_commit="$(jq -r '.kit_commit // "unknown"' "${manifest}")"
local_commit="$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$(jq -r '.kit_dirty // false' "${manifest}")" = "true" ]; then
    echo "WARNING: the package was built with a kit that had local modifications (kit_dirty=true, commit ${claimed_commit})." >&2
fi
if [ "${claimed_commit}" != "${local_commit}" ]; then
    echo "WARNING: the package was built with kit commit ${claimed_commit}; this verifier is at ${local_commit}." >&2
fi

# The signatures in the package are exactly the ones checked in step 2 (generate.sh verified them
# on the unpacked signatures.json); show who signed.
echo
echo "Impersonated EOAs (and the destination) with a valid signature:"
jq -r '.required_signers[]' "${manifest}" | sed 's/^/  /'
if jq -e '(.contract_senders | length) > 0' "${manifest}" >/dev/null; then
    echo "Contracts that sent transactions (no signature possible; the submitter must explain their"
    echo "controlling EOAs in the email — check that explanation by hand):"
    jq -r '.contract_senders[]' "${manifest}" | sed 's/^/  /'
fi

echo
echo "VERIFIED: ${tgz##*/} (case ${case_id}, nonce $(jq -r '.nonce' "${manifest}"))"
