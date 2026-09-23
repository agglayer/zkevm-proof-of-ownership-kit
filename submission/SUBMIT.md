# Submission checklist

Once you've completed the three steps in the main [README](../README.md) — fork,
simulate, sign — package the following and send it back through the same Polygon support
channel that gave you this kit.

**Delivery channel:** to be confirmed with your Polygon support contact (this may end up
being a PR to this repo, a zip attached to your support/Slack thread, or another agreed
channel — do not assume until confirmed).

## What to submit

- [ ] **Fork logs** — full console output from `setup/fork.sh`, including the latest
      published block it fetched and its `fork_block matches the network's latest block`
      confirmation line.
- [ ] **Simulated recovery transaction hash(es)** — the tx hash(es) produced by
      `recovery-tx/run.sh` showing the funds moving from the locked Smart Contract to your
      destination EOA on the fork.
- [ ] **One signature per impersonated EOA** — every EOA impersonated to execute the
      recovery transaction (owner(s)/signer(s) used to authorize it), each signing the
      fixed proof message from `ownership-proof/message-template.txt` with its real key.
- [ ] **Controller signatures for any impersonated contract** — a contract has no
      private key, so if `move.sh` impersonated a contract directly, submit signatures
      from the EOA(s) that control it on-chain (owner, multisig signers meeting the
      threshold, admin) plus a short explanation of that control path (e.g. which
      `owner()` / `getOwners()` call returns them at the fork block).
- [ ] **One signature for the final destination EOA** — the account that received the
      funds in the simulation, proving you control where the recovered funds would
      actually land.
- [ ] **The nonce and date used** in the signed message, so Polygon can reconstruct the
      exact message and verify each signature against it.
- [ ] **Etherscan links** — for any signature published via
      [etherscan.io/verifiedSignatures](https://etherscan.io/verifiedSignatures)
      instead of `sign-message.sh`, the link to it.
- [ ] **Contact info / case reference** — the support thread or case ID this submission
      relates to, so it can be matched to the original report.

Before packaging any of this, run
[`recovery-tx/list-impersonated.sh --signatures cases/<your-case-id>/signatures.json <tx-hash> ...`](../recovery-tx/list-impersonated.sh)
with every tx hash from `recovery-tx/run.sh` — it derives the impersonated addresses
from the transactions' own mined receipts, verifies every signature in
`signatures.json` with `ownership-proof/verify-signature.sh` (the same check Polygon runs
on your submission), and fails loudly if any entry is invalid or any EOA sender is still
missing a signature. It lists contract senders separately, since those are covered by
their controllers' signatures. It only checks senders, so it can't catch a missing
signature for your destination EOA — double-check that one yourself.

## Why every signature is mandatory

Impersonation on a shadow-fork proves nothing about real-world control — anyone can
impersonate any address on a fork they run locally. Recovery certificates are only
generated after every required signature above is submitted and independently verified.
Incomplete submissions (missing a signer, mismatched nonce/date, wrong message format)
will be sent back for correction before any certificate work begins.
