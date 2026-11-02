#!/bin/bash
# Lays out the archive service inside an app, with the worker it starts for each read, and signs both inside out:
# scripts/build.sh does it for Strata.app, and the archive tests for the app they read through. Each signature must then
# carry exactly the entitlements given (none when none is given: the tests show each part refusing to read without
# them), or this fails.
#
#   scripts/archive-service.sh APP PRODUCTS [--identifier ID] [--service-entitlements FILE]
#                              [--worker-entitlements FILE] -- CODESIGN_OPTIONS...
#
# PRODUCTS holds the built StrataArchiveService and StrataArchiveWorker. The service takes the app's version when it has
# one, and the identifier in Sources/StrataArchiveService/Info.plist unless given another (an empty one keeps it).
set -euo pipefail

app=$1 products=$2
shift 2
if [[ "$app" != *.app || ! -d "$app" ]]; then echo "$app isn't an app bundle." >&2; exit 2; fi
identifier="" service_entitlements="" worker_entitlements=""
while [[ $# -gt 0 && "$1" != "--" ]]; do
  case "$1" in
    --identifier) identifier=$2 ;;
    --service-entitlements) service_entitlements=$2 ;;
    --worker-entitlements) worker_entitlements=$2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
if [[ "${1:-}" == "--" ]]; then shift; fi
sign=("$@")
if [[ ${#sign[@]} -eq 0 ]]; then echo "Pass the codesign options after --." >&2; exit 2; fi

sources="$(cd "$(dirname "$0")/.." && pwd)/Sources"
service="$app/Contents/XPCServices/StrataArchiveService.xpc"
worker="$service/Contents/Helpers/StrataArchiveWorker"
plist=/usr/libexec/PlistBuddy

rm -rf "$service"
mkdir -p "$service/Contents/MacOS" "$service/Contents/Helpers"
cp "$products/StrataArchiveService" "$service/Contents/MacOS/StrataArchiveService"
cp "$products/StrataArchiveWorker" "$worker"
cp "$sources/StrataArchiveService/Info.plist" "$service/Contents/Info.plist"
if [[ -n "$identifier" ]]; then "$plist" -c "Set :CFBundleIdentifier $identifier" "$service/Contents/Info.plist"; fi
for key in CFBundleShortVersionString CFBundleVersion; do
  if value=$("$plist" -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null); then
    "$plist" -c "Add :$key string $value" "$service/Contents/Info.plist"
  fi
done

sign_with() {
  local entitlements=$1 code=$2 options=("${sign[@]}")
  if [[ -n "$entitlements" ]]; then options+=(--entitlements "$entitlements"); fi
  codesign "${options[@]}" "$code" >/dev/null
  if ! python3 -I -c 'import plistlib, subprocess, sys
signed = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", sys.argv[1]], capture_output=True, check=True)
expected = plistlib.loads(open(sys.argv[2], "rb").read()) if sys.argv[2] else None
sys.exit(0 if (plistlib.loads(signed.stdout) if signed.stdout else None) == expected else 1)' "$code" "$entitlements"; then
    echo "$code isn't signed with exactly ${entitlements:-no entitlements}." >&2
    exit 1
  fi
}
sign_with "$worker_entitlements" "$worker"
sign_with "$service_entitlements" "$service"
