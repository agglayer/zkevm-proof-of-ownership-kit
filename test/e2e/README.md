# End-to-end test

`test/e2e/run.sh` exercises the whole kit against a throwaway chain, with public test keys only:

1. starts `geth --dev` in Docker (stand-in for the halted zkEVM mainnet);
2. deploys `Vault.sol` (owner-only `withdraw`) and funds it with 5 ETH;
3. records the stable head block (geth --dev only mines on txs, so the head stays put);
4. starts `setup/fork.sh` (anvil in Docker) with `L2_RPC_URL` = geth and `FORK_BLOCK` = that block;
5. builds a temporary case from `cases/_template`, whose `move.sh` impersonates the owner and
   withdraws to a destination EOA; runs it with `recovery-tx/run.sh`;
6. signs with owner and destination (temporary keystore), then checks with
   `recovery-tx/list-impersonated.sh --signatures` and `ownership-proof/verify-signature.sh`;
7. checks that a tampered signature does not verify;
8. stops that fork and runs `submission/prepare-submission.sh` (`--allow-test-fork`), which starts its own
   fork from geth,
   then unpacks the `.tgz` and checks `manifest.json`, the file hashes and the signatures. A second
   case has the destination withdraw to itself, to check that the gas it pays is added back.

9. runs `submission/verify-submission.sh` on the `.tgz` (it starts its own fork), which unpacks it,
   re-runs `move.sh`, checks `recovery.json`, the impersonated addresses and the signatures, and compares
   them with `manifest.json`.

Negative cases: non-owner withdraw reverts; missing owner signature makes `list-impersonated.sh`
fail; `sign-message.sh` rejects `--private-key`; a forged signature does not verify; `prepare-submission.sh`
refuses a test fork without `--allow-test-fork`, a `recovery.json` declaring more than the vault
holds or less than `move.sh` moves, a missing owner signature (printing the command to sign) and
running while something already answers on the fork port; `verify-submission.sh` refuses a test package without `--allow-test-fork`,
a file changed after packaging, a manifest that differs from a fresh run and a path-traversal entry.

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
(unpacked), `CASE_DIR`, `SIGS`, `VAULT`, `OWNER`, `DEST`, `RPC_URL`, `WORKDIR`; helpers `step`, `fail`,
`expect_fail`, `fresh_fork`, `pkg` (prepare-submission.sh) and `verify` (verify-submission.sh).
