# Local / emergency deploy runbook

When **GitHub Actions is unavailable** (spending-limit hit, outage) you can build
and deploy TorqueTech from a laptop with `scripts/local-deploy.sh`. It reproduces
the reusable deploy workflow natively.

## Why amd64 matters

The DigitalOcean droplets are **linux/amd64**. A Docker image built on Apple
Silicon defaults to **arm64**, and pushing it clobbers the shared tag so the
droplet's `docker pull` fails with:

```
no matching manifest for linux/amd64 in the manifest list entries
```

The reusable build steps now **pin `platforms: linux/amd64`** (see
`actions/docker-buildx-push`'s `platforms` input, set in `deploy-beta.yml` and
`deploy-prod.yml`). `local-deploy.sh` also builds with `--platform linux/amd64`.
This makes builds deterministic regardless of host — including under `act`.

## Tag convention

| Env  | Domain                                | Web tag pulled by deploy |
|------|---------------------------------------|--------------------------|
| beta | torquetech-beta.chthonicsystems.com   | `web:beta`               |
| prod | torquetech.chthonicsystems.com        | `web:latest` (+ `web:main-<sha>`) |

Beta and prod share `api:latest` and `backup:latest`. Only rebuild the API image
when `api/` actually changed; frontend releases are web-only.

## Usage

Local deploys read the consolidated inventory directly from
`~/chthonicsystems/secrets.yaml` (override with `--secrets-yaml`). The scripts map
only the required values into a short-lived mode-`0600` env file and remove it on
exit. They never shell-source the YAML and never copy the full inventory to a
droplet. CI remains separate: GitHub Actions uses GitHub Environment secrets and
never reads this local file.

```bash
# Full beta deploy: api + web, EF migrations, beta provider credentials.
scripts/local-deploy.sh \
  --env beta \
  --repo ~/chthonicsystems/torquetech \
  --component all

# Full prod deploy: accounting preflight, api + web, migrations, backup enabled.
scripts/local-deploy.sh \
  --env prod \
  --repo ~/chthonicsystems/torquetech \
  --component all \
  --ref origin/main

# Frontend-only fast path: surgical web swap; api/mysql untouched.
scripts/local-deploy.sh --env beta --repo ~/chthonicsystems/torquetech

# Preview any path with no build, push, deploy, or store submission.
scripts/local-deploy.sh \
  --env prod \
  --repo ~/chthonicsystems/torquetech \
  --component all \
  --dry-run

# Entire release chain: beta(api+web) -> full suite -> prod(api+web) -> mobile.
scripts/local-pipeline.sh --repo ~/chthonicsystems/torquetech --dry-run
```

`--component web` (default) performs the surgical web-only swap. `--component
api|all` builds the linux/amd64 API image and always runs the full staged
deployment (`mysql -> api/migrations -> web`). On prod it also runs the same
accounting/data-protection preflight as CI.

## Recovering the public web build args

The Firebase/OAuth values are compiled into the served bundle, so you can recover
them from a running web container instead of GitHub secrets:

```bash
ssh -i ~/chthonicsystems/.ssh/id_rsa root@<droplet> \
  "docker exec torquetech-web-1 sh -c 'cat /usr/share/nginx/html/static/js/main.*.js'" \
  | grep -oE '(apiKey|authDomain|appId|messagingSenderId|storageBucket):"[^"]+"'
```

## Notes

- SSH: key is used as an identity (`ssh -i`); never embed the private key.
- `act` can drive these workflows locally, but its build produces images for the
  host arch — the `platforms: linux/amd64` pin above is what makes that safe.
- Keep `~/chthonicsystems/secrets.yaml` mode `0600`; never commit it, `.act/secrets`,
  generated mapped env files, or private keys.
