#!/bin/bash
# Copied from recovery-tx/impersonate-and-move.template.sh — fill in the TODOs below
# with your case's specific addresses and contract call(s), then run it from the repo
# root with:
#
#   ./recovery-tx/run.sh cases/<your-case-id>/move.sh
#
# (see recovery-tx/impersonate-and-move.template.sh for the annotated original)
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

# TODO: fill in your case's addresses.
LOCKED_CONTRACT="0x0000000000000000000000000000000000dEaD"  # the SC holding the funds
OWNER_ADDRESS="0x0000000000000000000000000000000000dEaD"    # address that must authorize the move — adjust/remove if not applicable to your case
DESTINATION_ADDRESS="0x0000000000000000000000000000000000dEaD"  # where the recovered funds should end up on Ethereum
AMOUNT_WEI="0"                                                   # how much ETH to bridge, in wei
BRIDGE="0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe"             # the zkEVM bridge (do not change)

if ! command -v cast >/dev/null 2>&1; then
    echo "Error: 'cast' not found in \$PATH. Install the Foundry toolchain from https://getfoundry.sh" >&2
    exit 1
fi

echo "Impersonating ${OWNER_ADDRESS} ..."
cast rpc anvil_impersonateAccount "${OWNER_ADDRESS}" --rpc-url "${RPC_URL}" >/dev/null

# TODO: replace this call with whatever moves YOUR locked funds into the bridge
# (bridgeAsset to network 0 and/or bridgeMessage; one call = one output). Common shapes:
#   - an execute(target, value, data)-style method on the locked contract, callable by its owner
#   - a withdraw to an EOA, then that EOA calls the bridge itself
#   - a multisig needing several impersonated signers to approve/execute (repeat the
#     impersonate + cast send block once per signer)
BRIDGE_CALL="$(cast calldata "bridgeAsset(uint32,address,uint256,address,bool,bytes)" \
    0 "${DESTINATION_ADDRESS}" "${AMOUNT_WEI}" 0x0000000000000000000000000000000000000000 true 0x)"
echo "Sending recovery tx from ${OWNER_ADDRESS} ..."
cast send --unlocked --from "${OWNER_ADDRESS}" "${LOCKED_CONTRACT}" \
    "execute(address,uint256,bytes)" "${BRIDGE}" "${AMOUNT_WEI}" "${BRIDGE_CALL}" \
    --rpc-url "${RPC_URL}"

echo
echo "Note the transactionHash printed above — you can build recovery.json from it with"
echo "recovery-tx/build-recovery.sh. Every EOA impersonated above now needs a signature —"
echo "see ownership-proof/ and cases/<your-case-id>/README.md."
