#!/bin/bash
# Runs a whole case against the shadow-fork and packages everything Polygon needs into a
# single .tgz to email to zkevm-claims@polygon.technology (see submission/SUBMIT.md).
#
# What it does, in order (it stops at the first problem, with what to do next):
#   1. validates cases/<case-id>/recovery.json (recovery-tx/validate-recovery.sh);
#   2. checks the fork: setup/fork.log confirms the halt block, the RPC is up and the
#      locked contract still holds the funds (a fork already used by an earlier run does
#      not — restart setup/fork.sh);
#   3. runs the case's move.sh against the fork (recovery-tx/run.sh) and collects every
#      transaction it mined;
#   4. checks the simulation against recovery.json: for each declared fund, the locked
#      contract lost exactly that amount and the destination gained exactly that amount;
#   5. works out which EOAs were impersonated (the senders) and makes sure each of them,
#      plus the destination, has a valid signature in signatures.json — it asks you to
#      sign the missing ones when run from a terminal;
#   6. writes manifest.json and the .tgz.
#
# Signatures are kept in cases/<case-id>/signatures.json, so if you stop half-way, restart
# the fork (setup/fork.sh), run this again and the signatures you already made are reused
# (same nonce).
#
# Requires: cast, jq, curl, bc, tar (and sha256sum or shasum), plus a running fork.
#
# Usage (from the repo root):
#   submission/package.sh cases/<case-id> [--output-dir <dir>] [--allow-test-fork]
#
# Options:
#   --output-dir <dir>  where to write the .tgz (default: the case directory)
#   --allow-test-fork   TESTING ONLY: accept a fork that is not at the halt block (started
#                       with FORK_BLOCK). The manifest records it; such a package is not
#                       valid for a real submission.
#
# Env overrides:
#   RPC_URL    the fork's JSON-RPC (default: http://127.0.0.1:8545)
#   FORK_LOG   the log fork.sh wrote (default: setup/fork.log)
#   NONCE      the nonce for the signatures of a new case (default: generated; ignored once
#              signatures.json already has entries, which fix it)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
FORK_LOG="${FORK_LOG:-${repo_root}/setup/fork.log}"
chain_id_expected=1101
submit_to="zkevm-claims@polygon.technology"

usage() {
    echo "Usage: $0 cases/<case-id> [--output-dir <dir>] [--allow-test-fork]" >&2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

case_arg=""
output_dir=""
allow_test_fork=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output-dir)
        [ "$#" -ge 2 ] || die "--output-dir requires a directory."
        output_dir="$2"
        shift 2
        ;;
    --allow-test-fork)
        allow_test_fork=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        die "unknown option '$1'."
        ;;
    *)
        [ -z "${case_arg}" ] || {
            usage
            die "only one case directory is accepted."
        }
        case_arg="$1"
        shift
        ;;
    esac
done
if [ -z "${case_arg}" ]; then
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
    case "${missing_tools}" in *cast*) echo "  cast: install the Foundry toolchain from https://getfoundry.sh" >&2 ;; esac
    exit 1
fi

sha256_of() { ${sha256_cmd} "$1" | awk '{print $1}'; }

# Amounts are 256-bit integers, beyond Bash arithmetic, so they go through bc. Values read
# from the RPC are checked to be plain digits first: they are untrusted input.
require_uint() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "unexpected value from the RPC (expected an integer): $1"
}
bc_calc() { printf '%s\n' "$1" | bc; }

# balance_of <holder> <token: native|0x...>
balance_of() {
    local out
    if [ "$2" = "native" ]; then
        out="$(cast balance "$1" --rpc-url "${RPC_URL}")"
    else
        out="$(cast call "$2" "balanceOf(address)(uint256)" "$1" --rpc-url "${RPC_URL}")"
    fi
    out="${out%% *}"
    require_uint "${out}"
    printf '%s' "${out}"
}

# --- 1. The case -------------------------------------------------------------------------

case_dir="${case_arg%/}"
[ -d "${case_dir}" ] || die "case directory '${case_dir}' not found — create it with cases/new-case.sh <case-id>."
case_dir="$(cd "${case_dir}" && pwd)"
case_id="$(basename "${case_dir}")"
recovery_path="${case_dir}/recovery.json"
move_path="${case_dir}/move.sh"
signatures_path="${case_dir}/signatures.json"
[ -f "${recovery_path}" ] || die "${recovery_path} not found."
[ -f "${move_path}" ] || die "${move_path} not found."
[ -n "${output_dir}" ] || output_dir="${case_dir}"
mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

step "1. Checking ${case_id}/recovery.json"
"${repo_root}/recovery-tx/validate-recovery.sh" "${recovery_path}"

locked="$(jq -r '.locked_contract' "${recovery_path}")"
destination="$(jq -r '.destination' "${recovery_path}")"
funds="$(jq -c '.funds[]' "${recovery_path}")"

# --- 2. The fork -------------------------------------------------------------------------

step "2. Checking the fork"
[ -f "${FORK_LOG}" ] || die "${FORK_LOG} not found — start the fork with setup/fork.sh (it writes that log), or set FORK_LOG."

halt_block="$(sed -n 's/^halt_block=\([0-9]*\)$/\1/p' "${repo_root}/setup/fork.sh")"
require_uint "${halt_block}"
confirmed_line="$(grep -E "^fork_block matches the network's latest block: [0-9]+$" "${FORK_LOG}" | tail -n 1 || true)"
[ -n "${confirmed_line}" ] || die "${FORK_LOG} has no \"fork_block matches the network's latest block\" line — was the fork started by setup/fork.sh, and did it get that far?"
fork_block="${confirmed_line##*: }"

test_fork=false
if grep -q "^WARNING: FORK_BLOCK=" "${FORK_LOG}" || [ "${fork_block}" != "${halt_block}" ]; then
    if [ "${allow_test_fork}" -ne 1 ]; then
        die "the fork is not at the halt block (${halt_block}; log says ${fork_block}) — a package built on it would not be accepted. Restart setup/fork.sh without FORK_BLOCK."
    fi
    test_fork=true
    echo "WARNING: test fork (block ${fork_block}) accepted by --allow-test-fork; this package is NOT valid for a real submission."
fi
echo "Fork log: fork block ${fork_block} confirmed against the network's latest block."

chain_id="$(cast chain-id --rpc-url "${RPC_URL}" 2>/dev/null)" || die "could not reach ${RPC_URL} — is setup/fork.sh running?"
require_uint "${chain_id}"
if [ "${test_fork}" = false ] && [ "${chain_id}" != "${chain_id_expected}" ]; then
    die "the RPC at ${RPC_URL} has chain id ${chain_id}, expected ${chain_id_expected} (zkEVM mainnet) — is that the shadow-fork?"
fi
head_before="$(cast block-number --rpc-url "${RPC_URL}")"
require_uint "${head_before}"
[ "${head_before}" -ge "${fork_block}" ] || die "the RPC head (${head_before}) is behind the fork block (${fork_block})."

[ "$(cast code "${locked}" --rpc-url "${RPC_URL}")" != "0x" ] || die "locked_contract ${locked} has no code on the fork — it must be a Smart Contract."
[ "$(cast code "${destination}" --rpc-url "${RPC_URL}")" = "0x" ] || die "destination ${destination} is a contract; it must be an EOA you control, because it has to sign."

# Balances before the move. The locked contract must hold at least what is declared: if
# not, the fork was probably already used by an earlier run.
balances="[]"
while IFS= read -r fund; do
    token="$(jq -r '.token' <<<"${fund}")"
    amount="$(jq -r '.amount' <<<"${fund}")"
    locked_before="$(balance_of "${locked}" "${token}")"
    dest_before="$(balance_of "${destination}" "${token}")"
    if [ "$(bc_calc "${locked_before} >= ${amount}")" != "1" ]; then
        die "${locked} holds ${locked_before} of ${token} on the fork, less than the ${amount} declared. If you already ran this case, restart setup/fork.sh for a fresh fork."
    fi
    balances="$(jq -c --arg token "${token}" --arg amount "${amount}" --arg lb "${locked_before}" --arg db "${dest_before}" \
        '. + [{token: $token, amount: $amount, locked_before: $lb, destination_before: $db}]' <<<"${balances}")"
done <<<"${funds}"
echo "The locked contract holds the declared funds."

# --- 3. Run move.sh ----------------------------------------------------------------------

step "3. Running ${case_id}/move.sh on the fork"
run_log="${work_dir}/run.log"
set +e
RPC_URL="${RPC_URL}" "${repo_root}/recovery-tx/run.sh" "${move_path}" 2>&1 | tee "${run_log}"
run_status="${PIPESTATUS[0]}"
set -e
[ "${run_status}" -eq 0 ] || die "move.sh failed (see above). Restart setup/fork.sh before trying again, since the fork may be half-modified."

head_after="$(cast block-number --rpc-url "${RPC_URL}")"
require_uint "${head_after}"
tx_hashes=""
n="${head_before}"
while [ "${n}" -lt "${head_after}" ]; do
    n=$((n + 1))
    block_txs="$(cast rpc eth_getBlockByNumber "$(printf '0x%x' "${n}")" false --rpc-url "${RPC_URL}" | jq -r '.transactions[]?')"
    [ -z "${block_txs}" ] || tx_hashes+="${block_txs}"$'\n'
done
[ -n "${tx_hashes}" ] || die "move.sh did not send any transaction to the fork (blocks ${head_before}..${head_after})."
echo "Transactions mined by move.sh:"
printf '%s' "${tx_hashes}" | sed 's/^/  /'

# --- 4. Senders, and the simulation against recovery.json --------------------------------

step "4. Checking the result against recovery.json"
senders=""
dest_fees="0"
while IFS= read -r tx; do
    [ -z "${tx}" ] && continue
    receipt="$(cast receipt "${tx}" --json --rpc-url "${RPC_URL}")"
    status="$(jq -r '.status' <<<"${receipt}")"
    case "${status}" in 1 | 0x1) ;; *) die "transaction ${tx} reverted on the fork." ;; esac
    from="$(jq -r '.from' <<<"${receipt}")"
    [[ "${from}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "could not read the sender of ${tx}."
    senders+="$(lower "${from}")"$'\n'
    if [ "$(lower "${from}")" = "$(lower "${destination}")" ]; then
        gas_used="$(cast to-dec "$(jq -r '.gasUsed' <<<"${receipt}")")"
        gas_price="$(cast to-dec "$(jq -r '.effectiveGasPrice' <<<"${receipt}")")"
        require_uint "${gas_used}"
        require_uint "${gas_price}"
        dest_fees="$(bc_calc "${dest_fees} + ${gas_used} * ${gas_price}")"
    fi
done <<<"${tx_hashes}"
senders="$(printf '%s' "${senders}" | sort -u)"

result_failed=0
result_balances="[]"
while IFS= read -r row; do
    token="$(jq -r '.token' <<<"${row}")"
    amount="$(jq -r '.amount' <<<"${row}")"
    lb="$(jq -r '.locked_before' <<<"${row}")"
    db="$(jq -r '.destination_before' <<<"${row}")"
    la="$(balance_of "${locked}" "${token}")"
    da="$(balance_of "${destination}" "${token}")"
    fees="0"
    # The destination may itself have sent transactions; the gas it paid is not a movement
    # of funds, so it is added back to compare the native balance.
    [ "${token}" != "native" ] || fees="${dest_fees}"
    locked_lost="$(bc_calc "${lb} - ${la}")"
    dest_gained="$(bc_calc "${da} + ${fees} - ${db}")"
    if [ "${locked_lost}" = "${amount}" ] && [ "${dest_gained}" = "${amount}" ]; then
        echo "OK   ${token}: ${amount} moved from ${locked} to ${destination}"
    else
        echo "FAIL ${token}: declared ${amount}; the locked contract lost ${locked_lost} and the destination gained ${dest_gained}." >&2
        result_failed=1
    fi
    result_balances="$(jq -c --argjson row "${row}" --arg la "${la}" --arg da "${da}" --arg fees "${fees}" \
        '. + [$row + {locked_after: $la, destination_after: $da, destination_gas_paid: $fees}]' <<<"${result_balances}")"
done < <(jq -c '.[]' <<<"${balances}")
if [ "${result_failed}" -ne 0 ]; then
    die "the simulation does not match recovery.json. Fix recovery.json or move.sh and restart setup/fork.sh."
fi

# --- 5. Proof of ownership ---------------------------------------------------------------

step "5. Proof of ownership"
eoa_senders=""
contract_senders=""
while IFS= read -r addr; do
    [ -z "${addr}" ] && continue
    if [ "$(cast code "${addr}" --rpc-url "${RPC_URL}")" = "0x" ]; then
        eoa_senders+="${addr}"$'\n'
    else
        contract_senders+="${addr}"$'\n'
    fi
done <<<"${senders}"

required="$(printf '%s%s\n' "${eoa_senders}" "$(lower "${destination}")" | sed '/^$/d' | sort -u)"
echo "EOAs that must sign (impersonated senders and the destination):"
printf '%s\n' "${required}" | sed 's/^/  /'
if [ -n "${contract_senders}" ]; then
    echo "Contracts that sent transactions (they cannot sign; their controlling EOAs must, and you"
    echo "explain that control path in the email — see submission/SUBMIT.md):"
    printf '%s' "${contract_senders}" | sed 's/^/  /'
fi

[ -f "${signatures_path}" ] || echo "[]" >"${signatures_path}"

nonce=""
first_message="$(jq -r '.[0].message // empty' "${signatures_path}")"
if [ -n "${first_message}" ]; then
    nonce="${first_message#*nonce: }"
    nonce="${nonce%% — date:*}"
fi
if [ -z "${nonce}" ]; then
    nonce="${NONCE:-$(date -u +%Y%m%d%H%M%S)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')}"
fi
echo "Nonce for this case: ${nonce}"

# missing_signers: required addresses with no entry in signatures.json
missing_signers() {
    local signed
    signed="$(jq -r '.[]?.address // empty' "${signatures_path}" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r addr; do
        [ -z "${addr}" ] && continue
        grep -Fxq "${addr}" <<<"${signed}" || printf '%s\n' "${addr}"
    done <<<"${required}"
}

missing="$(missing_signers)"
if [ -n "${missing}" ] && [ -t 0 ]; then
    echo
    echo "Signatures missing. For each address, enter how to sign (the key never goes on the command line):"
    echo "  --ledger | --trezor | --account <foundry-keystore-name> | --keystore <path> | --interactive"
    echo "Leave empty to stop and sign outside this script (e.g. with ownership-proof/sign-message.sh --print-message and etherscan.io/verifiedSignatures)."
    # A `for` (not a here-string `while read`) so the prompts below read from the terminal.
    for addr in ${missing}; do
        while :; do
            signer_flags=()
            read -r -p "Signer for ${addr}: " -a signer_flags || true
            [ "${#signer_flags[@]}" -gt 0 ] || break
            if ADDRESS="${addr}" NONCE="${nonce}" "${repo_root}/ownership-proof/sign-message.sh" "${signatures_path}" "${signer_flags[@]}"; then
                break
            fi
            echo "Signing failed — try again, or leave empty to stop."
        done
    done
    missing="$(missing_signers)"
fi

if [ -n "${missing}" ]; then
    echo >&2
    echo "Error: these addresses still have no signature in ${signatures_path}:" >&2
    printf '%s\n' "${missing}" | sed 's/^/  /' >&2
    echo "Sign each one (same nonce), then restart setup/fork.sh and run this again:" >&2
    while IFS= read -r addr; do
        [ -z "${addr}" ] && continue
        echo "  ADDRESS=${addr} NONCE=${nonce} ./ownership-proof/sign-message.sh ${signatures_path} --ledger   # or --trezor | --account <name> | --interactive" >&2
    done <<<"${missing}"
    exit 1
fi

"${repo_root}/ownership-proof/verify-signature.sh" "${signatures_path}" || die "signatures.json has invalid entries — see above."

# --- 6. Package --------------------------------------------------------------------------

step "6. Writing the package"
stage="${work_dir}/stage/${case_id}"
mkdir -p "${stage}"
cp "${recovery_path}" "${stage}/recovery.json"
cp "${move_path}" "${stage}/move.sh"
cp "${signatures_path}" "${stage}/signatures.json"
cp "${FORK_LOG}" "${stage}/fork.log"
cp "${run_log}" "${stage}/run.log"
[ ! -f "${case_dir}/etherscan-links.txt" ] || cp "${case_dir}/etherscan-links.txt" "${stage}/etherscan-links.txt"

files_json="{}"
for f in "${stage}"/*; do
    files_json="$(jq -c --arg name "$(basename "${f}")" --arg sum "$(sha256_of "${f}")" '. + {($name): $sum}' <<<"${files_json}")"
done

to_json_array() { printf '%s' "$1" | sed '/^$/d' | jq -R . | jq -s -c .; }
kit_commit="$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)"
kit_dirty=false
[ -z "$(git -C "${repo_root}" status --porcelain 2>/dev/null || true)" ] || kit_dirty=true

jq -n \
    --arg case_id "${case_id}" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg kit_commit "${kit_commit}" \
    --argjson kit_dirty "${kit_dirty}" \
    --argjson test_fork "${test_fork}" \
    --arg fork_block "${fork_block}" \
    --arg chain_id "${chain_id}" \
    --arg head_before "${head_before}" \
    --arg head_after "${head_after}" \
    --arg locked "${locked}" \
    --arg destination "${destination}" \
    --arg nonce "${nonce}" \
    --argjson tx_hashes "$(to_json_array "${tx_hashes}")" \
    --argjson eoa_senders "$(to_json_array "${eoa_senders}")" \
    --argjson contract_senders "$(to_json_array "${contract_senders}")" \
    --argjson required_signers "$(to_json_array "${required}")" \
    --argjson balances "${result_balances}" \
    --argjson files "${files_json}" \
    '{case_id: $case_id, created_at: $created_at, kit_commit: $kit_commit, kit_dirty: $kit_dirty,
      test_fork: $test_fork, fork_block: $fork_block, chain_id: $chain_id,
      head_before: $head_before, head_after: $head_after,
      locked_contract: $locked, destination: $destination, nonce: $nonce,
      tx_hashes: $tx_hashes, eoa_senders: $eoa_senders, contract_senders: $contract_senders,
      required_signers: $required_signers, balances: $balances, files: $files}' >"${stage}/manifest.json"

out_file="${output_dir}/${case_id}-$(date -u +%Y%m%dT%H%M%SZ).tgz"
tar -czf "${out_file}" -C "${work_dir}/stage" "${case_id}"

echo "Package written: ${out_file}"
echo "Contents:"
tar -tzf "${out_file}" | sed 's/^/  /'
echo
if [ "${test_fork}" = true ]; then
    echo "This package was built on a TEST fork and is not valid for a real submission."
else
    echo "Done. Email it to ${submit_to} with your case reference in the subject line,"
    echo "and — if any impersonated address is a contract — the explanation of how the signing"
    echo "EOAs control it (see submission/SUBMIT.md)."
fi
