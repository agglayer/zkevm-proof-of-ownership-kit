# Submission checklist

Once you've completed the three steps in the main [README](../README.md) — fork,
simulate, sign — package the following and send it back through the same Polygon support
channel that gave you this kit.

**Delivery channel:** to be confirmed with your Polygon support contact (this may end up
being a PR to this repo, a zip attached to your support/Slack thread, or another agreed
channel — do not assume until confirmed).

## What to submit

- [ ] **Fork logs** — full console output from `setup/fork.sh`, including the reference
      block number and confirmation from `verify-fork-state.js` that the fork started at
      the correct state.
- [ ] **Simulated recovery transaction hash(es)** — the tx hash(es) produced by
      `recovery-tx/run.sh` showing the funds moving from the locked Smart Contract to your
      destination EOA on the fork.
- [ ] **One signature per impersonated address** — every address impersonated to execute
      the recovery transaction (the Smart Contract itself where applicable, plus any
      owner(s)/signer(s) used to authorize it), each signing the fixed proof message from
      `ownership-proof/message-template.txt` with its real private key.
- [ ] **One signature for the final destination EOA** — the account that received the
      funds in the simulation, proving you control where the recovered funds would
      actually land.
- [ ] **The nonce and date used** in the signed message, so Polygon can reconstruct the
      exact message and verify each signature against it.
- [ ] **Contact info / case reference** — the support thread or case ID this submission
      relates to, so it can be matched to the original report.

Before packaging any of this, run
[`recovery-tx/list-impersonated.sh --signatures cases/<your-case-id>/signatures.json <tx-hash> ...`](../recovery-tx/list-impersonated.sh)
with every tx hash from `recovery-tx/run.sh` — it derives the impersonated addresses
from the transactions' own mined receipts and fails loudly if any of them is still
missing a signature. It only checks senders, so it can't catch a missing signature for
your destination EOA — double-check that one yourself.

## Why every signature is mandatory

Impersonation on a shadow-fork proves nothing about real-world control — anyone can
impersonate any address on a fork they run locally. Recovery certificates are only
generated after every required signature above is submitted and independently verified.
Incomplete submissions (missing a signer, mismatched nonce/date, wrong message format)
will be sent back for correction before any certificate work begins.
