#!/bin/bash
# Builds the .tgz you send to Polygon for your case, guiding you step by step. It is the
# only script you need in submission/: the ones in submission/helpers/ are called by it.
#
# Before running it, your case directory (cases/<case-id>/) must have:
#   recovery.json    the funds, the locked contract and the destination wallet
#   move.sh          the simulated recovery, filled in
#   signatures.json  one signature per EOA that move.sh impersonates, plus the destination
#                    (ownership-proof/sign-message.sh, same nonce for all) — if some are
#                    missing, this script tells you which ones and how to sign them
#
# What it does:
#   1. checks those files are there and filled in;
#   2. starts a fresh shadow-fork, runs move.sh on it and checks the result against
#      recovery.json and signatures.json (helpers/generate.sh); the fork is stopped at the end;
#   3. packs everything into cases/<case-id>/<case-id>-<timestamp>.tgz (helpers/package.sh);
#   4. tells you where to send it and how to verify it.
#
# Requires: docker (with its daemon running), cast (Foundry), jq, curl, bc, tar.
#
# Usage (from the repo root):
#   submission/prepare-submission.sh cases/<case-id> [--output-dir <dir>] [--allow-test-fork]
#
# Options:
#   --output-dir <dir>  where to write the .tgz (default: the case directory)
#   --allow-test-fork   TESTING ONLY: accept a fork that is not at the halt block (FORK_BLOCK).
#                       Such a package is not valid for a real submission.
#
# Env overrides: RPC_URL (default http://127.0.0.1:8545), FORK_LOG, and the settings of
# setup/fork.sh (L2_RPC_URL, ...: `source setup/.env` first if you use one).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
helpers="${script_dir}/helpers"
submit_to="zkevm-claims@polygon.technology"

usage() {
    echo "Usage: $0 cases/<case-id> [--output-dir <dir>] [--allow-test-fork]" >&2
}

die() {
    echo >&2
    echo "Error: $*" >&2
    exit 1
}

banner() {
    echo
    echo "################################################################################"
    echo "# $*"
    echo "################################################################################"
}

case_arg=""
output_dir=""
gen_flags=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output-dir)
        [ "$#" -ge 2 ] || die "--output-dir requires a directory."
        output_dir="$2"
        shift 2
        ;;
    --allow-test-fork)
        gen_flags="${gen_flags} $1"
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
command -v docker >/dev/null 2>&1 || missing_tools="${missing_tools} docker"
if [ -n "${missing_tools}" ]; then
    echo "Error: missing required tool(s):${missing_tools}" >&2
    case "${missing_tools}" in *cast*) echo "  cast:   install the Foundry toolchain from https://getfoundry.sh" >&2 ;; esac
    case "${missing_tools}" in *docker*) echo "  docker: install Docker from https://docs.docker.com/get-docker/" >&2 ;; esac
    echo "  others: install them with your package manager (apt, brew, ...)" >&2
    exit 1
fi

# --- 1. The case ---------------------------------------------------------------------------

banner "1/4  Checking your case"
case_dir="${case_arg%/}"
[ -d "${case_dir}" ] || die "case directory '${case_dir}' not found. Create it with: cases/new-case.sh <case-id>"
case_dir="$(cd "${case_dir}" && pwd)"
case_id="$(basename "${case_dir}")"
rel_case="cases/${case_id}"
[ -n "${output_dir}" ] || output_dir="${case_dir}"

for f in recovery.json move.sh; do
    [ -f "${case_dir}/${f}" ] || die "${rel_case}/${f} not found. Start from cases/_template/ (cases/new-case.sh) and fill it in."
done
echo "Case: ${case_id} (${case_dir})"

if ! "${repo_root}/recovery-tx/validate-recovery.sh" "${case_dir}/recovery.json"; then
    die "fix ${rel_case}/recovery.json (see ${rel_case}/README.md step 1) and run this again."
fi

if grep -qi '0x0000000000000000000000000000000000dEaD' "${case_dir}/move.sh"; then
    die "${rel_case}/move.sh still has template placeholders (0x...dEaD). Fill in your addresses and the call that moves the funds (see ${rel_case}/README.md)."
fi
echo "OK   move.sh is filled in"

signatures_path="${case_dir}/signatures.json"
if [ ! -f "${signatures_path}" ] || ! jq -e 'type == "array" and length > 0' "${signatures_path}" >/dev/null 2>&1; then
    echo
    echo "NOTE: ${rel_case}/signatures.json has no signatures yet. Every EOA impersonated in"
    echo "      move.sh and your destination wallet must sign (see ${rel_case}/README.md step 2)."
    echo "      The simulation below will tell you exactly which addresses and how to sign them."
    [ -f "${signatures_path}" ] || echo "[]" >"${signatures_path}"
else
    echo "OK   signatures.json has $(jq 'length' "${signatures_path}") signature(s) (checked in step 2)"
fi

# --- 2. Simulate and check ------------------------------------------------------------------

banner "2/4  Simulating your recovery on a fresh fork and checking it"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
generated="${work_dir}/generated"
# gen_flags is unquoted on purpose: empty or a list of plain flags.
# shellcheck disable=SC2086
if ! "${helpers}/generate.sh" "${case_dir}" --out-dir "${generated}" ${gen_flags}; then
    echo >&2
    echo "The submission was NOT created. Fix what is described above and run again:" >&2
    echo "  submission/prepare-submission.sh ${rel_case}${gen_flags}" >&2
    exit 1
fi

# --- 3. Package -----------------------------------------------------------------------------

banner "3/4  Packing your submission"
out_file="$("${helpers}/package.sh" "${generated}" "${case_id}" "${output_dir}")"
if command -v sha256sum >/dev/null 2>&1; then
    sha256_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    sha256_cmd="shasum -a 256"
else
    sha256_cmd=""
fi
echo "Contents:"
tar -tzf "${out_file}" | sed 's/^/  /'

# --- 4. What to do with it ------------------------------------------------------------------

banner "4/4  Done — your submission is ready"
echo "FILE TO SUBMIT: ${out_file}"
[ -z "${sha256_cmd}" ] || echo "sha256:         $(${sha256_cmd} "${out_file}" | awk '{print $1}')"
echo
if jq -e '.test_fork == true' "${generated}/manifest.json" >/dev/null 2>&1; then
    echo "WARNING: built on a TEST fork (--allow-test-fork). It is NOT valid for a real submission;"
    echo "do not send it."
else
    echo "WHERE TO SEND IT"
    echo "  Email the .tgz to ${submit_to}, with your case reference in the subject line."
    if jq -e '(.contract_senders | length) > 0' "${generated}/manifest.json" >/dev/null 2>&1; then
        echo "  Some impersonated addresses are contracts: explain in the email how the EOAs that"
        echo "  signed control them (see submission/SUBMIT.md)."
    fi
    if [ -f "${case_dir}/etherscan-links.txt" ]; then
        echo "  Your etherscan-links.txt is inside the package."
    fi
fi
echo
echo "HOW TO VERIFY IT (what Polygon checks; run from the repo root, on a machine where you are"
echo "happy to run move.sh again)"
echo "  submission/verify-submission.sh ${out_file}${gen_flags}"
echo
echo "What is in the package and how to send it: submission/SUBMIT.md"
