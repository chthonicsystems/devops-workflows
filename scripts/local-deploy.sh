#!/usr/bin/env bash
#
# local-deploy.sh -- emergency "deploy from a laptop" runbook for TorqueTech,
# for when GitHub Actions is unavailable (e.g. spending-limit hit).
#
# It reproduces what the reusable deploy workflow does, natively:
#   1. buildx --platform linux/amd64 build + push of the web image from a ref
#      (amd64 is REQUIRED: the DO droplets are linux/amd64; an arm64 image built
#       on Apple Silicon cannot be pulled by the droplet -> "no matching manifest
#       for linux/amd64"). This is why the reusable workflow now pins platforms.
#   2. Deploy on the droplet: surgical web-container swap (default) or the full
#      ./scripts/deploy-github.sh (down/up).
#
# Secrets are NEVER embedded. You supply a --secrets-file (KEY=VALUE, git-ignored).
# The SSH key is used as an identity (-i), never read into the script.
#
# API image: unchanged frontend releases don't need it. If the API changed,
# rebuild+push chthonicsystems/torquetech-api:latest for linux/amd64 separately
# (dotnet publish -r linux-x64 + buildx of the runtime Dockerfile) or run CI.
#
# Usage:
#   ./local-deploy.sh --env beta  --repo /path/to/torquetech --secrets-file ./deploy.secrets
#   ./local-deploy.sh --env prod  --repo /path/to/torquetech --secrets-file ./deploy.secrets --ref origin/main
#
# Required secrets-file keys (public web build args + tokens):
#   GITHUB_PACKAGES_PAT DOCKERHUB_USERNAME DOCKERHUB_TOKEN
#   REACT_APP_GOOGLE_CLIENT_ID REACT_APP_MICROSOFT_CLIENT_ID REACT_APP_APPLE_CLIENT_ID
#   REACT_APP_FIREBASE_API_KEY REACT_APP_FIREBASE_AUTH_DOMAIN REACT_APP_FIREBASE_PROJECT_ID
#   REACT_APP_FIREBASE_STORAGE_BUCKET REACT_APP_FIREBASE_MESSAGING_SENDER_ID
#   REACT_APP_FIREBASE_APP_ID [REACT_APP_FIREBASE_VAPID_KEY]
set -euo pipefail

ENV="" REF="origin/main" REPO="" SECRETS="" MODE="surgical" SSH_KEY="${HOME}/chthonicsystems/.ssh/id_rsa" COMPONENT="web"
while [ $# -gt 0 ]; do case "$1" in
  --env) ENV="$2"; shift 2;;
  --ref) REF="$2"; shift 2;;
  --repo) REPO="$2"; shift 2;;
  --secrets-file) SECRETS="$2"; shift 2;;
  --mode) MODE="$2"; shift 2;;          # surgical | full
  --ssh-key) SSH_KEY="$2"; shift 2;;
  --component) COMPONENT="$2"; shift 2;; # web (default)
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

die(){ echo "ERROR: $*" >&2; exit 1; }
[ -n "$ENV" ] || die "--env beta|prod required"
[ -n "$REPO" ] || die "--repo <torquetech checkout> required"
[ -n "$SECRETS" ] || die "--secrets-file required"
[ -f "$SECRETS" ] || die "secrets file not found: $SECRETS"
[ "$COMPONENT" = "web" ] || die "only --component web is supported (see header for api guidance)"

case "$ENV" in
  beta) HOST=165.22.52.106; DOMAIN=torquetech-beta.chthonicsystems.com; WEB_TAG=beta;   COMPOSE="-f docker-compose.yml -f docker-compose.prod.override.yml -f docker-compose.beta.override.yml";;
  prod) HOST=167.172.75.139; DOMAIN=torquetech.chthonicsystems.com;      WEB_TAG=latest; COMPOSE="-f docker-compose.yml -f docker-compose.prod.override.yml";;
  *) die "--env must be beta or prod";;
esac
IMG=chthonicsystems/torquetech-web
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
load_secrets "$SECRETS"

WT="$(mktemp -d /tmp/tt-localdeploy.XXXX)"
cleanup(){ git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"; }
trap cleanup EXIT
git -C "$REPO" fetch origin -q
git -C "$REPO" worktree add -f "$WT" "$REF" >/dev/null
SHA="$(git -C "$WT" rev-parse --short HEAD)"
VER="$(python3 -c "import json;print(json.load(open('$WT/web/app_version.json'))['latest'])")"
echo ">> env=$ENV host=$HOST sha=$SHA version=$VER tag=$IMG:$WEB_TAG mode=$MODE"

# --- build + push amd64 web ---
printf '%s' "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin >/dev/null
docker buildx inspect ttlocal >/dev/null 2>&1 || docker buildx create --name ttlocal --driver docker-container >/dev/null
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

# --- deploy on droplet ---
if [ "$MODE" = surgical ]; then
  # swap only the web container; api/mysql untouched, no down/up.
  $SSH "cd /opt/torquetech && docker pull $IMG:$WEB_TAG && docker tag $IMG:$WEB_TAG $IMG:latest && docker compose $COMPOSE up -d --no-deps --force-recreate web"
else
  # full deploy-github.sh (down/up); requires runtime secrets exported server-side.
  $SSH "cd /opt/torquetech && git pull origin main && WEB_IMAGE_TAG=$WEB_TAG SKIP_BACKUP=$([ "$ENV" = beta ] && echo true || echo false) ./scripts/deploy-github.sh"
fi

# --- verify ---
code=$(curl -k -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/")
echo ">> https://$DOMAIN/ -> $code ; deployed web $VER ($SHA) to $ENV"
[ "$code" = 200 ] || die "site did not return 200"
echo ">> OK"
