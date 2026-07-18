#!/bin/bash

# Primary references:
# https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
# https://sparkle-project.org/documentation/publishing/
# https://cli.github.com/manual/gh_release_create

set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT_FILE="$REPO_ROOT/ChatGPTSkinStudio.xcodeproj"
readonly PROJECT_SPEC="$REPO_ROOT/project.yml"
readonly SCHEME="ChatGPTSkinStudio"
readonly BUILT_APP_NAME="ChatGPTSkinStudio.app"
readonly DISTRIBUTED_APP_NAME="ChatGPT Skin Studio.app"
readonly APP_EXECUTABLE="ChatGPTSkinStudio"
readonly BUNDLE_ID="com.zuuzii.chatgpt-skin-studio"
readonly VOLUME_NAME="ChatGPT Skin Studio"
readonly GITHUB_REPOSITORY="zuuzii-org/chatgpt-avatar"
readonly PROJECT_URL="https://github.com/$GITHUB_REPOSITORY"
readonly SPARKLE_FEED_URL="$PROJECT_URL/releases/latest/download/appcast.xml"
readonly EXCLUDED_RELEASE_THEME="original-night-city"

COMMAND="all"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
TEAM_ID="${TEAM_ID:-H74633HDAD}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Li Lan (H74633HDAD)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ChatGPTSkinStudioNotary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-chatgpt-skin-studio}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-}"
DRY_RUN="${DRY_RUN:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
CONFIRM_PUBLISH="${CONFIRM_PUBLISH:-0}"

TAG=""
RELEASE_ROOT=""
DERIVED_DATA=""
ARCHIVE_PATH=""
WORK_DIR=""
STAGED_APP_PATH=""
ARTIFACT_DIR=""
UPDATE_DIR=""
ZIP_PATH=""
DMG_PATH=""
APPCAST_PATH=""
CHECKSUM_PATH=""
MANIFEST_PATH=""
SPARKLE_GENERATE_KEYS=""
SPARKLE_GENERATE_APPCAST=""
SPARKLE_SIGN_UPDATE=""
SPARKLE_PRIVATE_KEY_FILE=""
MOUNT_POINT=""
MOUNTED_IMAGE=""

usage() {
  cat <<'EOF'
Build, sign, notarize, package, validate, and publish ChatGPT Skin Studio.

Usage:
  scripts/release.sh [command] [options]

Commands:
  preflight       Validate the release environment without building the app
  test            Run offline Swift and JavaScript release tests
  build           Archive, stage, audit themes, and Developer ID-sign the app
  notarize-app    Notarize and staple the staged app
  package         Create the Sparkle ZIP and signed DMG
  notarize-dmg    Notarize and staple the DMG
  appcast         Generate and verify the signed Sparkle appcast
  checksum        Generate SHA256SUMS.txt
  validate        Audit all release artifacts
  publish         Create the GitHub tag and Release (requires explicit consent)
  all             Run every command except publish (default)

Options:
  --version VALUE           Marketing version (default: 0.1.0)
  --build VALUE             Bundle build number (default: 1)
  --team-id VALUE           Apple Developer Team ID
  --signing-identity VALUE  Developer ID Application identity
  --notary-profile VALUE    notarytool Keychain profile (default: ChatGPTSkinStudioNotary)
  --sparkle-account VALUE   Sparkle Ed25519 Keychain account
  --sparkle-bin-dir PATH    Sparkle bin directory override
  --notes-file PATH         Bilingual GitHub/Sparkle release notes
  --skip-notarization       Rehearsal only; publish will remain blocked
  --allow-dirty             Allowed only together with --dry-run
  --dry-run                 Print mutating actions without performing them
  --confirm-publish         Required with the publish command
  -h, --help                Show this help

Environment equivalents:
  VERSION, BUILD_NUMBER, TEAM_ID, SIGNING_IDENTITY, NOTARY_PROFILE,
  SPARKLE_ACCOUNT, SPARKLE_PUBLIC_ED_KEY, SPARKLE_BIN_DIR,
  RELEASE_NOTES_PATH, DRY_RUN, ALLOW_DIRTY, SKIP_NOTARIZATION,
  CONFIRM_PUBLISH

Security:
  The script accepts no Apple ID, app password, API private key, or Sparkle
  private key argument. Notarization uses a named Keychain profile. For
  unattended Sparkle signing, generate_keys exports the selected Keychain item
  to a mode-0600 release-workspace file that is deleted by the EXIT trap.

The release staging step intentionally removes bundled theme
Resources/Themes/original-night-city. The source fixture remains untouched.
EOF
}

log() {
  printf '[release] %s\n' "$*"
}

warn() {
  printf '[release] warning: %s\n' "$*" >&2
}

die() {
  printf '[release] error: %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

print_command() {
  printf '[release] +'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  if ! is_true "$DRY_RUN"; then
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
  if ! is_true "$DRY_RUN"; then
    [[ -f "$1" ]] || die "required file not found: $1"
  fi
}

require_directory() {
  if ! is_true "$DRY_RUN"; then
    [[ -d "$1" ]] || die "required directory not found: $1"
  fi
}

safe_remove() {
  local path="$1"
  case "$path" in
    "$RELEASE_ROOT"|"$RELEASE_ROOT"/*) run /bin/rm -rf "$path" ;;
    *) die "refusing to remove path outside release workspace: $path" ;;
  esac
}

cleanup() {
  local exit_code=$?
  if [[ -n "$MOUNTED_IMAGE" ]]; then
    /usr/bin/hdiutil detach "$MOUNTED_IMAGE" -force >/dev/null 2>&1 || true
    MOUNTED_IMAGE=""
  fi
  if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]] && [[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    case "$SPARKLE_PRIVATE_KEY_FILE" in
      "$WORK_DIR/sparkle-ed25519-private-key")
        /usr/bin/unlink "$SPARKLE_PRIVATE_KEY_FILE" || warn "failed to delete temporary Sparkle private-key file"
        ;;
      *) warn "refusing to remove unexpected Sparkle private-key path" ;;
    esac
    SPARKLE_PRIVATE_KEY_FILE=""
  fi
  exit "$exit_code"
}

trap cleanup EXIT

parse_arguments() {
  if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    COMMAND="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      --build)
        [[ $# -ge 2 ]] || die "--build requires a value"
        BUILD_NUMBER="$2"
        shift 2
        ;;
      --team-id)
        [[ $# -ge 2 ]] || die "--team-id requires a value"
        TEAM_ID="$2"
        shift 2
        ;;
      --signing-identity)
        [[ $# -ge 2 ]] || die "--signing-identity requires a value"
        SIGNING_IDENTITY="$2"
        shift 2
        ;;
      --notary-profile)
        [[ $# -ge 2 ]] || die "--notary-profile requires a value"
        NOTARY_PROFILE="$2"
        shift 2
        ;;
      --sparkle-account)
        [[ $# -ge 2 ]] || die "--sparkle-account requires a value"
        SPARKLE_ACCOUNT="$2"
        shift 2
        ;;
      --sparkle-bin-dir)
        [[ $# -ge 2 ]] || die "--sparkle-bin-dir requires a value"
        SPARKLE_BIN_DIR="$2"
        shift 2
        ;;
      --notes-file)
        [[ $# -ge 2 ]] || die "--notes-file requires a value"
        RELEASE_NOTES_PATH="$2"
        shift 2
        ;;
      --skip-notarization)
        SKIP_NOTARIZATION=1
        shift
        ;;
      --allow-dirty)
        ALLOW_DIRTY=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --confirm-publish)
        CONFIRM_PUBLISH=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

initialize_paths() {
  TAG="v$VERSION"
  RELEASE_ROOT="$REPO_ROOT/.build/release/$TAG"
  DERIVED_DATA="$RELEASE_ROOT/DerivedData"
  ARCHIVE_PATH="$RELEASE_ROOT/ChatGPTSkinStudio.xcarchive"
  WORK_DIR="$RELEASE_ROOT/work"
  STAGED_APP_PATH="$WORK_DIR/stage/$DISTRIBUTED_APP_NAME"
  ARTIFACT_DIR="$RELEASE_ROOT/artifacts"
  UPDATE_DIR="$WORK_DIR/updates"
  ZIP_PATH="$ARTIFACT_DIR/ChatGPT-Skin-Studio-$VERSION.zip"
  DMG_PATH="$ARTIFACT_DIR/ChatGPT-Skin-Studio-$VERSION.dmg"
  APPCAST_PATH="$ARTIFACT_DIR/appcast.xml"
  CHECKSUM_PATH="$ARTIFACT_DIR/SHA256SUMS.txt"
  MANIFEST_PATH="$WORK_DIR/release-manifest.plist"
  MOUNT_POINT="$WORK_DIR/mount"

  if [[ -n "$RELEASE_NOTES_PATH" ]] && [[ "$RELEASE_NOTES_PATH" != /* ]]; then
    RELEASE_NOTES_PATH="$REPO_ROOT/$RELEASE_NOTES_PATH"
  fi
  if [[ -n "$SPARKLE_BIN_DIR" ]] && [[ "$SPARKLE_BIN_DIR" != /* ]]; then
    SPARKLE_BIN_DIR="$REPO_ROOT/$SPARKLE_BIN_DIR"
  fi
}

validate_options() {
  case "$COMMAND" in
    preflight|test|build|notarize-app|package|notarize-dmg|appcast|checksum|validate|publish|all) ;;
    *) die "unsupported command: $COMMAND" ;;
  esac
  [[ "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z-]+)*$ ]] || die "invalid version: $VERSION"
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "build number must be a positive integer"
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "TEAM_ID must be 10 alphanumeric characters"
  [[ -n "$SIGNING_IDENTITY" ]] || die "signing identity cannot be empty"
  [[ -n "$NOTARY_PROFILE" ]] || die "notary profile cannot be empty"
  [[ -n "$SPARKLE_ACCOUNT" ]] || die "Sparkle account cannot be empty"
  if is_true "$ALLOW_DIRTY" && ! is_true "$DRY_RUN"; then
    die "--allow-dirty is restricted to --dry-run rehearsals"
  fi
  if [[ "$COMMAND" == "publish" ]] && is_true "$SKIP_NOTARIZATION"; then
    die "publishing an unnotarized build is forbidden"
  fi
  if [[ "$COMMAND" == "publish" ]] && ! is_true "$CONFIRM_PUBLISH"; then
    die "publish requires --confirm-publish"
  fi
  if [[ "$COMMAND" == "publish" ]] && is_true "$DRY_RUN"; then
    die "publish cannot be combined with --dry-run"
  fi
  case "$COMMAND" in
    all|appcast|publish)
      if ! is_true "$DRY_RUN" && [[ -z "$RELEASE_NOTES_PATH" ]]; then
        die "$COMMAND requires --notes-file so Sparkle and GitHub receive release notes"
      fi
      ;;
  esac
  if [[ -n "$RELEASE_NOTES_PATH" ]] && [[ ! -f "$RELEASE_NOTES_PATH" ]]; then
    die "release notes file not found: $RELEASE_NOTES_PATH"
  fi
}

require_release_tools() {
  local command
  for command in git xcodegen xcodebuild xcrun codesign security ditto hdiutil \
    spctl plutil xmllint shasum gh curl file lipo find sort comm awk sed grep node; do
    require_command "$command"
  done
}

require_clean_worktree() {
  local status
  if is_true "$ALLOW_DIRTY"; then
    warn "dirty-worktree protection is disabled for this dry run"
    return
  fi
  /usr/bin/git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 || \
    die "release requires a committed Git HEAD"
  status="$(/usr/bin/git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
  [[ -z "$status" ]] || die "Git worktree is not clean; commit intended release changes first"
}

verify_repository_identity() {
  local origin
  origin="$(/usr/bin/git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$origin" in
    git@github.com:zuuzii-org/chatgpt-avatar.git|https://github.com/zuuzii-org/chatgpt-avatar.git) ;;
    *) die "unexpected origin remote: $origin" ;;
  esac
}

verify_signing_identity() {
  local identities
  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  printf '%s\n' "$identities" | /usr/bin/grep -Fq "\"$SIGNING_IDENTITY\"" || \
    die "Developer ID signing identity is unavailable: $SIGNING_IDENTITY"
  log "validated Developer ID Application identity for Team $TEAM_ID"
}

verify_notary_profile() {
  if is_true "$SKIP_NOTARIZATION"; then
    warn "notarization is disabled; publish will remain blocked"
    return
  fi
  if is_true "$DRY_RUN"; then
    log "[dry-run] validate notarytool Keychain profile: $NOTARY_PROFILE"
    return
  fi
  /usr/bin/xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    --no-progress \
    --output-format json >/dev/null 2>&1 || \
    die "notarytool Keychain profile is unavailable or invalid: $NOTARY_PROFILE"
  log "validated notarytool Keychain profile"
}

verify_github_access() {
  local visibility
  /usr/bin/env GH_PAGER= "$(command -v gh)" auth status -h github.com >/dev/null 2>&1 || \
    die "GitHub CLI is not authenticated"
  visibility="$("$(command -v gh)" repo view "$GITHUB_REPOSITORY" --json visibility --jq .visibility)"
  [[ "$visibility" == "PUBLIC" ]] || die "GitHub repository must be public; got: $visibility"
  log "validated GitHub access to public repository $GITHUB_REPOSITORY"
}

generate_project() {
  run "$(command -v xcodegen)" generate --spec "$PROJECT_SPEC"
  require_clean_worktree
}

resolve_sparkle_tools() {
  if [[ -z "$SPARKLE_BIN_DIR" ]]; then
    SPARKLE_BIN_DIR="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
  fi
  SPARKLE_GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"
  SPARKLE_GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
  SPARKLE_SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"
  if is_true "$DRY_RUN" && [[ ! -x "$SPARKLE_GENERATE_KEYS" ]]; then
    log "[dry-run] Sparkle tools will resolve under $SPARKLE_BIN_DIR"
    return
  fi
  [[ -x "$SPARKLE_GENERATE_KEYS" ]] || die "Sparkle generate_keys tool not found: $SPARKLE_GENERATE_KEYS"
  [[ -x "$SPARKLE_GENERATE_APPCAST" ]] || die "Sparkle generate_appcast tool not found: $SPARKLE_GENERATE_APPCAST"
  [[ -x "$SPARKLE_SIGN_UPDATE" ]] || die "Sparkle sign_update tool not found: $SPARKLE_SIGN_UPDATE"
}

validate_public_sparkle_key() {
  local decoded_bytes keychain_public_key
  if is_true "$DRY_RUN" && [[ ! -x "$SPARKLE_GENERATE_KEYS" ]]; then
    log "[dry-run] read Sparkle public key from Keychain account: $SPARKLE_ACCOUNT"
    [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || SPARKLE_PUBLIC_ED_KEY="DRY_RUN_PUBLIC_KEY"
    return
  fi
  if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    SPARKLE_PUBLIC_ED_KEY="$("$SPARKLE_GENERATE_KEYS" -p --account "$SPARKLE_ACCOUNT" 2>/dev/null || true)"
  fi
  [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || \
    die "no Sparkle Ed25519 key for Keychain account '$SPARKLE_ACCOUNT'; run generate_keys once for this account"
  keychain_public_key="$("$SPARKLE_GENERATE_KEYS" -p --account "$SPARKLE_ACCOUNT" 2>/dev/null || true)"
  [[ -n "$keychain_public_key" ]] || \
    die "Sparkle private key is not available in Keychain account '$SPARKLE_ACCOUNT'"
  [[ "$keychain_public_key" == "$SPARKLE_PUBLIC_ED_KEY" ]] || \
    die "SPARKLE_PUBLIC_ED_KEY does not match Keychain account '$SPARKLE_ACCOUNT'"
  decoded_bytes="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
  [[ "$decoded_bytes" == "32" ]] || die "Sparkle public key must be base64 encoding of 32 bytes"
  log "validated Sparkle Ed25519 public key (private key remains in Keychain)"
}

prepare_sparkle_private_key_file() {
  local permissions
  resolve_sparkle_tools
  if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]] && [[ -s "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    return
  fi
  SPARKLE_PRIVATE_KEY_FILE="$WORK_DIR/sparkle-ed25519-private-key"
  if is_true "$DRY_RUN"; then
    log "[dry-run] export Sparkle Keychain item to a temporary mode-0600 signing file"
    return
  fi
  safe_remove "$SPARKLE_PRIVATE_KEY_FILE"
  /bin/mkdir -p "$WORK_DIR"
  "$SPARKLE_GENERATE_KEYS" \
    --account "$SPARKLE_ACCOUNT" \
    -x "$SPARKLE_PRIVATE_KEY_FILE" >/dev/null
  /bin/chmod 600 "$SPARKLE_PRIVATE_KEY_FILE"
  require_file "$SPARKLE_PRIVATE_KEY_FILE"
  [[ -s "$SPARKLE_PRIVATE_KEY_FILE" ]] || die "Sparkle temporary private-key export is empty"
  permissions="$(/usr/bin/stat -f '%Lp' "$SPARKLE_PRIVATE_KEY_FILE")"
  [[ "$permissions" == "600" ]] || die "Sparkle temporary private-key file permissions are $permissions; expected 600"
  log "prepared temporary Sparkle signing key file; EXIT trap will delete it"
}

resolve_packages() {
  if is_true "$DRY_RUN"; then
    log "[dry-run] resolve Swift package dependencies into $DERIVED_DATA"
    return
  fi
  /bin/mkdir -p "$RELEASE_ROOT"
  /usr/bin/xcodebuild \
    -resolvePackageDependencies \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$DERIVED_DATA"
}

run_preflight() {
  require_release_tools
  require_file "$PROJECT_FILE/project.pbxproj"
  require_file "$PROJECT_SPEC"
  validate_options
  verify_repository_identity
  require_clean_worktree
  verify_signing_identity
  verify_notary_profile
  verify_github_access
  generate_project
  resolve_packages
  resolve_sparkle_tools
  validate_public_sparkle_key
  log "preflight passed for $TAG (build $BUILD_NUMBER)"
}

run_release_tests() {
  run_preflight
  run /usr/bin/xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    test
  run "$(command -v node)" --check \
    "$REPO_ROOT/ChatGPTSkinStudio/Resources/Injected/bootstrap.js"
  run "$(command -v node)" --check \
    "$REPO_ROOT/ChatGPTSkinStudio/Resources/Injected/cleanup.js"
  run "$(command -v node)" --test \
    "$REPO_ROOT/ChatGPTSkinStudioTests/CleanupContractTests.mjs"
  log "offline release tests passed without launching ChatGPT"
}

write_release_manifest() {
  local git_head temp_manifest
  git_head="$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)"
  temp_manifest="$MANIFEST_PATH.tmp"
  run /bin/mkdir -p "$WORK_DIR"
  run /usr/bin/plutil -create xml1 "$temp_manifest"
  run /usr/bin/plutil -insert schemaVersion -integer 1 "$temp_manifest"
  run /usr/bin/plutil -insert gitHead -string "$git_head" "$temp_manifest"
  run /usr/bin/plutil -insert version -string "$VERSION" "$temp_manifest"
  run /usr/bin/plutil -insert build -string "$BUILD_NUMBER" "$temp_manifest"
  run /bin/mv "$temp_manifest" "$MANIFEST_PATH"
}

validate_release_manifest() {
  local expected_head actual_head actual_version actual_build
  require_file "$MANIFEST_PATH"
  if is_true "$DRY_RUN"; then
    return
  fi
  expected_head="$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)"
  actual_head="$(/usr/bin/plutil -extract gitHead raw -o - "$MANIFEST_PATH")"
  actual_version="$(/usr/bin/plutil -extract version raw -o - "$MANIFEST_PATH")"
  actual_build="$(/usr/bin/plutil -extract build raw -o - "$MANIFEST_PATH")"
  [[ "$actual_head" == "$expected_head" ]] || die "release artifacts were built from a different Git HEAD"
  [[ "$actual_version" == "$VERSION" ]] || die "release manifest version mismatch"
  [[ "$actual_build" == "$BUILD_NUMBER" ]] || die "release manifest build mismatch"
}

assert_safe_staged_app_path() {
  case "$STAGED_APP_PATH" in
    "$RELEASE_ROOT"/*.app|"$RELEASE_ROOT"/*/*.app|"$RELEASE_ROOT"/*/*/*.app) ;;
    *) die "unsafe staged app path: $STAGED_APP_PATH" ;;
  esac
}

remove_excluded_release_theme() {
  local match count
  local matches_file="$WORK_DIR/excluded-theme-matches.txt"
  assert_safe_staged_app_path
  require_directory "$STAGED_APP_PATH/Contents/Resources"
  if is_true "$DRY_RUN"; then
    log "[dry-run] remove only bundled theme '$EXCLUDED_RELEASE_THEME' from staged app"
    return
  fi
  /usr/bin/find "$STAGED_APP_PATH/Contents/Resources" -type d \
    -name "$EXCLUDED_RELEASE_THEME" -print >"$matches_file"
  count="$(/usr/bin/wc -l <"$matches_file" | /usr/bin/tr -d ' ')"
  [[ "$count" == "1" ]] || die "expected exactly one bundled $EXCLUDED_RELEASE_THEME theme; found $count"
  match="$(/usr/bin/sed -n '1p' "$matches_file")"
  case "$match" in
    "$STAGED_APP_PATH/Contents/Resources/"*"/$EXCLUDED_RELEASE_THEME"|\
    "$STAGED_APP_PATH/Contents/Resources/$EXCLUDED_RELEASE_THEME") ;;
    *) die "refusing to remove unexpected theme path: $match" ;;
  esac
  /bin/rm -rf "$match"
  log "removed excluded release theme: $EXCLUDED_RELEASE_THEME"
}

audit_release_themes() {
  local expected="$WORK_DIR/expected-themes.txt"
  local actual="$WORK_DIR/actual-themes.txt"
  local source_themes="$REPO_ROOT/ChatGPTSkinStudio/Resources/Themes"
  require_directory "$STAGED_APP_PATH/Contents/Resources"
  if is_true "$DRY_RUN"; then
    log "[dry-run] assert original-night-city is absent and every other source theme is present"
    return
  fi

  /usr/bin/find "$source_themes" -mindepth 2 -maxdepth 2 -type f -name theme.json \
    -print | while IFS= read -r manifest; do
      theme="$(/usr/bin/basename "$(/usr/bin/dirname "$manifest")")"
      [[ "$theme" == "$EXCLUDED_RELEASE_THEME" ]] || printf '%s\n' "$theme"
    done | /usr/bin/sort -u >"$expected"

  /usr/bin/find "$STAGED_APP_PATH/Contents/Resources" -type f -name theme.json \
    -print | while IFS= read -r manifest; do
      /usr/bin/basename "$(/usr/bin/dirname "$manifest")"
    done | /usr/bin/sort -u >"$actual"

  if /usr/bin/grep -Fxq "$EXCLUDED_RELEASE_THEME" "$actual"; then
    die "excluded theme is still present in the release app: $EXCLUDED_RELEASE_THEME"
  fi
  /usr/bin/comm -3 "$expected" "$actual" >"$WORK_DIR/theme-audit.diff"
  [[ ! -s "$WORK_DIR/theme-audit.diff" ]] || {
    /bin/cat "$WORK_DIR/theme-audit.diff" >&2
    die "release theme set does not match source themes minus $EXCLUDED_RELEASE_THEME"
  }
  [[ -s "$expected" ]] || die "release would contain no bundled themes"
  log "theme audit passed: excluded $EXCLUDED_RELEASE_THEME; retained $(/usr/bin/wc -l <"$expected" | /usr/bin/tr -d ' ') themes"
}

audit_no_private_material() {
  local forbidden="$WORK_DIR/forbidden-release-files.txt"
  if is_true "$DRY_RUN"; then
    log "[dry-run] scan staged app for private key and credential filenames"
    return
  fi
  /usr/bin/find "$STAGED_APP_PATH" -type f \
    \( -name '*.p8' -o -name '*.pem' -o -name '*.key' -o -name '.env' \
       -o -iname '*private*key*' -o -iname '*app*password*' \) -print >"$forbidden"
  [[ ! -s "$forbidden" ]] || {
    /bin/cat "$forbidden" >&2
    die "private key or credential-like file found in staged app"
  }
}

validate_app_metadata() {
  local info="$STAGED_APP_PATH/Contents/Info.plist"
  local version build bundle feed public_key executable archs icon_name minimum_system
  require_file "$info"
  if is_true "$DRY_RUN"; then
    return
  fi
  version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info")"
  build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info")"
  bundle="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info")"
  feed="$(/usr/bin/plutil -extract SUFeedURL raw -o - "$info")"
  public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$info")"
  icon_name="$(/usr/bin/plutil -extract CFBundleIconName raw -o - "$info")"
  minimum_system="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$info")"
  executable="$STAGED_APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
  [[ "$version" == "$VERSION" ]] || die "app marketing version is $version; expected $VERSION"
  [[ "$build" == "$BUILD_NUMBER" ]] || die "app build is $build; expected $BUILD_NUMBER"
  [[ "$bundle" == "$BUNDLE_ID" ]] || die "unexpected bundle identifier: $bundle"
  [[ "$feed" == "$SPARKLE_FEED_URL" ]] || die "unexpected Sparkle feed URL: $feed"
  [[ "$public_key" == "$SPARKLE_PUBLIC_ED_KEY" ]] || die "built app contains an unexpected Sparkle public key"
  [[ "$icon_name" == "AppIcon" ]] || die "release app does not declare AppIcon"
  require_file "$STAGED_APP_PATH/Contents/Resources/AppIcon.icns"
  [[ "$minimum_system" == "14.0" ]] || die "unexpected minimum macOS version: $minimum_system"
  require_file "$executable"
  archs="$(/usr/bin/lipo -archs "$executable")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || \
    die "release executable must be universal (arm64 + x86_64); got: $archs"
}

validate_app_signature() {
  local entitlements
  local sparkle_framework="$STAGED_APP_PATH/Contents/Frameworks/Sparkle.framework"
  require_directory "$STAGED_APP_PATH"
  if is_true "$DRY_RUN"; then
    log "[dry-run] verify strict nested code signatures, Team ID, hardened runtime, and timestamp"
    return
  fi
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH"
  validate_developer_id_component "$sparkle_framework/Versions/B/XPCServices/Installer.xpc" "Sparkle Installer.xpc"
  validate_developer_id_component "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc" "Sparkle Downloader.xpc"
  validate_developer_id_component "$sparkle_framework/Versions/B/Autoupdate" "Sparkle Autoupdate"
  validate_developer_id_component "$sparkle_framework/Versions/B/Updater.app" "Sparkle Updater.app"
  validate_developer_id_component "$sparkle_framework" "Sparkle.framework"
  validate_developer_id_component "$STAGED_APP_PATH" "release app"
  entitlements="$(/usr/bin/codesign -d --entitlements :- "$STAGED_APP_PATH" 2>&1 || true)"
  if [[ "$entitlements" == *"com.apple.security.get-task-allow"* ]] && \
     [[ "$entitlements" == *"<true/>"* ]]; then
    die "release app contains com.apple.security.get-task-allow=true"
  fi
}

validate_developer_id_component() {
  local component="$1"
  local label="$2"
  local signature_info
  [[ -e "$component" ]] || die "$label is missing: $component"
  /usr/bin/codesign --verify --strict --verbose=2 "$component"
  signature_info="$(/usr/bin/codesign -d --verbose=4 "$component" 2>&1)"
  [[ "$signature_info" == *"Authority=Developer ID Application:"* ]] || \
    die "$label is not signed with Developer ID Application"
  [[ "$signature_info" == *"TeamIdentifier=$TEAM_ID"* ]] || die "$label signature Team ID mismatch"
  [[ "$signature_info" == *"Runtime Version="* ]] || die "$label signature is missing hardened runtime"
  [[ "$signature_info" == *"Timestamp="* ]] || die "$label signature is missing a secure timestamp"
}

resign_staged_app() {
  local sparkle_framework="$STAGED_APP_PATH/Contents/Frameworks/Sparkle.framework"
  require_directory "$sparkle_framework"

  # Sparkle's SPM artifact intentionally ships its helpers ad-hoc signed. An
  # alternative distribution workflow must re-sign them inside-out before the
  # framework and host app. Do not use --deep: Downloader.xpc may carry its own
  # entitlements. See https://sparkle-project.org/documentation/sandboxing/.
  run /usr/bin/codesign --force \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --sign "$SIGNING_IDENTITY" \
    "$sparkle_framework/Versions/B/XPCServices/Installer.xpc"
  run /usr/bin/codesign --force \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --preserve-metadata=entitlements \
    --sign "$SIGNING_IDENTITY" \
    "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
  run /usr/bin/codesign --force \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --sign "$SIGNING_IDENTITY" \
    "$sparkle_framework/Versions/B/Autoupdate"
  run /usr/bin/codesign --force \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --sign "$SIGNING_IDENTITY" \
    "$sparkle_framework/Versions/B/Updater.app"
  run /usr/bin/codesign --force \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --sign "$SIGNING_IDENTITY" \
    "$sparkle_framework"
  run /usr/bin/codesign --force \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --sign "$SIGNING_IDENTITY" \
    "$STAGED_APP_PATH"
}

build_release_app() {
  local archived_app="$ARCHIVE_PATH/Products/Applications/$BUILT_APP_NAME"
  run_preflight
  safe_remove "$ARCHIVE_PATH"
  safe_remove "$DERIVED_DATA/Build"
  safe_remove "$WORK_DIR"
  safe_remove "$ARTIFACT_DIR"
  run /bin/mkdir -p "$WORK_DIR/stage" "$ARTIFACT_DIR"
  run /usr/bin/xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$ARCHIVE_PATH" \
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
    archive
  require_directory "$archived_app"
  run /usr/bin/ditto --rsrc --extattr "$archived_app" "$STAGED_APP_PATH"
  remove_excluded_release_theme
  audit_release_themes
  audit_no_private_material
  resign_staged_app
  validate_app_metadata
  validate_app_signature
  write_release_manifest
  log "signed release app ready: $STAGED_APP_PATH"
}

json_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

notarize_with_wait() {
  local artifact="$1"
  local label="$2"
  local result="$WORK_DIR/notary-$label.json"
  local submission_id status
  if is_true "$SKIP_NOTARIZATION"; then
    warn "skipped $label notarization"
    return
  fi
  require_file "$artifact"
  if is_true "$DRY_RUN"; then
    log "[dry-run] notarize $artifact with Keychain profile $NOTARY_PROFILE and wait up to 45 minutes"
    return
  fi
  /usr/bin/xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout 45m \
    --no-progress \
    --output-format json >"$result"
  submission_id="$(json_value "$result" id)"
  status="$(json_value "$result" status)"
  [[ "$status" == "Accepted" ]] || {
    if [[ -n "$submission_id" ]]; then
      /usr/bin/xcrun notarytool log "$submission_id" \
        --keychain-profile "$NOTARY_PROFILE" \
        --output-format json >"$WORK_DIR/notary-$label-log.json" 2>/dev/null || true
    fi
    die "$label notarization failed with status: ${status:-unknown}; inspect $result"
  }
  log "$label notarization accepted (submission $submission_id)"
}

notarize_release_app() {
  local submission_zip="$WORK_DIR/notary-app.zip"
  require_clean_worktree
  validate_release_manifest
  validate_app_metadata
  audit_release_themes
  validate_app_signature
  safe_remove "$submission_zip"
  run /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP_PATH" "$submission_zip"
  notarize_with_wait "$submission_zip" app
  if ! is_true "$SKIP_NOTARIZATION"; then
    run /usr/bin/xcrun stapler staple -v "$STAGED_APP_PATH"
    run /usr/bin/xcrun stapler validate -v "$STAGED_APP_PATH"
    run /usr/sbin/spctl --assess --type execute --verbose=4 "$STAGED_APP_PATH"
  fi
  validate_app_signature
  log "release app notarization stage complete"
}

create_sparkle_zip() {
  require_directory "$STAGED_APP_PATH"
  safe_remove "$ZIP_PATH"
  run /bin/mkdir -p "$ARTIFACT_DIR"
  run /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP_PATH" "$ZIP_PATH"
  log "created Sparkle ZIP: $ZIP_PATH"
}

validate_dmg_signature() {
  local signature_info
  require_file "$DMG_PATH"
  if is_true "$DRY_RUN"; then
    return
  fi
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
  signature_info="$(/usr/bin/codesign -d --verbose=4 "$DMG_PATH" 2>&1)"
  [[ "$signature_info" == *"Authority=Developer ID Application:"* ]] || \
    die "DMG is not signed with Developer ID Application"
  [[ "$signature_info" == *"Timestamp="* ]] || die "DMG signature is missing a secure timestamp"
}

create_signed_dmg() {
  local dmg_source="$WORK_DIR/dmg-source"
  require_directory "$STAGED_APP_PATH"
  safe_remove "$dmg_source"
  safe_remove "$DMG_PATH"
  run /bin/mkdir -p "$dmg_source" "$ARTIFACT_DIR"
  run /usr/bin/ditto --rsrc --extattr "$STAGED_APP_PATH" "$dmg_source/$DISTRIBUTED_APP_NAME"
  run /bin/ln -s /Applications "$dmg_source/Applications"
  run /usr/bin/hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$dmg_source" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"
  run /usr/bin/codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
  validate_dmg_signature
  log "created signed DMG: $DMG_PATH"
}

package_release_artifacts() {
  require_clean_worktree
  validate_release_manifest
  audit_release_themes
  validate_app_signature
  if ! is_true "$SKIP_NOTARIZATION"; then
    run /usr/bin/xcrun stapler validate -v "$STAGED_APP_PATH"
  fi
  create_sparkle_zip
  create_signed_dmg
}

notarize_release_dmg() {
  require_clean_worktree
  validate_release_manifest
  validate_dmg_signature
  notarize_with_wait "$DMG_PATH" dmg
  if ! is_true "$SKIP_NOTARIZATION"; then
    run /usr/bin/xcrun stapler staple -v "$DMG_PATH"
    run /usr/bin/xcrun stapler validate -v "$DMG_PATH"
    run /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  fi
  validate_dmg_signature
  log "DMG notarization stage complete"
}

generate_appcast() {
  local notes_copy=""
  local download_prefix="$PROJECT_URL/releases/download/$TAG/"
  require_clean_worktree
  validate_release_manifest
  require_file "$ZIP_PATH"
  resolve_sparkle_tools
  validate_public_sparkle_key
  prepare_sparkle_private_key_file
  safe_remove "$UPDATE_DIR"
  safe_remove "$APPCAST_PATH"
  run /bin/mkdir -p "$UPDATE_DIR" "$ARTIFACT_DIR"
  run /bin/cp "$ZIP_PATH" "$UPDATE_DIR/$(/usr/bin/basename "$ZIP_PATH")"
  if [[ -n "$RELEASE_NOTES_PATH" ]]; then
    notes_copy="$UPDATE_DIR/ChatGPT-Skin-Studio-$VERSION.md"
    run /bin/cp "$RELEASE_NOTES_PATH" "$notes_copy"
  fi
  run "$SPARKLE_GENERATE_APPCAST" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    --download-url-prefix "$download_prefix" \
    --link "$PROJECT_URL" \
    --embed-release-notes \
    --maximum-versions 10 \
    -o "$APPCAST_PATH" \
    "$UPDATE_DIR"
  validate_appcast
  log "generated signed Sparkle appcast: $APPCAST_PATH"
}

validate_appcast() {
  local signature enclosure_url feed_version
  require_file "$APPCAST_PATH"
  require_file "$ZIP_PATH"
  if is_true "$DRY_RUN"; then
    return
  fi
  prepare_sparkle_private_key_file
  /usr/bin/xmllint --noout "$APPCAST_PATH"
  signature="$(/usr/bin/xmllint --xpath \
    'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
    "$APPCAST_PATH")"
  enclosure_url="$(/usr/bin/xmllint --xpath \
    'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
  feed_version="$(/usr/bin/xmllint --xpath \
    'string(//*[local-name()="item"]/*[local-name()="version"])' "$APPCAST_PATH")"
  [[ -n "$signature" ]] || die "appcast is missing Sparkle Ed25519 signature"
  [[ "$enclosure_url" == "$PROJECT_URL/releases/download/$TAG/$(/usr/bin/basename "$ZIP_PATH")" ]] || \
    die "unexpected appcast enclosure URL: $enclosure_url"
  [[ "$feed_version" == "$BUILD_NUMBER" ]] || die "appcast build version mismatch: $feed_version"
  "$SPARKLE_SIGN_UPDATE" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    --verify \
    "$ZIP_PATH" \
    "$signature"
  log "verified appcast XML, URL, build, and Ed25519 archive signature"
}

generate_checksums() {
  require_file "$ZIP_PATH"
  require_file "$DMG_PATH"
  require_file "$APPCAST_PATH"
  if is_true "$DRY_RUN"; then
    log "[dry-run] write SHA-256 checksums to $CHECKSUM_PATH"
    return
  fi
  (
    cd "$ARTIFACT_DIR"
    /usr/bin/shasum -a 256 \
      "$(/usr/bin/basename "$ZIP_PATH")" \
      "$(/usr/bin/basename "$DMG_PATH")" \
      "$(/usr/bin/basename "$APPCAST_PATH")" >"$(/usr/bin/basename "$CHECKSUM_PATH")"
  )
  log "generated checksums: $CHECKSUM_PATH"
}

validate_zip_contents() {
  local extract_root="$WORK_DIR/validate-zip"
  local extracted_app="$extract_root/$DISTRIBUTED_APP_NAME"
  safe_remove "$extract_root"
  run /bin/mkdir -p "$extract_root"
  run /usr/bin/ditto -x -k "$ZIP_PATH" "$extract_root"
  if ! is_true "$DRY_RUN"; then
    [[ -d "$extracted_app" ]] || die "Sparkle ZIP does not contain $DISTRIBUTED_APP_NAME"
    STAGED_APP_PATH="$extracted_app"
    audit_release_themes
    validate_app_metadata
    validate_app_signature
    if ! is_true "$SKIP_NOTARIZATION"; then
      /usr/bin/xcrun stapler validate -v "$STAGED_APP_PATH"
      /usr/sbin/spctl --assess --type execute --verbose=4 "$STAGED_APP_PATH"
    fi
  fi
}

validate_dmg_contents() {
  local mounted_app
  safe_remove "$MOUNT_POINT"
  run /bin/mkdir -p "$MOUNT_POINT"
  if is_true "$DRY_RUN"; then
    log "[dry-run] mount DMG read-only and audit the contained app"
    return
  fi
  /usr/bin/hdiutil attach "$DMG_PATH" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" >/dev/null
  MOUNTED_IMAGE="$MOUNT_POINT"
  mounted_app="$MOUNT_POINT/$DISTRIBUTED_APP_NAME"
  [[ -d "$mounted_app" ]] || die "DMG does not contain $DISTRIBUTED_APP_NAME"
  STAGED_APP_PATH="$mounted_app"
  audit_release_themes
  validate_app_metadata
  validate_app_signature
  if ! is_true "$SKIP_NOTARIZATION"; then
    /usr/sbin/spctl --assess --type execute --verbose=4 "$STAGED_APP_PATH"
  fi
  /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
  MOUNTED_IMAGE=""
}

validate_checksums() {
  require_file "$CHECKSUM_PATH"
  if is_true "$DRY_RUN"; then
    return
  fi
  (
    cd "$ARTIFACT_DIR"
    /usr/bin/shasum -a 256 -c "$(/usr/bin/basename "$CHECKSUM_PATH")"
  )
}

validate_release_artifacts() {
  local original_staged_app="$STAGED_APP_PATH"
  require_clean_worktree
  validate_release_manifest
  require_file "$ZIP_PATH"
  require_file "$DMG_PATH"
  require_file "$APPCAST_PATH"
  validate_dmg_signature
  if ! is_true "$SKIP_NOTARIZATION"; then
    run /usr/bin/xcrun stapler validate -v "$DMG_PATH"
    run /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  fi
  resolve_sparkle_tools
  validate_public_sparkle_key
  validate_appcast
  validate_checksums
  validate_zip_contents
  STAGED_APP_PATH="$original_staged_app"
  validate_dmg_contents
  STAGED_APP_PATH="$original_staged_app"
  log "release artifact validation passed"
}

verify_remote_release_assets() {
  local expected name missing=0
  local assets_file="$WORK_DIR/remote-assets.txt"
  "$(command -v gh)" release view "$TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --json assets \
    --jq '.assets[].name' | /usr/bin/sort >"$assets_file"
  for expected in "$ZIP_PATH" "$DMG_PATH" "$APPCAST_PATH" "$CHECKSUM_PATH"; do
    name="$(/usr/bin/basename "$expected")"
    if ! /usr/bin/grep -Fxq "$name" "$assets_file"; then
      warn "remote Release is missing asset: $name"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "remote GitHub Release asset verification failed"
}

publish_github_release() {
  local head remote_head release_url published_tag_head
  is_true "$CONFIRM_PUBLISH" || die "publish requires --confirm-publish"
  is_true "$DRY_RUN" && die "publish cannot be combined with --dry-run"
  ! is_true "$SKIP_NOTARIZATION" || die "publishing an unnotarized build is forbidden"
  [[ -n "$RELEASE_NOTES_PATH" ]] || die "publish requires --notes-file with bilingual release notes"
  require_clean_worktree
  validate_release_artifacts
  /usr/bin/git -C "$REPO_ROOT" fetch origin main --tags --quiet
  head="$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)"
  remote_head="$(/usr/bin/git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"
  [[ "$head" == "$remote_head" ]] || die "local HEAD is not the pushed origin/main commit"
  ! /usr/bin/git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || \
    die "local tag already exists: $TAG"
  [[ -z "$(/usr/bin/git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/$TAG")" ]] || \
    die "remote tag already exists: $TAG"
  ! "$(command -v gh)" release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || \
    die "GitHub Release already exists: $TAG"

  # This is deliberately a normal Latest release, even though the title says
  # Public Beta. GitHub's /releases/latest URL excludes prereleases, and that
  # stable URL is the Sparkle feed endpoint embedded in the app.
  "$(command -v gh)" release create "$TAG" \
    "$ZIP_PATH#Sparkle automatic update archive" \
    "$DMG_PATH#macOS installer" \
    "$APPCAST_PATH#Sparkle update feed" \
    "$CHECKSUM_PATH#SHA-256 checksums" \
    --repo "$GITHUB_REPOSITORY" \
    --target "$head" \
    --title "ChatGPT Skin Studio $VERSION Public Beta" \
    --notes-file "$RELEASE_NOTES_PATH" \
    --latest

  release_url="$("$(command -v gh)" release view "$TAG" --repo "$GITHUB_REPOSITORY" --json url --jq .url)"
  verify_remote_release_assets
  /usr/bin/git -C "$REPO_ROOT" fetch origin "refs/tags/$TAG:refs/tags/$TAG" --quiet
  published_tag_head="$(/usr/bin/git -C "$REPO_ROOT" rev-list -n 1 "$TAG")"
  [[ "$published_tag_head" == "$head" ]] || die "published tag does not point to the release Git HEAD"
  /usr/bin/curl -fsSL "$SPARKLE_FEED_URL" | /usr/bin/xmllint --noout -
  log "published and remotely verified: $release_url"
}

run_all_without_publish() {
  run_release_tests
  build_release_app
  if ! is_true "$SKIP_NOTARIZATION"; then
    notarize_release_app
  fi
  package_release_artifacts
  if ! is_true "$SKIP_NOTARIZATION"; then
    notarize_release_dmg
  fi
  generate_appcast
  generate_checksums
  validate_release_artifacts
  log "release is ready for an explicit publish command"
}

main() {
  parse_arguments "$@"
  initialize_paths
  validate_options
  case "$COMMAND" in
    preflight) run_preflight ;;
    test) run_release_tests ;;
    build) build_release_app ;;
    notarize-app) run_preflight; notarize_release_app ;;
    package) run_preflight; package_release_artifacts ;;
    notarize-dmg) run_preflight; notarize_release_dmg ;;
    appcast) run_preflight; generate_appcast ;;
    checksum) run_preflight; generate_checksums ;;
    validate) run_preflight; validate_release_artifacts ;;
    publish) run_preflight; publish_github_release ;;
    all) run_all_without_publish ;;
  esac
}

main "$@"
