#!/usr/bin/env bash
#
# local-pipeline.sh — run the full TorqueTech release pipeline locally, on-demand,
# mirroring the daily CI chain WITHOUT using GitHub Actions minutes.
#
# Stages (each gated on the previous — a failure stops the pipeline):
#   1. beta    — build + deploy web to beta (native linux/amd64) via local-deploy.sh
#   2. test    — run the FULL Playwright suite against beta (the gate; stop on failure)
#   3. prod    — build + deploy web to prod via local-deploy.sh
#   4. android — web build + cap sync + `fastlane android internal` (AAB → Play Store) + S3 mirror
#   5. ios     — web build + cap sync + `fastlane ios beta` (TestFlight) + `fastlane ios release`
#
# This is the "release from a laptop" companion to local-deploy.sh. It does REAL
# deploys and store submissions — treat it like a production release.
#
# Usage:
#   ./local-pipeline.sh --repo ~/chthonicsystems/torquetech --secrets-file ./pipeline.secrets \
#       [--ref origin/main] [--only beta|test|prod|android|ios] [--skip-mobile] [--skip-prod] [--dry-run]
#
# secrets-file (KEY=VALUE, git-ignored) — superset of local-deploy.sh keys, plus:
#   Android: KEYSTORE_PATH KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD
#            FIREBASE_SERVICE_ACCOUNT_JSON (Google Play API key JSON, full content)
#            AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_S3_BUCKET_ANDROID
#   iOS:     APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH
#            MATCH_PASSWORD
#            IOS_SIGNING_P12_PATH IOS_SIGNING_P12_PASSWORD  (macOS: seeds the signing identity into a
#                                                            temp keychain because `security import`
#                                                            rejects match's empty-password p12)
#   Public OAuth build args have committed defaults in web/scripts/native-build.sh, so are optional.
#
set -euo pipefail

# ---- args ----------------------------------------------------------------
REPO="" SECRETS="" REF="origin/main" ONLY="" SKIP_MOBILE=0 SKIP_PROD=0 DRY=0
BETA_HOST="torquetech-beta.chthonicsystems.com"
PROD_URL="https://torquetech.chthonicsystems.com"
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;;
  --secrets-file) SECRETS="$2"; shift 2;;
  --ref) REF="$2"; shift 2;;
  --only) ONLY="$2"; shift 2;;
  --skip-mobile) SKIP_MOBILE=1; shift;;
  --skip-prod) SKIP_PROD=1; shift;;
  --dry-run) DRY=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$REPO" ] || { echo "--repo is required" >&2; exit 2; }
[ -n "$SECRETS" ] && [ -f "$SECRETS" ] || { echo "--secrets-file <file> is required and must exist" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH"

run() { echo "+ $*"; [ "$DRY" = 1 ] && return 0; "$@"; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
log() { printf '\n\033[36m==== %s ====\033[0m\n' "$*"; }

# ---- 1. beta deploy ------------------------------------------------------
if want beta; then
  log "STAGE 1/5 — deploy web to BETA (native amd64)"
  run "$SCRIPT_DIR/local-deploy.sh" --env beta --repo "$REPO" --secrets-file "$SECRETS" --ref "$REF"
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
  log "STAGE 3/5 — deploy web to PROD (native amd64)"
  run "$SCRIPT_DIR/local-deploy.sh" --env prod --repo "$REPO" --secrets-file "$SECRETS" --ref "$REF"
fi

# Mobile stages load the secrets-file into the environment for fastlane.
# Parse literally (no shell-sourcing) so values with $, spaces, quotes, () are safe.
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
mobile_env() { load_secrets "$SECRETS"; }

# ---- 4. Android — AAB → Play Store + S3 ----------------------------------
if want android && [ "$SKIP_MOBILE" = 0 ]; then
  log "STAGE 4/5 — Android: build + Play Store + S3"
  mobile_env
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
  mobile_env
  # macOS: seed the distribution identity into a dedicated keychain, because
  # `security import` rejects match's empty-password p12 on recent macOS. match
  # then finds the identity already present and gym signs with it.
  if [ -n "${IOS_SIGNING_P12_PATH:-}" ]; then
    KC=/tmp/tt-pipeline-signing.keychain-db
    run security delete-keychain "$KC" 2>/dev/null || true
    run security create-keychain -p tt "$KC"
    run security set-keychain-settings -lut 7200 "$KC"
    run security unlock-keychain -p tt "$KC"
    run security import "$IOS_SIGNING_P12_PATH" -k "$KC" -P "${IOS_SIGNING_P12_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security
    run security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k tt "$KC" >/dev/null 2>&1 || true
    # keep the login keychain in the search list (git creds + WWDR chain) alongside ours
    run security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC"
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
