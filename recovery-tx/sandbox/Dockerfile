# Image the sandbox of recovery-tx/run.sh runs move.sh in: the Foundry image (bash, cast, forge,
# anvil) plus jq and curl. Built automatically by run.sh the first time (needs internet for
# apt only then; running it needs none). Nothing else is added: keep it minimal.
ARG FOUNDRY_IMAGE=ghcr.io/foundry-rs/foundry:v1.5.1
FROM ${FOUNDRY_IMAGE}
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
USER foundry
