#!/usr/bin/env bash
#
# local-deploy.sh -- emergency "deploy from a laptop" runbook for TorqueTech,
# for when GitHub Actions is unavailable (e.g. spending-limit hit).
#
# It reproduces what the reusable deploy workflow does, natively:
#   1. buildx --platform linux/amd64 build + push of the web and/or api images
#      from a ref (amd64 is REQUIRED: the DO droplets are linux/amd64; an arm64
#      image built on Apple Silicon cannot be pulled by the droplet -> "no
#      matching manifest for linux/amd64"). This is why the reusable workflow
#      pins platforms.
#   2. Deploy on the droplet, by --component:
#        web  (default) -> surgical web-container swap (fast; api/db untouched,
#                          NO migrations). Good for frontend-only releases.
#        api | all      -> full ./scripts/deploy-github.sh: staged bring-up
#                          mysql -> api (runs EF migrations, RUN_MIGRATIONS=true)
#                          -> web, with the COMPLETE runtime-secret env mapped
#                          from ~/chthonicsystems/secrets.yaml. This is full parity
#                          with CI's deploy job (build api+web -> deploy-github.sh).
#
# Local secrets come directly from the consolidated secrets.yaml inventory. The
# script maps only the required keys into a short-lived 0600 env file, parses it
# literally (no shell-sourcing), sends it to the droplet only for full deploys,
# and deletes it afterward. CI does NOT read secrets.yaml; CI continues to use
# GitHub Environment secrets. The SSH key is used as an identity (-i) only.
#
# The api image is built from api/Dockerfile -- a self-contained multi-stage
# build (dotnet SDK restore+publish -> aspnet runtime), producing the same
# runtime image CI ships. Building .NET under linux/amd64 emulation on Apple
# Silicon is slow (qemu); expect several minutes.
#
# Usage (secrets.yaml defaults to ~/chthonicsystems/secrets.yaml):
#   # fast web-only (default):
#   ./local-deploy.sh --env beta --repo /path/to/torquetech
#   # full api+web parity (rebuilds api, runs migrations):
#   ./local-deploy.sh --env beta --repo /path/to/torquetech --component all
#   # api only, alternate inventory path:
#   ./local-deploy.sh --env prod --repo ... --secrets-yaml /path/to/secrets.yaml --component api --ref origin/main
#   # preview, no side effects:
#   ./local-deploy.sh --env beta --repo ... --component all --dry-run
#
# Required secrets.yaml mappings are maintained by scripts/secrets-yaml-to-env.rb:
#   web build args (component web|all):
#     GITHUB_PACKAGES_PAT DOCKERHUB_USERNAME DOCKERHUB_TOKEN
#     REACT_APP_GOOGLE_CLIENT_ID REACT_APP_MICROSOFT_CLIENT_ID REACT_APP_APPLE_CLIENT_ID
#     REACT_APP_FIREBASE_API_KEY REACT_APP_FIREBASE_AUTH_DOMAIN REACT_APP_FIREBASE_PROJECT_ID
#     REACT_APP_FIREBASE_STORAGE_BUCKET REACT_APP_FIREBASE_MESSAGING_SENDER_ID
#     REACT_APP_FIREBASE_APP_ID [REACT_APP_FIREBASE_VAPID_KEY]
#   api build args (component api|all):
#     GITHUB_USERNAME GITHUB_PACKAGES_PAT
#   full-deploy runtime secrets (component api|all -- exported into deploy-github.sh):
#     MYSQL_ROOT_PASSWORD MYSQL_PASSWORD JWT_SECRET             (boot-critical)
#     FIREBASE_SERVICE_ACCOUNT_JSON
#     AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY [AWS_SESSION_TOKEN] AWS_REGION S3_BACKUP_BUCKET
#     AWS_BEDROCK_ACCESS_KEY_ID AWS_BEDROCK_SECRET_ACCESS_KEY
#     STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET [STRIPE_CONNECT_WEBHOOK_SECRET]
#     TWILIO_AUTH_TOKEN
#     XERO_CLIENT_ID XERO_CLIENT_SECRET XERO_WEBHOOK_KEY
#     QB_CLIENT_ID QB_CLIENT_SECRET QB_WEBHOOK_VERIFIER_TOKEN
#     Provider base keys above are production values. For beta, supply overrides:
#       STRIPE_SECRET_KEY_BETA STRIPE_WEBHOOK_SECRET_BETA STRIPE_CONNECT_WEBHOOK_SECRET_BETA
#       XERO_CLIENT_ID_BETA XERO_CLIENT_SECRET_BETA XERO_WEBHOOK_KEY_BETA
#       QB_CLIENT_ID_BETA QB_CLIENT_SECRET_BETA QB_WEBHOOK_VERIFIER_TOKEN_BETA
#     GOOGLE_PLACES_API_KEY GH_SUPPORT_TOKEN
#   (any missing optional feature secret just leaves that feature unconfigured;
#    only the boot-critical trio is enforced.)
#   prod preflight (component/env prod, enforced only when set):
#     ACCOUNTING_LAUNCH=true  -> runs CI's validate-accounting-production gate
#       (prod Xero/QB secrets present, QuickBooks on the production Intuit
#        endpoint, redirect/frontend URLs == prod origin, /app/keys is a
#        persistent named volume). Advisory no-op when unset/!=true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="" REF="origin/main" REPO="" SECRETS_YAML="${HOME}/chthonicsystems/secrets.yaml" MODE="surgical" SSH_KEY="${HOME}/chthonicsystems/.ssh/id_rsa" COMPONENT="web" DRYRUN=false
while [ $# -gt 0 ]; do case "$1" in
  --env) ENV="$2"; shift 2;;
  --ref) REF="$2"; shift 2;;
  --repo) REPO="$2"; shift 2;;
  --secrets-yaml) SECRETS_YAML="$2"; shift 2;;
  --mode) MODE="$2"; shift 2;;          # surgical | full (web only; api/all force full)
  --ssh-key) SSH_KEY="$2"; shift 2;;
  --component) COMPONENT="$2"; shift 2;; # web (default) | api | all
  --dry-run) DRYRUN=true; shift;;        # print planned actions, no side effects
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

die(){ echo "ERROR: $*" >&2; exit 1; }
[ -n "$ENV" ] || die "--env beta|prod required"
[ -n "$REPO" ] || die "--repo <torquetech checkout> required"
[ -f "$SECRETS_YAML" ] || die "secrets YAML not found: $SECRETS_YAML"
[ -f "$SCRIPT_DIR/secrets-yaml-to-env.rb" ] || die "secrets adapter not found: $SCRIPT_DIR/secrets-yaml-to-env.rb"
case "$COMPONENT" in web|api|all) ;; *) die "--component must be web, api, or all";; esac

case "$ENV" in
  beta) HOST=165.22.52.106; DOMAIN=torquetech-beta.chthonicsystems.com; WEB_TAG=beta;   COMPOSE="-f docker-compose.yml -f docker-compose.prod.override.yml -f docker-compose.beta.override.yml";;
  prod) HOST=167.172.75.139; DOMAIN=torquetech.chthonicsystems.com;      WEB_TAG=latest; COMPOSE="-f docker-compose.yml -f docker-compose.prod.override.yml";;
  *) die "--env must be beta or prod";;
esac
IMG=chthonicsystems/torquetech-web
API_IMG=chthonicsystems/torquetech-api
BACKUP_IMG=chthonicsystems/torquetech-backup
SSH="ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=20 root@$HOST"

# Load the KEY=VALUE secrets file WITHOUT shell-sourcing it. Values are taken literally
# (no $-expansion, command substitution, or word splitting), so secrets containing $,
# spaces, parentheses, quotes, backticks, etc. are safe. One optional pair of surrounding
# single or double quotes is stripped; the value is otherwise verbatim to end of line.
load_secrets() {
  local file="$1" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"          # ltrim
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"             # rtrim key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [ "${#val}" -ge 2 ] && [ "${val:0:1}" = "'" ] && [ "${val: -1}" = "'" ]; then
      val="${val:1:${#val}-2}"
    elif [ "${#val}" -ge 2 ] && [ "${val:0:1}" = '"' ] && [ "${val: -1}" = '"' ]; then
      val="${val:1:${#val}-2}"
    fi
    export "$key=$val"
  done < "$file"
}

SECRETS="" MAPPED_SECRETS="" WT="" REMOTE_TMP=""
cleanup() {
  if [ -n "$WT" ]; then
    git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
  fi
  [ -z "$REMOTE_TMP" ] || rm -f "$REMOTE_TMP"
  [ -z "$MAPPED_SECRETS" ] || rm -f "$MAPPED_SECRETS"
}
trap cleanup EXIT

MAPPED_SECRETS="$(mktemp "${TMPDIR:-/tmp}/tt-local-secrets.XXXXXX")"
chmod 600 "$MAPPED_SECRETS"
ruby "$SCRIPT_DIR/secrets-yaml-to-env.rb" "$SECRETS_YAML" "$MAPPED_SECRETS"
SECRETS="$MAPPED_SECRETS"
load_secrets "$SECRETS"

# Prod-only preflight, mirroring CI's validate-accounting-production gate in
# deploy-prod.yml. Enforced only when ACCOUNTING_LAUNCH=true (set it in the
# secrets.yaml or environment); advisory no-op otherwise, exactly like CI's
# pre-launch behaviour. Read-only (docker compose config needs no daemon), so it
# also runs under --dry-run. Checks: prod Xero/QB secrets present; QuickBooks
# points at the production Intuit endpoint; redirect/frontend URLs match the prod
# origin; and the /app/keys data-protection volume is a persistent named volume.
preflight_prod_accounting() {
  local origin="https://$DOMAIN" safe_config field missing=""
  if [ "${ACCOUNTING_LAUNCH:-}" != "true" ]; then
    echo ">> [preflight] ACCOUNTING_LAUNCH!=true -- skipping production Accounting enforcement (advisory)"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || die "prod preflight needs jq (brew install jq)"
  for name in XERO_CLIENT_ID XERO_CLIENT_SECRET XERO_WEBHOOK_KEY \
              QB_CLIENT_ID QB_CLIENT_SECRET QB_WEBHOOK_VERIFIER_TOKEN; do
    [ -n "${!name:-}" ] || missing="$missing $name"
  done
  [ -z "$missing" ] || die "prod preflight: missing production Accounting secrets in $SECRETS_YAML:$missing"
  safe_config="$(docker compose -f "$WT/docker-compose.yml" -f "$WT/docker-compose.prod.override.yml" config --format json 2>/dev/null \
    | jq -c '{
        qbApiBaseUrl: .services.api.environment.QB_API_BASE_URL,
        redirectBaseUrl: .services.api.environment.ACCOUNTING_REDIRECT_BASE_URL,
        frontendUrl: .services.api.environment.FRONTEND_URL,
        keyVolumeCount: ([.services.api.volumes[] | select(.type == "volume" and .target == "/app/keys")] | length)
      }')"
  [ "$(jq -r '.qbApiBaseUrl' <<<"$safe_config")" = "https://quickbooks.api.intuit.com" ] \
    || die "prod preflight: QuickBooks API host is not the production endpoint"
  for field in redirectBaseUrl frontendUrl; do
    [ "$(jq -r --arg f "$field" '.[$f]' <<<"$safe_config")" = "$origin" ] \
      || die "prod preflight: production $field does not match $origin"
  done
  [ "$(jq -r '.keyVolumeCount' <<<"$safe_config")" = "1" ] \
    || die "prod preflight: production data-protection key volume is not persistent"
  echo ">> [preflight] production Accounting + data-protection key-volume checks passed"
}

WT="$(mktemp -d "${TMPDIR:-/tmp}/tt-localdeploy.XXXXXX")"
git -C "$REPO" fetch origin -q
git -C "$REPO" worktree add -f "$WT" "$REF" >/dev/null
SHA="$(git -C "$WT" rev-parse --short HEAD)"
VER="$(python3 -c "import json;print(json.load(open('$WT/web/app_version.json'))['latest'])")"
echo ">> env=$ENV host=$HOST sha=$SHA version=$VER component=$COMPONENT mode=$MODE"

# --- plan: what to build, and whether to run the full staged deploy ---
build_web=false; build_api=false
case "$COMPONENT" in
  web) build_web=true;;
  api) build_api=true;;
  all) build_web=true; build_api=true;;
esac
# api/all always use the full staged deploy (api recreate + EF migrations);
# only a web-only surgical run takes the fast swap path.
FULL_DEPLOY=true
[ "$COMPONENT" = web ] && [ "$MODE" = surgical ] && FULL_DEPLOY=false

# validate the keys each path needs before doing any work.
if [ "$build_api" = true ]; then
  [ -n "${GITHUB_USERNAME:-}" ] || die "--component $COMPONENT needs GITHUB_USERNAME in $SECRETS_YAML (GitHub login for the private @chthonic NuGet restore)"
  [ -n "${GITHUB_PACKAGES_PAT:-}" ] || die "--component $COMPONENT needs GITHUB_PACKAGES_PAT in $SECRETS_YAML"
fi
if [ "$FULL_DEPLOY" = true ]; then
  miss=""
  for k in MYSQL_ROOT_PASSWORD MYSQL_PASSWORD JWT_SECRET DOCKERHUB_USERNAME DOCKERHUB_TOKEN; do
    [ -n "${!k:-}" ] || miss="$miss $k"
  done
  [ -z "$miss" ] || die "full deploy (--component $COMPONENT) needs runtime secrets in $SECRETS_YAML; missing:$miss"
fi

SKIP_BACKUP=$([ "$ENV" = beta ] && echo true || echo false)

# prod parity: run CI's validate-accounting-production gate before any prod
# deploy (read-only; runs in dry-run too).
[ "$ENV" = prod ] && preflight_prod_accounting

if [ "$DRYRUN" = true ]; then
  echo ">> [dry-run] build_web=$build_web build_api=$build_api full_deploy=$FULL_DEPLOY skip_backup=$SKIP_BACKUP"
  [ "$build_web" = true ] && echo ">> [dry-run] buildx web -> $IMG:$WEB_TAG$([ "$ENV" = prod ] && echo " + $IMG:main-$SHA") (linux/amd64) --push"
  [ "$build_api" = true ] && echo ">> [dry-run] buildx api -> $API_IMG:latest$([ "$ENV" = prod ] && echo " + $API_IMG:main-$SHA") (linux/amd64, api/Dockerfile) --push"
  if [ "$FULL_DEPLOY" = true ]; then
    echo ">> [dry-run] map $SECRETS_YAML -> ephemeral 0600 env; scp mapped subset -> root@$HOST:/tmp/tt-pipe.env"
    echo ">> [dry-run] remote: git pull origin main; load_secrets; export API/WEB/BACKUP_IMAGE + DOMAIN + RUN_MIGRATIONS=true + SKIP_BACKUP=$SKIP_BACKUP; ./scripts/deploy-github.sh; shred secrets"
  else
    echo ">> [dry-run] surgical: docker compose $COMPOSE up -d --no-deps --force-recreate web on $HOST"
  fi
  echo ">> [dry-run] OK"
  exit 0
fi

# --- docker login + amd64 builder ---
printf '%s' "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin >/dev/null
docker buildx inspect ttlocal >/dev/null 2>&1 || docker buildx create --name ttlocal --driver docker-container >/dev/null

# --- build + push amd64 web ---
if [ "$build_web" = true ]; then
  TAGS=(-t "$IMG:$WEB_TAG"); [ "$ENV" = prod ] && TAGS+=(-t "$IMG:main-$SHA")
  docker buildx build --builder ttlocal --platform linux/amd64 -f "$WT/web/Dockerfile" \
    --build-arg GITHUB_PACKAGES_PAT="${GITHUB_PACKAGES_PAT}" \
    --build-arg REACT_APP_VERSION="$VER" \
    --build-arg REACT_APP_API_URL="https://$DOMAIN" \
    --build-arg REACT_APP_ENV=production \
    --build-arg REACT_APP_GOOGLE_CLIENT_ID="${REACT_APP_GOOGLE_CLIENT_ID:-}" \
    --build-arg REACT_APP_MICROSOFT_CLIENT_ID="${REACT_APP_MICROSOFT_CLIENT_ID:-}" \
    --build-arg REACT_APP_APPLE_CLIENT_ID="${REACT_APP_APPLE_CLIENT_ID:-}" \
    --build-arg REACT_APP_FIREBASE_API_KEY="${REACT_APP_FIREBASE_API_KEY:-}" \
    --build-arg REACT_APP_FIREBASE_AUTH_DOMAIN="${REACT_APP_FIREBASE_AUTH_DOMAIN:-}" \
    --build-arg REACT_APP_FIREBASE_PROJECT_ID="${REACT_APP_FIREBASE_PROJECT_ID:-}" \
    --build-arg REACT_APP_FIREBASE_STORAGE_BUCKET="${REACT_APP_FIREBASE_STORAGE_BUCKET:-}" \
    --build-arg REACT_APP_FIREBASE_MESSAGING_SENDER_ID="${REACT_APP_FIREBASE_MESSAGING_SENDER_ID:-}" \
    --build-arg REACT_APP_FIREBASE_APP_ID="${REACT_APP_FIREBASE_APP_ID:-}" \
    --build-arg REACT_APP_FIREBASE_VAPID_KEY="${REACT_APP_FIREBASE_VAPID_KEY:-}" \
    "${TAGS[@]}" --push "$WT/web"
fi

# --- build + push amd64 api (self-contained multi-stage api/Dockerfile) ---
if [ "$build_api" = true ]; then
  API_TAGS=(-t "$API_IMG:latest"); [ "$ENV" = prod ] && API_TAGS+=(-t "$API_IMG:main-$SHA")
  docker buildx build --builder ttlocal --platform linux/amd64 -f "$WT/api/Dockerfile" \
    --build-arg GITHUB_USERNAME="${GITHUB_USERNAME}" \
    --build-arg GITHUB_PACKAGES_PAT="${GITHUB_PACKAGES_PAT}" \
    "${API_TAGS[@]}" --push "$WT/api"
fi

# --- deploy on droplet ---
if [ "$FULL_DEPLOY" != true ]; then
  # surgical: swap only the web container; api/mysql untouched, no migrations.
  $SSH "cd /opt/torquetech && docker pull $IMG:$WEB_TAG && docker tag $IMG:$WEB_TAG $IMG:latest && docker compose $COMPOSE up -d --no-deps --force-recreate web"
else
  # full parity: inject the COMPLETE runtime-secret env and run the staged deploy
  # (mysql -> api[EF migrations via RUN_MIGRATIONS=true] -> web), exactly like
  # CI's deploy job. Secrets are copied as a 0600 file and parsed literally on the
  # droplet with the same no-shell-source loader -- never placed on a command line.
  scp -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 "$SECRETS" "root@$HOST:/tmp/tt-pipe.env" >/dev/null
  REMOTE_TMP="$(mktemp "${TMPDIR:-/tmp}/tt-remote-deploy.XXXXXX.sh")"
  cat > "$REMOTE_TMP" <<REMOTE_EOF
set -e
umask 077
cd /opt/torquetech
git pull origin main -q
load_secrets() {
  local file="\$1" line key val
  while IFS= read -r line || [ -n "\$line" ]; do
    line="\${line#"\${line%%[![:space:]]*}"}"
    [ -z "\$line" ] && continue
    case "\$line" in '#'*) continue ;; *=*) ;; *) continue ;; esac
    key="\${line%%=*}"; val="\${line#*=}"
    key="\${key%"\${key##*[![:space:]]}"}"
    [[ "\$key" =~ ^[A-Za-z_][A-Za-z0-9_]*\$ ]] || continue
    if [ "\${#val}" -ge 2 ] && [ "\${val:0:1}" = "'" ] && [ "\${val: -1}" = "'" ]; then
      val="\${val:1:\${#val}-2}"
    elif [ "\${#val}" -ge 2 ] && [ "\${val:0:1}" = '"' ] && [ "\${val: -1}" = '"' ]; then
      val="\${val:1:\${#val}-2}"
    fi
    export "\$key=\$val"
  done < "\$file"
}
load_secrets /tmp/tt-pipe.env
# A single local secrets file serves both environments. Base provider keys are
# production values; beta-only overrides mirror CI's environment-scoped secrets
# without ever injecting production Stripe/Xero/QB credentials into beta.
if [ "$ENV" = beta ]; then
  export STRIPE_SECRET_KEY="\${STRIPE_SECRET_KEY_BETA:-\${STRIPE_SECRET_KEY:-}}"
  export STRIPE_WEBHOOK_SECRET="\${STRIPE_WEBHOOK_SECRET_BETA:-\${STRIPE_WEBHOOK_SECRET:-}}"
  export STRIPE_CONNECT_WEBHOOK_SECRET="\${STRIPE_CONNECT_WEBHOOK_SECRET_BETA:-\${STRIPE_CONNECT_WEBHOOK_SECRET:-}}"
  export XERO_CLIENT_ID="\${XERO_CLIENT_ID_BETA:-\${XERO_CLIENT_ID:-}}"
  export XERO_CLIENT_SECRET="\${XERO_CLIENT_SECRET_BETA:-\${XERO_CLIENT_SECRET:-}}"
  export XERO_WEBHOOK_KEY="\${XERO_WEBHOOK_KEY_BETA:-\${XERO_WEBHOOK_KEY:-}}"
  export QB_CLIENT_ID="\${QB_CLIENT_ID_BETA:-\${QB_CLIENT_ID:-}}"
  export QB_CLIENT_SECRET="\${QB_CLIENT_SECRET_BETA:-\${QB_CLIENT_SECRET:-}}"
  export QB_WEBHOOK_VERIFIER_TOKEN="\${QB_WEBHOOK_VERIFIER_TOKEN_BETA:-\${QB_WEBHOOK_VERIFIER_TOKEN:-}}"
fi
export API_IMAGE="$API_IMG" WEB_IMAGE="$IMG" BACKUP_IMAGE="$BACKUP_IMG"
export DOMAIN="$DOMAIN" WEB_IMAGE_TAG="$WEB_TAG" RUN_MIGRATIONS=true SKIP_BACKUP="$SKIP_BACKUP"
./scripts/deploy-github.sh
rc=\$?
shred -u /tmp/tt-pipe.env 2>/dev/null || rm -f /tmp/tt-pipe.env
exit \$rc
REMOTE_EOF
  # shellcheck disable=SC2086
  $SSH 'bash -s' < "$REMOTE_TMP"
fi

# --- verify ---
code=$(curl -k -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/")
echo ">> https://$DOMAIN/ -> $code ; deployed [$COMPONENT] $VER ($SHA) to $ENV"
[ "$code" = 200 ] || die "site did not return 200"
if [ "$FULL_DEPLOY" = true ]; then
  acode=$(curl -k -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/api/health")
  echo ">> https://$DOMAIN/api/health -> $acode"
fi
echo ">> OK"
