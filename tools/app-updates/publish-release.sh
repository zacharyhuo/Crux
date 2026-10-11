#!/bin/bash
set -euo pipefail

# Invoked only from the protected main signing job after candidate validation,
# SDK checksum verification and environment approval. Never executes app code.
test "${GITHUB_REF}" = refs/heads/main
case "${CHANNEL}" in
  beta) app_name='Crux Beta'; prefix=Crux-Beta ;;
  stable) app_name=Crux; prefix=Crux ;;
  *) exit 1 ;;
esac
key_file="$RUNNER_TEMP/crux-sparkle-key.txt"
certificate="$RUNNER_TEMP/crux-developer-id.p12"
notary_key="$RUNNER_TEMP/crux-notary-key.p8"
keychain="$RUNNER_TEMP/crux-release.keychain-db"
test ! -e "$key_file"
test ! -e "$certificate"
test ! -e "$notary_key"
test ! -e "$keychain"
cleanup() {
  rm -f -- "$key_file" "$certificate" "$notary_key"
  if [ -f "$keychain" ]; then security delete-keychain "$keychain"; fi
}
trap cleanup EXIT
umask 077
test -n "${SPARKLE_PRIVATE_KEY:-}"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key_file"
unset SPARKLE_PRIVATE_KEY
app="$RUNNER_TEMP/Crux-verified/Crux.xcarchive/Products/Applications/$app_name.app"
dist="$RUNNER_TEMP/Crux-dist"

if [ "$SIGNING_MODE" = developer-id ]; then
  test -n "${CERTIFICATE_BASE64:-}" && test -n "${KEYCHAIN_PASSWORD:-}"
  [[ "${DEVELOPMENT_TEAM:-}" =~ ^[A-Z0-9]{10}$ ]]
  printf '%s' "$CERTIFICATE_BASE64" | base64 --decode > "$certificate"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
  security import "$certificate" -P "$CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"
  security list-keychain -d user -s "$keychain"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$keychain"
  # Export, not build: no candidate build scripts or Package.swift execute here.
  export_options="$RUNNER_TEMP/crux-export-options.plist"
  test ! -e "$export_options"
  cp tools/app-updates/DeveloperIDExport.plist "$export_options"
  /usr/libexec/PlistBuddy -c "Add :teamID string $DEVELOPMENT_TEAM" "$export_options"
  xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/Crux-verified/Crux.xcarchive" \
    -exportPath "$RUNNER_TEMP/Crux-export" -exportOptionsPlist "$export_options"
  app="$RUNNER_TEMP/Crux-export/$app_name.app"
  test -n "${NOTARY_KEY_BASE64:-}" && test -n "${NOTARY_KEY_ID:-}" && test -n "${NOTARY_ISSUER_ID:-}"
  printf '%s' "$NOTARY_KEY_BASE64" | base64 --decode > "$notary_key"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$RUNNER_TEMP/Crux-notarization.zip"
  xcrun notarytool submit "$RUNNER_TEMP/Crux-notarization.zip" --wait --key "$notary_key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
elif [ "$SIGNING_MODE" != adhoc ]; then exit 1; fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
bash scripts/package-release.sh "$app" "$version" "$dist"
node tools/app-updates/prepare.mjs --app "$app" --channel "$CHANNEL" --tag "$RELEASE_TAG" --output "$dist" \
  --existing-archive --key-file "$key_file" --sign-tool "$RUNNER_TEMP/CruxSigner/bin/sign_update" --signing-mode "$SIGNING_MODE"
if [ "$SIGNING_MODE" = developer-id ]; then
  dmg="$dist/$prefix-$version-arm64.dmg"
  xcrun notarytool submit "$dmg" --wait --key "$notary_key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  (cd "$dist" && shasum -a 256 "$prefix-$version-arm64.zip" "$prefix-$version-arm64.dmg" > SHA256SUMS.txt)
fi
if gh release view "$RELEASE_TAG" --repo zacharyhuo/Crux; then
  echo 'Release exists; notes refresh requires an established ledger entry. Never overwrite assets; recover unpromoted releases through a reviewed new tag/build and the full main Release workflow.' >&2
  exit 1
fi
args=(); if [ "$CHANNEL" = beta ]; then args+=(--prerelease); fi
gh release create "$RELEASE_TAG" "$dist/$prefix-$version-arm64.zip" "$dist/$prefix-$version-arm64.dmg" \
  "$dist/SHA256SUMS.txt" "$dist/update-build.json" --repo zacharyhuo/Crux --verify-tag --generate-notes \
  --title "$app_name $version" "${args[@]}"
release_id="$(gh api "repos/zacharyhuo/Crux/releases/tags/$RELEASE_TAG" --jq '.id')"
node tools/app-updates/publish.mjs --release "$release_id" --build "$dist/update-build.json" --directory "$dist" \
  --approved-plan "$RUNNER_TEMP/approved-plan.json" --candidate-receipt "$RUNNER_TEMP/Crux-payload/build-receipt.json" --candidate-payload "$RUNNER_TEMP/Crux-payload/payload.tar" \
  --key-file "$key_file" --sign-tool "$RUNNER_TEMP/CruxSigner/bin/sign_update"
