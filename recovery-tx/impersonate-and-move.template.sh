#!/bin/bash
# TEMPLATE — copy this file into your case directory (cases/<your-case-id>/move.sh, see
# cases/_template/) and fill in the TODOs below before running it.
#
# Moves funds locked in a Smart Contract to a destination EOA, against the local
# shadow-fork started by setup/fork.sh. Every address impersonated here — and the
# destination EOA — must submit a signature afterwards, via ownership-proof/, before
# any recovery certificate can be generated. See cases/_template/README.md.
#
# Requires: the Foundry toolchain (for `cast`), and setup/fork.sh already running.
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

# TODO: fill in your case's addresses.
LOCKED_CONTRACT="0x0000000000000000000000000000000000dEaD"  # the SC holding the funds
OWNER_ADDRESS="0x0000000000000000000000000000000000dEaD"    # address that must authorize the move — adjust/remove if not applicable to your case
DESTINATION_EOA="0x0000000000000000000000000000000000dEaD"  # where the recovered funds should end up

if ! command -v cast >/dev/null 2>&1; then
    echo "Error: 'cast' not found in \$PATH. Install the Foundry toolchain from https://getfoundry.sh" >&2
    exit 1
fi

echo "Impersonating ${OWNER_ADDRESS} ..."
cast rpc anvil_impersonateAccount "${OWNER_ADDRESS}" --rpc-url "${RPC_URL}" >/dev/null

# TODO: replace this call with whatever actually moves the funds for your case. Common
# shapes:
#   - a withdraw()-style method on the locked contract, callable by its owner
#   - an ERC20 transfer() called by the SC or its owner
#   - a multisig needing several impersonated signers to approve/execute (repeat the
#     impersonate + cast send block once per signer)
#
# Example below: the owner calls a hypothetical withdraw(address) on the locked
# contract. --unlocked sends the tx unsigned, which Anvil accepts from an impersonated
# account (fork.sh also runs with --auto-impersonate, so the anvil_impersonateAccount
# call above is a belt-and-braces step, not strictly required).
echo "Sending recovery tx from ${OWNER_ADDRESS} ..."
cast send --unlocked --from "${OWNER_ADDRESS}" "${LOCKED_CONTRACT}" \
    "withdraw(address)" "${DESTINATION_EOA}" \
    --rpc-url "${RPC_URL}"

echo
echo "Note the transactionHash printed above — you'll need it for submission."
echo "Every address impersonated above, plus the destination EOA, now needs a"
echo "signature — see ../../ownership-proof/ and README.md in this directory."
