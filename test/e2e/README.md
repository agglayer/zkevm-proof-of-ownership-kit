# End-to-end test

`test/e2e/run.sh` exercises the whole kit against a throwaway chain, with public test keys only:

1. starts `geth --dev` in Docker (stand-in for the halted zkEVM mainnet);
2. deploys `MockBridge.sol` (stand-in for the zkEVM bridge: same `bridgeAsset` / `bridgeMessage` /
   `networkID` / `getTokenWrappedAddress` and `BridgeEvent`, passed to the scripts as the test-only
   `BRIDGE_ADDRESS`; plus `fakeBridgeEvent`, which emits without taking funds, for a negative case),
   two `MockERC20`s (one native to the chain, one registered as the wrapped version of a network-0
   token) and `Vault.sol` (owner-only `execute`), and funds the vault with 5 ETH and both tokens;
3. records the stable head block (geth --dev only mines on txs, so the head stays put);
4. starts `setup/fork.sh` (anvil in Docker) with `L2_RPC_URL` = geth and `FORK_BLOCK` = that block;
5. builds a temporary case from `cases/_template`, whose `move.sh` impersonates the owner and makes
   the vault call `bridgeAsset` (4 ETH to network 0) and `bridgeMessage`; runs it with
   `recovery-tx/run.sh` and builds `recovery.json` (two outputs) with `recovery-tx/build-recovery.sh`;
   then checks that `validate-recovery.sh` refuses broken variants of it (version, missing/unknown
   fields, leaf type, network, amount, address, metadata, uint32 range);
6. signs with the owner (and the destination, an extra valid signature; temporary keystore), then checks with
   `recovery-tx/list-impersonated.sh --signatures` and `ownership-proof/verify-signature.sh`;
7. checks that a tampered signature does not verify;
8. stops that fork and runs `submission/prepare-submission.sh` (`--allow-test-fork`), which starts its own
   fork from geth,
   then unpacks the `.tgz` and checks `manifest.json`, the file hashes and the signatures. A case
   without `recovery.json` gets it written from `move.sh` (identical to step 5's), and a case driven
   by impersonating a contract (nobody signs) is packaged too, as is one where the vault withdraws to the
   owner and the owner calls the bridge, and one that bridges a native token (locked in the bridge), a
   wrapped token (burned) and a `bridgeMessage` carrying ETH, checking all three kinds of balance in the
   manifest.

9. runs `submission/verify-submission.sh` on the `.tgz` (it starts its own fork), which unpacks it,
   re-runs `move.sh`, checks that it gives `recovery.json`, the impersonated addresses and the signatures, and compares
   them with `manifest.json`.

Negative cases: non-owner `execute` reverts; missing owner signature makes `list-impersonated.sh`
fail; `sign-message.sh` rejects `--private-key`; a forged signature does not verify; `prepare-submission.sh`
refuses a non-standard fork (another `L2_RPC_URL`, `FORK_BLOCK`) without `--allow-test-fork`, a `recovery.json` that
differs from what `move.sh` bridges, a `BridgeEvent` the bridge did not back with funds (balance check), a
`bridgeAsset` to a network other than 0, a `move.sh` that never calls the bridge, a missing owner signature (printing the command to sign) and
running while something already answers on the fork port, a `move.sh` that tries to edit the state
with `anvil_setBalance` (the sandbox only allows an RPC allowlist) and a tx still pending when `move.sh` exits; `verify-submission.sh` refuses a test package without `--allow-test-fork`,
a file changed after packaging, a manifest that differs from a fresh run (nonce, balances) and a path-traversal entry.

Everything (containers, temp dirs, fork process) is removed on exit, also on failure. Nothing is
written to the repo.

## Run locally

Linux only for now: the script uses GNU `tar --transform` and `sha256sum` (macOS needs `gtar` and `coreutils`).

Needs `docker` (daemon running), Foundry (`cast`, `forge`), `curl`, `jq`. From the repo root:

```bash
test/e2e/run.sh
```

Optional env: `GETH_IMAGE`, `GETH_PORT` (18545), `ANVIL_PORT` (18546), `E2E_WORKDIR` +
`E2E_KEEP=1` to keep `fork.log` / `geth.log`. The first run downloads the geth image and solc 0.8.24.

## CI

`.github/workflows/e2e.yml` runs it on pull requests and pushes to `main`, and uploads `fork.log`
and `geth.log` as an artifact if it fails.

## Extending

New steps go before the final `E2E PASSED`. Variables available there: `PKG` (the `.tgz`), `PKG_DIR`
(unpacked), `CASE_DIR`, `SIGS`, `VAULT`, `BRIDGE`, `OWNER`, `DEST`, `RPC_URL`, `WORKDIR`; helpers `step`, `fail`,
`expect_fail`, `bridge_calls` / `write_move` (a `move.sh`), `pkg` (prepare-submission.sh) and `verify` (verify-submission.sh).
