#!/usr/bin/env bash
#
# local-pipeline.sh — run the full TorqueTech release pipeline locally, on-demand,
# mirroring the daily CI chain WITHOUT using GitHub Actions minutes.
#
# Stages (each gated on the previous — a failure stops the pipeline):
#   1. beta    — build + deploy api+web to beta (native linux/amd64, migrations)
#   2. test    — run the FULL Playwright suite against beta (the gate; stop on failure)
#   3. prod    — run prod preflight, then build + deploy api+web (migrations)
#   4. android — web build + cap sync + `fastlane android internal` (AAB → Play Store) + S3 mirror
#   5. ios     — web build + cap sync + `fastlane ios beta` (TestFlight) + `fastlane ios release`
#
# This is the "release from a laptop" companion to local-deploy.sh. It does REAL
# deploys and store submissions — treat it like a production release.
#
# Usage (secrets.yaml defaults to ~/chthonicsystems/secrets.yaml):
#   ./local-pipeline.sh --repo ~/chthonicsystems/torquetech \
#       [--secrets-yaml /path/to/secrets.yaml] [--ref origin/main] \
#       [--only beta|test|prod|android|ios] [--skip-mobile] [--skip-prod] [--dry-run]
#
# secrets.yaml is the sole local secret source. scripts/secrets-yaml-to-env.rb
# maps the required deploy/mobile values into a short-lived 0600 env file which
# is parsed literally and deleted on exit. CI continues to use GitHub Environment
# secrets and never reads this local inventory.
#
set -euo pipefail

# ---- args ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="" SECRETS_YAML="${HOME}/chthonicsystems/secrets.yaml" REF="origin/main" ONLY="" SKIP_MOBILE=0 SKIP_PROD=0 DRY=0
BETA_HOST="torquetech-beta.chthonicsystems.com"
PROD_URL="https://torquetech.chthonicsystems.com"
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;;
  --secrets-yaml) SECRETS_YAML="$2"; shift 2;;
  --ref) REF="$2"; shift 2;;
  --only) ONLY="$2"; shift 2;;
  --skip-mobile) SKIP_MOBILE=1; shift;;
  --skip-prod) SKIP_PROD=1; shift;;
  --dry-run) DRY=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$REPO" ] || { echo "--repo is required" >&2; exit 2; }
[ -f "$SECRETS_YAML" ] || { echo "secrets YAML not found: $SECRETS_YAML" >&2; exit 2; }
[ -f "$SCRIPT_DIR/secrets-yaml-to-env.rb" ] || { echo "secrets adapter not found" >&2; exit 2; }
export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH"

SECRETS="$(mktemp "${TMPDIR:-/tmp}/tt-local-pipeline-secrets.XXXXXX")"
chmod 600 "$SECRETS"
KC="" KC_CREATED=0
ORIGINAL_KEYCHAINS=()
cleanup() {
  if [ "$KC_CREATED" = 1 ] && [ -n "$KC" ]; then
    if [ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]; then
      security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    fi
    security delete-keychain "$KC" >/dev/null 2>&1 || true
  fi
  rm -f "$SECRETS"
}
trap cleanup EXIT
ruby "$SCRIPT_DIR/secrets-yaml-to-env.rb" "$SECRETS_YAML" "$SECRETS"

# Load the mapped env once, before any stage. Parse literally (no shell-sourcing)
# so values with $, spaces, quotes, and parentheses are safe.
load_secrets() {
  local file="$1" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
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

run() { echo "+ $*"; [ "$DRY" = 1 ] && return 0; "$@"; }
run_secret() { local label="$1"; shift; echo "+ $label [secret arguments redacted]"; [ "$DRY" = 1 ] && return 0; "$@"; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
log() { printf '\n\033[36m==== %s ====\033[0m\n' "$*"; }

# ---- 1. beta deploy ------------------------------------------------------
if want beta; then
  log "STAGE 1/5 — deploy api+web to BETA (native amd64 + migrations)"
  run "$SCRIPT_DIR/local-deploy.sh" --env beta --repo "$REPO" --secrets-yaml "$SECRETS_YAML" --ref "$REF" --component all
fi

# ---- 2. full Playwright suite against beta (GATE) ------------------------
if want test; then
  log "STAGE 2/5 — FULL Playwright suite against beta (gate)"
  ( cd "$REPO"
    [ -d node_modules ] || run npm ci
    # The repo's playwright config reads the target URL from PLAYWRIGHT_BASE_URL / BASE_URL.
    run env PLAYWRIGHT_BASE_URL="https://$BETA_HOST" BASE_URL="https://$BETA_HOST" \
        npx playwright test )
  echo "Playwright suite passed — beta is green."
fi

# ---- 3. prod deploy ------------------------------------------------------
if want prod && [ "$SKIP_PROD" = 0 ]; then
  log "STAGE 3/5 — prod preflight + deploy api+web (native amd64 + migrations)"
  run "$SCRIPT_DIR/local-deploy.sh" --env prod --repo "$REPO" --secrets-yaml "$SECRETS_YAML" --ref "$REF" --component all
fi

# The mapped environment is already loaded before Stage 1, so deploy, test, and
# mobile stages all use the same credentials and release metadata.

# ---- 4. Android — AAB → Play Store + S3 ----------------------------------
if want android && [ "$SKIP_MOBILE" = 0 ]; then
  log "STAGE 4/5 — Android: build + Play Store + S3"
  ( cd "$REPO/web"
    export REACT_APP_API_URL="$PROD_URL" NODE_ENV=production
    export REACT_APP_VERSION="$(node -e 'const d=require("./app_version.json");console.log(d.latest)')"
    run npm ci --include=dev
    run ./node_modules/.bin/ionic build
    run ./node_modules/.bin/cap sync android )
  ( cd "$REPO" && run bundle exec fastlane android internal )
  # S3 mirror (fastlane lane already uploads to Play Store; mirror the signed AAB too)
  AAB="$REPO/web/android/app/build/outputs/bundle/release/app-release.aab"
  VER="$(node -e "const d=require('$REPO/web/app_version.json');console.log(d.latest)")"
  if [ -n "${AWS_S3_BUCKET_ANDROID:-}" ] && [ -f "$AAB" ]; then
    run aws s3 cp "$AAB" "s3://${AWS_S3_BUCKET_ANDROID}/v${VER}/release.aab" --content-type application/octet-stream
    run aws s3 cp "$AAB" "s3://${AWS_S3_BUCKET_ANDROID}/LATEST/release.aab" --content-type application/octet-stream
  fi
fi

# ---- 5. iOS — TestFlight + App Store review ------------------------------
if want ios && [ "$SKIP_MOBILE" = 0 ]; then
  log "STAGE 5/5 — iOS: TestFlight (beta) + App Store review (release)"
  # macOS: seed the distribution identity into a dedicated keychain, because
  # `security import` rejects match's empty-password p12 on recent macOS. match
  # then finds the identity already present and gym signs with it.
  if [ -n "${IOS_SIGNING_P12_PATH:-}" ]; then
    KC="${TMPDIR:-/tmp}/tt-pipeline-signing.keychain-db"
    if [ "$DRY" != 1 ]; then
      while IFS= read -r keychain; do
        keychain="${keychain#\"}"; keychain="${keychain%\"}"
        [ -z "$keychain" ] || [ "$keychain" = "$KC" ] || ORIGINAL_KEYCHAINS+=("$keychain")
      done < <(security list-keychains -d user | sed 's/^[[:space:]]*//')
    fi
    run security delete-keychain "$KC" 2>/dev/null || true
    run security create-keychain -p tt "$KC"
    [ "$DRY" = 1 ] || KC_CREATED=1
    run security set-keychain-settings -lut 7200 "$KC"
    run security unlock-keychain -p tt "$KC"
    run_secret "security import $IOS_SIGNING_P12_PATH" security import "$IOS_SIGNING_P12_PATH" -k "$KC" -P "${IOS_SIGNING_P12_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security
    run security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k tt "$KC" >/dev/null 2>&1 || true
    # Preserve every original search-list entry and append only our temporary keychain.
    if [ "$DRY" = 1 ]; then
      run security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC"
    else
      run security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KC"
    fi
    export MATCH_KEYCHAIN_NAME="$KC" MATCH_KEYCHAIN_PASSWORD=tt
    export MATCH_GIT_BASIC_AUTHORIZATION="$(printf 'x-access-token:%s' "$(gh auth token)" | base64 | tr -d '\n')"
  fi
  ( cd "$REPO/web"
    export REACT_APP_API_URL="$PROD_URL" NODE_ENV=production
    export REACT_APP_VERSION="$(node -e 'const d=require("./app_version.json");console.log(d.latest)')"
    run npm ci --include=dev
    run ./node_modules/.bin/ionic build
    run ./node_modules/.bin/cap sync ios
    # SPM identity-collision workaround for @capacitor-firebase/app-check
    run ln -sf "$(pwd)/node_modules/@capacitor-firebase/app-check" \
               "$(pwd)/node_modules/@capacitor-firebase/capacitor-firebase-app-check"
    run sed -i '' 's|@capacitor-firebase/app-check"|@capacitor-firebase/capacitor-firebase-app-check"|' \
        ios/App/CapApp-SPM/Package.swift || true
    run npx --package=@chthonicsystems/devops-scripts version-sync sync-version --platform ios || true )
  ( cd "$REPO" && run bundle exec fastlane ios beta && run bundle exec fastlane ios release )
fi

log "local pipeline complete."
