# cases/

Each stakeholder's recovery case lives in its own directory here, copied from
[`_template/`](_template/README.md):

```bash
cases/new-case.sh <your-case-id>
```

`<your-case-id>` — a Slack thread ID, your project name, whatever's easy to reference
back to your support conversation (letters, digits, `.`, `_`, `-`). Plain
`cp -r cases/_template cases/<your-case-id>` does the same.

Each case holds `move.sh` (the simulated recovery: it moves the locked funds into the bridge),
`signatures.json` (the ownership proofs) and a step-by-step `README.md`. `recovery.json` (the
outputs you recover) is generated from `move.sh` by `submission/prepare-submission.sh`.

Full walkthrough: [`_template/README.md`](_template/README.md).
