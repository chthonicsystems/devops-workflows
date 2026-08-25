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

```bash
# secrets file (KEY=VALUE, git-ignored) with public web build args + tokens
cat > deploy.secrets <<'EOF'
GITHUB_PACKAGES_PAT=...
DOCKERHUB_USERNAME=chthonicsystems
DOCKERHUB_TOKEN=...
REACT_APP_GOOGLE_CLIENT_ID=...
REACT_APP_MICROSOFT_CLIENT_ID=...
REACT_APP_APPLE_CLIENT_ID=...
REACT_APP_FIREBASE_API_KEY=...
REACT_APP_FIREBASE_AUTH_DOMAIN=...
REACT_APP_FIREBASE_PROJECT_ID=...
REACT_APP_FIREBASE_STORAGE_BUCKET=...
REACT_APP_FIREBASE_MESSAGING_SENDER_ID=...
REACT_APP_FIREBASE_APP_ID=...
EOF

# beta (surgical web swap; api/mysql untouched, no down/up)
scripts/local-deploy.sh --env beta --repo ~/chthonicsystems/torquetech --secrets-file ./deploy.secrets

# prod (from origin/main HEAD)
scripts/local-deploy.sh --env prod --repo ~/chthonicsystems/torquetech --secrets-file ./deploy.secrets --ref origin/main
```

`--mode full` runs the droplet's `./scripts/deploy-github.sh` (full `down`/`up`,
needs runtime secrets present server-side). Default `--mode surgical` recreates
only the `web` container — the safe path for frontend-only releases.

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
- Never commit `deploy.secrets`, `.act/secrets`, or any private key.
