# Reusable Workflows

This repo ships **7 reusable workflows** (`on: workflow_call`) that
caller workflows in product repos invoke via:

```yaml
jobs:
  <job>:
    uses: chthonicsystems/devops-workflows/.github/workflows/<name>.yml@v0
    with:
      <inputs>
    secrets: inherit
```

Per [RFC 0019](https://github.com/chthonicsystems/architecture/blob/main/rfcs/0019-devops-strategy.md)
§ 3 (option 3a), all reusable workflows use **`secrets: inherit`** —
caller's secret store flows through transparently. Each workflow's
expected secrets are documented below + in its YAML header comment.

## Index

| Workflow | Purpose | Required inputs |
|---|---|---|
| [`deploy-beta.yml`](#deploy-betayml) | Build + push images, SSH deploy, Playwright E2E gate | `domain`, `docker-image-prefix` |
| [`deploy-prod.yml`](#deploy-prodyml) | Find last-green-on-beta, build prod web, SSH deploy | `domain`, `docker-image-prefix` |
| [`deploy-cdk.yml`](#deploy-cdkyml) | Bootstrap + deploy AWS CDK stacks (cross-region aware) | `cdk-region` |
| [`deploy-monitoring.yml`](#deploy-monitoringyml) | Bootstrap SSL + deploy Prometheus + Grafana stack | _(none)_ |
| [`e2e-gate.yml`](#e2e-gateyml) | Standalone Playwright runner | `base-url` |
| [`mobile-build-android.yml`](#mobile-build-androidyml) | Capacitor Android build via Fastlane → Play Store | _(none)_ |
| [`mobile-build-ios.yml`](#mobile-build-iosyml) | Capacitor iOS build via Fastlane → TestFlight + App Store | _(none)_ |

---

## `deploy-beta.yml`

Lifts TorqueTech's `deploy-beta.yml` 4-job chain: build-and-push (api +
web + backup) → ssl-setup → deploy → playwright-e2e.

### Caller usage

```yaml
# .github/workflows/deploy-beta.yml in your product repo
name: Deploy Beta
on:
  push: { branches: [main] }
  workflow_dispatch:
jobs:
  deploy:
    uses: chthonicsystems/devops-workflows/.github/workflows/deploy-beta.yml@v0
    with:
      domain: torquetech-beta.chthonicsystems.com
      docker-image-prefix: chthonicsystems/torquetech
    secrets: inherit
```

### Inputs

| Input | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `domain` | string | — | ✓ | Beta domain |
| `docker-image-prefix` | string | — | ✓ | Image-name prefix (`-api` / `-web` / `-backup` get appended) |
| `web-image-tag` | string | `'beta'` | | Tag for the beta web image |
| `e2e-spec-glob` | string | `''` | | Optional glob passed to `npx playwright test` |
| `working-directory` | string | `/opt/torquetech` | | Server-side directory |
| `ssl-script` | string | `./scripts/setup-ssl-github.sh` | | Server-side SSL bootstrap script |
| `deploy-script` | string | `./scripts/deploy-github.sh` | | Server-side deploy script |
| `git-branch` | string | `main` | | Branch to git pull on the server |
| `api-context` / `web-context` / `backup-context` | string | `./api` / `./web` / `./backup` | | Build contexts |
| `app-version-json-path` | string | `web/app_version.json` | | Used for `REACT_APP_VERSION` build arg |
| `runner-environment` | string | `beta` | | GitHub Environment name |
| `runs-on` | string | `ubuntu-latest` | | Runner image |
| `ssh-command-timeout` | string | `15m` | | SSH command timeout |

### Required secrets (`secrets: inherit`)

```
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
AWS_BEDROCK_ACCESS_KEY_ID, AWS_BEDROCK_SECRET_ACCESS_KEY
AWS_BEDROCK_GUARDRAIL_ID, AWS_BEDROCK_GUARDRAIL_VERSION
AWS_DOCUMENTS_BUCKET, AWS_MEDIA_BUCKET
AI_KEYPAIR_SECRET_NAME, AI_LOG_GROUP_NAME
APPLE_CLIENT_ID
CHTHONIC_PACKAGES_PAT          (optional; falls back to GITHUB_TOKEN)
DO_HOST, DO_USER, DO_SSH_KEY
DOCKERHUB_USERNAME, DOCKERHUB_TOKEN
DOMAIN, SSL_EMAIL
E2E_ADMIN_USERNAME, E2E_ADMIN_PASSWORD
FIREBASE_API_KEY, FIREBASE_APP_ID, FIREBASE_AUTH_DOMAIN
FIREBASE_MESSAGING_SENDER_ID, FIREBASE_PROJECT_ID
FIREBASE_SERVICE_ACCOUNT_JSON, FIREBASE_STORAGE_BUCKET
FIREBASE_VAPID_KEY
FROM_EMAIL
GH_SUPPORT_TOKEN, GH_SUPPORT_REPO   (optional)
GOOGLE_CLIENT_ID, GOOGLE_PLACES_API_KEY
JWT_SECRET
MICROSOFT_CLIENT_ID
MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD
QB_CLIENT_ID, QB_CLIENT_SECRET, QB_WEBHOOK_VERIFIER_TOKEN
RUN_MIGRATIONS
S3_BACKUP_BUCKET
STRIPE_*
TWILIO_*
XERO_*
```

Optional caller `vars`:
- `CRM_DOMAIN` — passed to `setup-ssl-github.sh` for CRM cert provisioning

---

## `deploy-prod.yml`

Lifts TorqueTech's `deploy-prod.yml`. Finds the last green commit on
the upstream beta workflow; builds a prod-flavoured web image (API +
backup are reused from beta — no rebuild); SSH deploys to prod.

### Caller usage

```yaml
name: Deploy Production
on:
  schedule: [{ cron: '0 7 * * *' }]
  workflow_dispatch:
jobs:
  deploy:
    uses: chthonicsystems/devops-workflows/.github/workflows/deploy-prod.yml@v0
    with:
      domain: torquetech.chthonicsystems.com
      docker-image-prefix: chthonicsystems/torquetech
    secrets: inherit
```

### Inputs

| Input | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `domain` | string | — | ✓ | Production domain |
| `docker-image-prefix` | string | — | ✓ | Image-name prefix |
| `upstream-workflow-file` | string | `deploy-beta.yml` | | Upstream for last-green check |
| `working-directory` | string | `/opt/torquetech` | | Server-side directory |
| `ssl-script` / `deploy-script` | string | `./scripts/setup-ssl-github.sh` / `./scripts/deploy-github.sh` | | Server-side scripts |
| `web-context` | string | `./web` | | Build context for prod web |
| `app-version-json-path` | string | `web/app_version.json` | | |
| `runner-environment` | string | `production` | | |
| `runs-on` | string | `ubuntu-latest` | | |
| `ssh-command-timeout` | string | `15m` | | |
| `branch` | string | `main` | | |

### Required secrets

Same set as `deploy-beta.yml`.

---

## `deploy-cdk.yml`

Bootstraps the primary AWS region + optionally an additional region
(default `us-east-1` for Bedrock + Guardrails), then runs
`npx cdk deploy --all --require-approval never`.

### Caller usage

```yaml
name: Deploy CDK
on:
  push: { branches: [main], paths: [cdk/**] }
  workflow_dispatch:
jobs:
  deploy:
    uses: chthonicsystems/devops-workflows/.github/workflows/deploy-cdk.yml@v0
    with:
      cdk-region: ap-southeast-1
    secrets: inherit
```

### Inputs

| Input | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `cdk-region` | string | — | ✓ | Primary AWS region |
| `bootstrap-additional-region` | string | `us-east-1` | | Empty string to skip |
| `cdk-path` | string | `cdk` | | CDK project subdir |
| `node-version` | string | `20` | | |
| `install-command` | string | `npm install` | | |
| `deploy-args` | string | `--all --require-approval never` | | |
| `runs-on` | string | `ubuntu-latest` | | |
| `runner-environment` | string | `''` | | |

### Required secrets

```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

---

## `deploy-monitoring.yml`

Idempotent SSL bootstrap (Let's Encrypt standalone) + monitoring stack
deploy via docker-compose.

### Caller usage

```yaml
name: Deploy Monitoring
on:
  push:
    branches: [main]
    paths: [monitoring/**, docker-compose.monitoring.yml]
  workflow_dispatch:
jobs:
  deploy:
    uses: chthonicsystems/devops-workflows/.github/workflows/deploy-monitoring.yml@v0
    secrets: inherit
```

### Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `compose-file` | string | `docker-compose.monitoring.yml` | |
| `working-directory` | string | `/opt/torquetech` | |
| `git-branch` | string | `main` | |
| `runs-on` | string | `ubuntu-latest` | |
| `runner-environment` | string | `''` | |

### Required secrets

```
DO_HOST, DO_USER, DO_SSH_KEY
DOMAIN, SSL_EMAIL
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
GRAFANA_ADMIN_PASSWORD
```

---

## `e2e-gate.yml`

Standalone Playwright runner. Used as a `needs: deploy` step in
`deploy-beta.yml` and can also be called directly for ad-hoc gates
against any environment.

### Caller usage

```yaml
jobs:
  smoke:
    uses: chthonicsystems/devops-workflows/.github/workflows/e2e-gate.yml@v0
    with:
      base-url: https://torquetech.chthonicsystems.com
      summary-title: '🎭 Prod Smoke Tests'
    secrets: inherit
```

### Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `base-url` | string | — | Required — target environment URL |
| `spec-glob` | string | `''` | |
| `working-directory` | string | `.` | |
| `install-command` | string | `npm install` | |
| `browsers` | string | `chromium` | |
| `readiness-timeout-seconds` | string | `180` | |
| `skip-readiness` | string | `false` | |
| `report-name` | string | `playwright-report` | |
| `report-retention-days` | string | `14` | |
| `summary-title` | string | `🎭 E2E Test Results` | |
| `runs-on` | string | `ubuntu-latest` | |
| `runner-environment` | string | `''` | |

### Required secrets

```
E2E_ADMIN_USERNAME
E2E_ADMIN_PASSWORD
```

---

## `mobile-build-android.yml`

Capacitor Android build → Fastlane upload → Play Store internal track
+ S3 mirror.

### Caller usage

```yaml
name: Deploy Android
on:
  workflow_run:
    workflows: ["Deploy Beta"]
    types: [completed]
  workflow_dispatch:
jobs:
  build:
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    uses: chthonicsystems/devops-workflows/.github/workflows/mobile-build-android.yml@v0
    secrets: inherit
```

### Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `upstream-workflow-file` | string | `deploy-beta.yml` | |
| `caller-workflow-file` | string | `deploy-android.yml` | |
| `working-directory` | string | `web` | |
| `app-version-json-path` | string | `web/app_version.json` | |
| `branch` | string | `main` | |
| `runs-on` | string | `ubuntu-latest` | |
| `java-version` | string | `21` | |
| `ruby-version` | string | `3.2` | |
| `node-version` | string | `22` | |
| `fastlane-lane` | string | `android internal` | |

### Required secrets

```
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
AWS_S3_BUCKET_ANDROID
KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD
FIREBASE_SERVICE_ACCOUNT_JSON
REACT_APP_GOOGLE_CLIENT_ID, REACT_APP_GOOGLE_IOS_CLIENT_ID
REACT_APP_MICROSOFT_CLIENT_ID, REACT_APP_APPLE_CLIENT_ID
CHTHONIC_PACKAGES_PAT          (optional)
```

---

## `mobile-build-ios.yml`

Capacitor iOS build → Fastlane TestFlight + App Store review (with
Spaceship blocking-state precheck).

### Caller usage

```yaml
name: Deploy iOS
on:
  workflow_run:
    workflows: ["Deploy Beta"]
    types: [completed]
  workflow_dispatch:
jobs:
  build:
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    uses: chthonicsystems/devops-workflows/.github/workflows/mobile-build-ios.yml@v0
    secrets: inherit
```

### Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `upstream-workflow-file` | string | `deploy-beta.yml` | |
| `caller-workflow-file` | string | `deploy-ios.yml` | |
| `working-directory` | string | `web` | |
| `app-version-json-path` | string | `web/app_version.json` | |
| `branch` | string | `main` | |
| `runs-on-linux` | string | `ubuntu-latest` | |
| `runs-on-macos` | string | `macos-26` | |
| `runner-environment` | string | `production` | |
| `ruby-version` | string | `3.2` | |
| `node-version` | string | `22` | |
| `beta-lane` | string | `ios beta` | |
| `release-lane` | string | `ios release` | |
| `ios-build-export-path` | string | `web/ios/App/build/export/App.ipa` | |
| `asc-metadata-path` | string | `web/ios/metadata` | |

### Required secrets

```
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
AWS_S3_BUCKET_IOS
APP_STORE_CONNECT_API_KEY_ID
APP_STORE_CONNECT_API_ISSUER_ID
APP_STORE_CONNECT_API_KEY_BASE64
MATCH_PASSWORD
MATCH_GIT_BASIC_AUTHORIZATION
REACT_APP_GOOGLE_IOS_CLIENT_ID
REACT_APP_MICROSOFT_CLIENT_ID
REACT_APP_APPLE_CLIENT_ID
CHTHONIC_PACKAGES_PAT          (optional)
```
