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
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
notes_file="$RUNNER_TEMP/crux-release-notes.md"
if [ "$SIGNING_MODE" = adhoc ]; then
  signing_zh='本预览版采用 ad-hoc 签名，未经 Apple Developer ID 签名或公证。首次打开可能被 Gatekeeper 阻止；仅在信任此应用时，在系统设置 → 隐私与安全性中选择“仍要打开”。不要关闭系统整体安全检查。'
  signing_en='This preview is ad-hoc signed, without Apple Developer ID signing or notarization. Gatekeeper may block the first launch. Only if you trust this app, use System Settings → Privacy & Security → Open Anyway. Do not disable system-wide security checks.'
else
  signing_zh='此安装包使用 Developer ID 签名并经过 Apple 公证。'
  signing_en='This package is Developer ID signed and notarized by Apple.'
fi
cat > "$notes_file" <<EOF
# $app_name $version (build $build) / Early Preview

## 中文

适用于 Apple Silicon（arm64），要求 macOS 26 或更高版本。

- 首次安装请下载 **$prefix-$version-arm64.dmg**，通过 Finder 将 **$app_name.app** 拖入 Applications 后启动。
- ZIP 包也包含应用，并用于 Sparkle 更新；GitHub 的 Source code 压缩包是源码，不是安装包。
- 已安装且配置更新密钥的同渠道版本可通过应用菜单的 Check for Updates 检查更新。
- SHA256SUMS.txt 提供安装包校验和。Crux 与 Crux Beta 使用独立的数据目录和更新渠道。

$signing_zh

Sparkle 签名用于验证更新包，与 Apple 公证不同。自动发布并不代表真实更新安装与重启验收已完成，验收结果会在此补充。

## English

For Apple Silicon (arm64), requiring macOS 26 or later.

- For a first installation, download **$prefix-$version-arm64.dmg** and use Finder to drag **$app_name.app** into Applications before launching it.
- The ZIP also contains the app and is used for Sparkle updates. GitHub Source code archives are not app installers.
- Installed builds on the same channel with an update key can use Check for Updates in the app menu.
- SHA256SUMS.txt provides package checksums. Crux and Crux Beta use separate data directories and update channels.

$signing_en

Sparkle signatures verify updates and are separate from Apple notarization. Automated publication does not establish that real update installation and relaunch acceptance has passed; results will be added here.

[Commits / 提交记录](https://github.com/zacharyhuo/Crux/commits/$RELEASE_TAG)
EOF
args=(); if [ "$CHANNEL" = beta ]; then args+=(--prerelease); fi
gh release create "$RELEASE_TAG" "$dist/$prefix-$version-arm64.zip" "$dist/$prefix-$version-arm64.dmg" \
  "$dist/SHA256SUMS.txt" "$dist/update-build.json" --repo zacharyhuo/Crux --verify-tag --notes-file "$notes_file" \
  --title "$app_name $version (build $build)" "${args[@]}"
release_id="$(gh api "repos/zacharyhuo/Crux/releases/tags/$RELEASE_TAG" --jq '.id')"
node tools/app-updates/publish.mjs --release "$release_id" --build "$dist/update-build.json" --directory "$dist" \
  --approved-plan "$RUNNER_TEMP/approved-plan.json" --candidate-receipt "$RUNNER_TEMP/Crux-payload/build-receipt.json" --candidate-payload "$RUNNER_TEMP/Crux-payload/payload.tar" \
  --key-file "$key_file" --sign-tool "$RUNNER_TEMP/CruxSigner/bin/sign_update"
