# Submission checklist

Once you've prepared your case — fork, `recovery.json`, `move.sh` — run
[`submission/prepare-submission.sh cases/<your-case-id>`](prepare-submission.sh) with
`signatures.json` already filled in. It starts a fresh fork itself and stops it afterwards
(`--no-fork` to use one you started). It runs the simulation, checks it against
`recovery.json` and `signatures.json`, tells you what is missing, and writes one `.tgz`
with everything
below that can be produced automatically (marked **in the package**), so you only send
that file plus what is left.

**Delivery channel:** email the `.tgz` to
[`zkevm-claims@polygon.technology`](mailto:zkevm-claims@polygon.technology). Put your
case reference in the subject line.

The package is laid out as `<case-id>/{manifest.json, recovery.json, move.sh, fork.log,
run.log, signatures.json[, etherscan-links.txt]}`; `manifest.json` records the tx hashes,
the impersonated addresses, the nonce, the balances before and after and the sha256 of
each file.

## What to submit

- [ ] **Fork logs** — the `setup/fork.log` file that `setup/fork.sh` writes (full console
      output; no need to copy it by hand), including the latest
      published block it fetched and its `fork_block matches the network's latest block`
      confirmation line. **In the package** (`fork.log`).
- [ ] **`recovery.json`** — your case's `cases/<your-case-id>/recovery.json`: the locked
      contract, the funds you want to recover (token and amount) and the destination wallet.
      Check it first with `recovery-tx/validate-recovery.sh`. It holds only that claim: the
      case reference and the control-path explanation below go in the email itself.
      **In the package** (`recovery.json`).
- [ ] **Simulated recovery transaction hash(es)** — the tx hash(es) produced by
      `recovery-tx/run.sh` showing the funds moving from the locked Smart Contract to your
      destination EOA on the fork. **In the package** (`manifest.json`, `run.log`).
- [ ] **One signature per impersonated EOA** — every EOA impersonated to execute the
      recovery transaction (owner(s)/signer(s) used to authorize it), each signing the
      fixed proof message from `ownership-proof/message-template.txt` with its real key.
      **In the package** (`signatures.json`); `prepare-submission.sh` refuses to build it if one is missing.
- [ ] **Controller signatures for any impersonated contract** — a contract has no
      private key, so if `move.sh` impersonated a contract directly, submit signatures
      from the EOA(s) that control it on-chain (owner, multisig signers meeting the
      threshold, admin) plus a short explanation of that control path, written in the
      email (e.g. which `owner()` / `getOwners()` call returns them at the fork block).
- [ ] **One signature for the final destination EOA** — the account that received the
      funds in the simulation, proving you control where the recovered funds would
      actually land. **In the package** (`prepare-submission.sh` requires it too).
- [ ] **The nonce and date used** in the signed message, so Polygon can reconstruct the
      exact message and verify each signature against it. **In the package** (inside each
      signed message, and the nonce in `manifest.json`).
- [ ] **Etherscan links** — for any signature published via
      [etherscan.io/verifiedSignatures](https://etherscan.io/verifiedSignatures)
      instead of `sign-message.sh`, the link to it. Put the links in
      `cases/<your-case-id>/etherscan-links.txt` and `prepare-submission.sh` includes the file.
- [ ] **Contact info / case reference** — the support thread or case ID this submission
      relates to, so it can be matched to the original report.

`prepare-submission.sh` already does the checks below (and also covers the destination EOA). To run
them by hand, e.g. if you assemble the submission without it, use
[`recovery-tx/list-impersonated.sh --signatures cases/<your-case-id>/signatures.json <tx-hash> ...`](../recovery-tx/list-impersonated.sh)
with every tx hash from `recovery-tx/run.sh` — it derives the impersonated addresses
from the transactions' own mined receipts, verifies every signature in
`signatures.json` with `ownership-proof/verify-signature.sh` (the same check Polygon runs
on your submission), and fails loudly if any entry is invalid or any EOA sender is still
missing a signature. It lists contract senders separately, since those are covered by
their controllers' signatures. It only checks senders, so it can't catch a missing
signature for your destination EOA — double-check that one yourself.

## Verifying a package

```bash
submission/verify-submission.sh <your-case-id>-<timestamp>.tgz
```

This is what Polygon runs on receiving it: it unpacks the `.tgz`, checks the file hashes in
`manifest.json`, re-runs `move.sh` on a fresh fork, checks it against `recovery.json`, derives
the impersonated addresses, verifies every signature and compares all of it with
`manifest.json`. The packaged `move.sh` runs inside a sandbox container that can only reach the fork (no
internet, nothing of your machine), the same one `prepare-submission.sh` uses.

## Why every signature is mandatory

Impersonation on a shadow-fork proves nothing about real-world control — anyone can
impersonate any address on a fork they run locally. Recovery certificates are only
generated after every required signature above is submitted and independently verified.
Incomplete submissions (missing a signer, mismatched nonce/date, wrong message format)
will be sent back for correction before any certificate work begins.
