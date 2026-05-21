# `chthonicsystems/devops-workflows`

Reusable GitHub Actions workflows + composite actions for [Chthonic
Systems](https://github.com/chthonicsystems) products. Per
[RFC 0019 — DevOps Strategy](https://github.com/chthonicsystems/architecture/blob/main/rfcs/0019-devops-strategy.md).

This repo is one of three artefacts in the Chthonic DevOps story:

1. **`chthonicsystems/devops-workflows`** *(this repo)* — reusable GitHub
   Actions workflows + composite actions, versioned via git tags.
   Products consume them via
   `uses: chthonicsystems/devops-workflows/.github/workflows/<name>.yml@v0`.
2. [`@chthonicsystems/devops-scripts`](https://github.com/chthonicsystems/devops-scripts)
   *(future, PR 27)* — npm package shipping `dev-start`,
   `setup-server`, `setup-ssl`, `db-backup`, etc. as CLI bins.
3. [`chthonicsystems/devops-template`](https://github.com/chthonicsystems/devops-template)
   *(future, PR 28)* — git template repo with the per-product
   orchestration glue (CDK scaffold, monitoring scaffold, nginx +
   Docker compose templates).

## What's in here

### Reusable workflows (`.github/workflows/`)

| Workflow | Purpose |
|---|---|
| `deploy-beta.yml` | Build API + web → push to DockerHub → SSH deploy → Playwright E2E gate |
| `deploy-prod.yml` | Find last green-on-beta → build prod web → SSH deploy |
| `deploy-cdk.yml` | AWS CDK stack deploy (cross-region bootstrap aware) |
| `deploy-monitoring.yml` | Prometheus + Grafana stack deploy |
| `e2e-gate.yml` | Standalone Playwright runner for hard-gate flows |
| `mobile-build-android.yml` | Capacitor Android build via Fastlane → Play Store internal track |
| `mobile-build-ios.yml` | Capacitor iOS build via Fastlane → TestFlight + App Store review |

### Composite actions (`actions/`)

| Action | Purpose |
|---|---|
| `setup-dotnet-with-packages` | `actions/setup-dotnet@v4` + GitHub Packages auth |
| `setup-node-with-packages` | `actions/setup-node@v4` + npm cache + `@chthonicsystems` registry auth |
| `find-green-beta-commit` | Compute the last-green-on-beta SHA + decide whether downstream should run |
| `appleboy-ssh-with-env` | Wrapper around `appleboy/ssh-action@v1.0.3` with bulk env-var passthrough + script invocation |
| `playwright-e2e-gate` | Wait-for-API-readiness + `npx playwright test` + artifact upload + summary |
| `docker-buildx-push` | `setup-buildx` + `metadata-action` + `build-push-action` with cache config |

## How to consume

### From a caller workflow

```yaml
# torquetech/.github/workflows/deploy-beta.yml
name: Deploy Beta

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: chthonicsystems/devops-workflows/.github/workflows/deploy-beta.yml@v0
    with:
      domain: torquetech-beta.chthonicsystems.com
      docker-image-prefix: chthonicsystems/torquetech
    secrets: inherit
```

### Tag pinning

- **`@v0`** — recommended for callers during the 0.x window. Floating
  major-version tag; auto-updates on every minor + patch release.
- **`@v0.1.0`** — exact version pin. Use when you need byte-for-byte
  reproducibility (e.g. release branches).
- **`@main`** — bleeding edge; not recommended outside ad-hoc testing.

See [`docs/VERSIONING.md`](docs/VERSIONING.md) for the full versioning
policy + bump-to-v1 trigger.

### Required secrets

Each reusable workflow uses `secrets: inherit` from its caller —
there's no explicit `secrets:` schema on the workflow boundary. The
required secrets per workflow are documented in
[`docs/REUSABLE-WORKFLOWS.md`](docs/REUSABLE-WORKFLOWS.md) and in
the YAML header comment of each workflow file. Caller repos must
have the relevant secrets defined at the GitHub Environment or repo
level.

## Documentation

- [`docs/REUSABLE-WORKFLOWS.md`](docs/REUSABLE-WORKFLOWS.md) — per-workflow inputs + expected secrets + usage example
- [`docs/COMPOSITE-ACTIONS.md`](docs/COMPOSITE-ACTIONS.md) — per-composite reference
- [`docs/VERSIONING.md`](docs/VERSIONING.md) — tag pinning + bump policy

## Status

- **Current version:** `v0.1.0`
- **Status:** initial extraction from TorqueTech via PR 26. Battle-tested in production via TorqueTech deploy chain.
- **Bump to `v1.0.0`:** when first sister-product (MarineDeck) GAs in production consuming this repo.

## Cross-references

- [RFC 0019 — DevOps Strategy](https://github.com/chthonicsystems/architecture/blob/main/rfcs/0019-devops-strategy.md) — governing RFC
- [RFC 0002 — Shared Library Strategy](https://github.com/chthonicsystems/architecture/blob/main/rfcs/0002-shared-library-strategy.md) — versioning + governance
- [PR 26 plan](https://github.com/chthonicsystems/architecture/blob/main/torquetech-refactor/03-pr-templates/26-devops-workflows.md) — extraction PR template
