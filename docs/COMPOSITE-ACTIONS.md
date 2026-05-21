# Composite Actions

This repo ships **6 composite actions** consumed by the reusable
workflows + reusable directly from caller workflows when the
reusable-workflow shape doesn't fit.

| Composite | Purpose |
|---|---|
| [`setup-dotnet-with-packages`](#setup-dotnet-with-packages) | `actions/setup-dotnet@v4` + Chthonic GitHub Packages NuGet feed |
| [`setup-node-with-packages`](#setup-node-with-packages) | `actions/setup-node@v4` + npm cache + `@chthonicsystems` registry |
| [`find-green-beta-commit`](#find-green-beta-commit) | Compute last-green upstream SHA + `should_proceed` flag |
| [`appleboy-ssh-with-env`](#appleboy-ssh-with-env) | SSH deploy with bulk env-var passthrough |
| [`playwright-e2e-gate`](#playwright-e2e-gate) | Wait-for-readiness + `npx playwright test` + artifact + summary |
| [`docker-buildx-push`](#docker-buildx-push) | `setup-buildx` + `metadata-action` + `build-push-action` with cache |

---

## `setup-dotnet-with-packages`

Wraps `actions/setup-dotnet@v4` and registers the Chthonic GitHub
Packages NuGet source idempotently.

```yaml
- uses: chthonicsystems/devops-workflows/actions/setup-dotnet-with-packages@v0
  with:
    github-packages-pat: ${{ secrets.CHTHONIC_PACKAGES_PAT || secrets.GITHUB_TOKEN }}
```

| Input | Default | Purpose |
|---|---|---|
| `dotnet-version` | `9.0.x` | |
| `github-username` | `''` (falls back to `$GITHUB_ACTOR`) | |
| `github-packages-pat` | — (required) | PAT with `read:packages` |
| `source-name` | `github-chthonic` | |
| `source-url` | `https://nuget.pkg.github.com/chthonicsystems/index.json` | |

---

## `setup-node-with-packages`

Wraps `actions/setup-node@v4` with npm cache + `@chthonicsystems`
scope mapped to GitHub Packages. Exports `NODE_AUTH_TOKEN` to
`$GITHUB_ENV` so subsequent npm steps in the calling job can run
`npm ci` / `npm install` / `npm publish` against the scoped registry.

```yaml
- uses: chthonicsystems/devops-workflows/actions/setup-node-with-packages@v0
  with:
    github-packages-pat: ${{ secrets.CHTHONIC_PACKAGES_PAT || secrets.GITHUB_TOKEN }}
- run: npm ci
  working-directory: web
```

| Input | Default | Purpose |
|---|---|---|
| `node-version` | `22` | |
| `working-directory` | `web` | Used for cache key |
| `github-packages-pat` | — (required) | |
| `registry-scope` | `@chthonicsystems` | |
| `registry-url` | `https://npm.pkg.github.com` | |
| `enable-cache` | `true` | Set `false` when no `package-lock.json` exists |

---

## `find-green-beta-commit`

Queries the last successful run of an upstream workflow and decides
whether the calling downstream workflow should run. Replaces the
~25-line bash block previously duplicated in TT's `deploy-prod.yml`,
`deploy-android.yml`, and `deploy-ios.yml`.

```yaml
- id: find
  uses: chthonicsystems/devops-workflows/actions/find-green-beta-commit@v0
  with:
    upstream-workflow-file: deploy-beta.yml
    caller-workflow-file: deploy-prod.yml
    github-token: ${{ secrets.GITHUB_TOKEN }}

- if: steps.find.outputs.should_proceed == 'true'
  run: echo "Deploy ${{ steps.find.outputs.sha }}"
```

| Input | Default | Purpose |
|---|---|---|
| `upstream-workflow-file` | `deploy-beta.yml` | |
| `caller-workflow-file` | — (required) | E.g. `deploy-prod.yml` |
| `github-token` | — (required) | |
| `branch` | `main` | |
| `fail-on-no-upstream` | `false` | When `true`, action fails if no green upstream run exists |

| Output | Purpose |
|---|---|
| `sha` | Last-green upstream SHA (empty if none) |
| `should_proceed` | `'true'` or `'false'` |
| `upstream-date` | ISO timestamp of upstream's last success |
| `caller-date` | ISO timestamp of caller's last success (or 2000-01-01 if none) |

---

## `appleboy-ssh-with-env`

Wraps `appleboy/ssh-action@v1.0.3` with TT's standard pattern: cd to
working-directory, optionally git pull / git checkout, run a server-
side script with comma-separated env-var name passthrough.

```yaml
- uses: chthonicsystems/devops-workflows/actions/appleboy-ssh-with-env@v0
  with:
    host: ${{ secrets.DO_HOST }}
    username: ${{ secrets.DO_USER }}
    ssh-key: ${{ secrets.DO_SSH_KEY }}
    envs: API_IMAGE,WEB_IMAGE,DOMAIN,DOCKERHUB_USERNAME,DOCKERHUB_TOKEN
    script-path: ./scripts/deploy-github.sh
  env:
    # The actual env-var VALUES are set on the calling JOB
    # (or step), not inside the composite. The composite just
    # passes the NAMES list to appleboy/ssh-action's `envs:` input.
    API_IMAGE: chthonicsystems/torquetech-api
    WEB_IMAGE: chthonicsystems/torquetech-web
    DOMAIN: ${{ secrets.DOMAIN }}
    DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
    DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

| Input | Default | Purpose |
|---|---|---|
| `host` | — (required) | SSH host |
| `username` | — (required) | SSH user |
| `ssh-key` | — (required) | SSH private key |
| `command-timeout` | `15m` | |
| `envs` | `''` | Comma-separated env-var NAMES to forward |
| `working-directory` | `/opt/torquetech` | Server-side cd target |
| `git-mode` | `pull` | `pull` / `checkout-sha` / `none` |
| `git-branch` | `main` | |
| `git-sha` | `''` | Required when `git-mode=checkout-sha` |
| `script-path` | — (required) | Server-side script to invoke |
| `script-args` | `''` | |
| `pre-script-commands` | `''` | Optional bash before the script |
| `post-script-commands` | `''` | Optional bash after the script |

---

## `playwright-e2e-gate`

Wait-for-API-readiness loop + `npx playwright test` + artifact upload
+ Markdown summary block. Lifted from TT's `deploy-beta.yml`
`playwright-e2e-beta` job.

```yaml
- uses: chthonicsystems/devops-workflows/actions/playwright-e2e-gate@v0
  with:
    base-url: https://torquetech-beta.chthonicsystems.com
    admin-username: ${{ secrets.E2E_ADMIN_USERNAME }}
    admin-password: ${{ secrets.E2E_ADMIN_PASSWORD }}
```

| Input | Default | Purpose |
|---|---|---|
| `base-url` | — (required) | Target env URL |
| `admin-username` / `admin-password` | — (required) | Seed admin for readiness probe + spec auth |
| `readiness-endpoint` | `/api/auth/login` | |
| `readiness-timeout-seconds` | `180` | |
| `readiness-poll-seconds` | `5` | |
| `skip-readiness` | `false` | |
| `node-version` | `22` | |
| `working-directory` | `.` | |
| `install-command` | `npm install` | |
| `browsers` | `chromium` | |
| `spec-glob` | `''` | |
| `report-name` | `playwright-report` | |
| `report-path` | `playwright-report/` | |
| `report-retention-days` | `14` | |
| `summary-title` | `🎭 E2E Test Results` | |

---

## `docker-buildx-push`

`setup-buildx` + `metadata-action` (when `metadata-tags` set) +
`build-push-action` with GHA cache.

```yaml
# Pattern A: with metadata-action tag rules (auto branch-sha + raw tags)
- uses: chthonicsystems/devops-workflows/actions/docker-buildx-push@v0
  with:
    image-name: chthonicsystems/torquetech-api
    context: ./api
    metadata-tags: |
      type=sha,prefix={{branch}}-
      type=raw,value=latest
    cache-scope: api
    registry-username: ${{ secrets.DOCKERHUB_USERNAME }}
    registry-password: ${{ secrets.DOCKERHUB_TOKEN }}

# Pattern B: with static tag list
- uses: chthonicsystems/devops-workflows/actions/docker-buildx-push@v0
  with:
    image-name: chthonicsystems/torquetech-web
    context: ./web
    tags: chthonicsystems/torquetech-web:beta
    build-args: |
      REACT_APP_API_URL=https://torquetech-beta.chthonicsystems.com
    cache-scope: web-beta
    skip-login: 'true'   # caller already logged in via earlier docker-buildx-push step
```

| Input | Default | Purpose |
|---|---|---|
| `image-name` | — (required) | Image-name without tag |
| `context` | `.` | |
| `dockerfile` | `Dockerfile` | |
| `tags` | `''` | Multiline OR comma-separated; ignored when `metadata-tags` set |
| `metadata-tags` | `''` | metadata-action tag rules; takes precedence over `tags` |
| `build-args` | `''` | Multiline KEY=VALUE |
| `platforms` | `''` | E.g. `linux/amd64,linux/arm64` |
| `push` | `true` | |
| `cache-scope` | — (required) | |
| `registry` | `docker.io` | |
| `registry-username` | `''` | |
| `registry-password` | `''` | |
| `skip-login` | `false` | When `true`, skip docker/login-action (caller already logged in) |

| Output | Purpose |
|---|---|
| `digest` | Pushed image digest |
| `imageid` | Local image id |
| `metadata-tags` | Resolved tags (when `metadata-tags` was used) |
