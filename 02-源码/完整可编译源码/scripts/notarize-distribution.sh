#!/bin/zsh
set -euo pipefail

DMG="${1:-}"
IDENTITY="${AUTOREPLY_SIGNING_IDENTITY:--}"
PROFILE="${AUTOREPLY_NOTARY_PROFILE:-}"

[[ "$IDENTITY" != "-" ]] || { print -u2 -- "NOTARIZATION_SKIPPED_ADHOC"; exit 2; }
[[ -n "$PROFILE" ]] || { print -u2 -- "缺少 AUTOREPLY_NOTARY_PROFILE"; exit 2; }
[[ -s "$DMG" ]] || { print -u2 -- "DMG 不存在：$DMG"; exit 2; }

codesign --verify --strict --verbose=2 "$DMG"
result=$(mktemp "${TMPDIR%/}/qianniu-notary.XXXXXX.json")
cleanup() { rm -f -- "$result"; }
trap cleanup EXIT
xcrun notarytool submit "$DMG" --wait --keychain-profile "$PROFILE" \
  --output-format json > "$result"
status=$(/usr/bin/python3 - "$result" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", ""))
PY
)
[[ "$status" == "Accepted" ]] || { print -u2 -- "NOTARIZATION_REJECTED=$status"; exit 1; }
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
print -- "NOTARIZATION_ACCEPTED=1"
