#!/bin/bash
set -euo pipefail

#───────────────────────────────────────────────────────────────
# MemoryDot Release Script
#
# Builds, signs, notarizes, and publishes a new release.
#
# Prerequisites (one-time setup):
#   1. Apple Developer account with a Developer ID Application certificate
#      installed in your keychain.
#   2. Store notarization credentials:
#        xcrun notarytool store-credentials "MemoryDot" \
#          --apple-id "you@example.com" \
#          --team-id "YOUR_TEAM_ID" \
#          --password "app-specific-password"
#   3. Create the Homebrew tap repo on GitHub:
#        gh repo create nadimkobeissi/homebrew-memorydot --public
#        Then clone it next to this repo (../homebrew-memorydot).
#   4. gh auth login (already done if you use gh regularly)
#
# Usage:
#   ./scripts/release.sh 1.0
#   ./scripts/release.sh 1.1 --skip-notarize   # for testing
#───────────────────────────────────────────────────────────────

NOTARYTOOL_PROFILE="MemoryDot"
GITHUB_REPO="nadimkobeissi/memorydot"
TAP_REPO_DIR="../homebrew-memorydot"
SCHEME="MemoryDot"
APP_NAME="MemoryDot"
BUNDLE_ID="com.symbolicsoft.memorydot"

# ── Parse arguments ──────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--skip-notarize]"
    echo "  e.g. $0 1.0"
    exit 1
fi

VERSION="$1"
SKIP_NOTARIZE=false
if [[ "${2:-}" == "--skip-notarize" ]]; then
    SKIP_NOTARIZE=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Releasing $APP_NAME v$VERSION"

# ── 1. Update version in project.yml ─────────────────────────

echo "==> Updating version in project.yml..."
cd "$PROJECT_DIR"
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" project.yml

# Increment build number (reads current value, adds 1)
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/[^0-9]//g')
NEW_BUILD=$((CURRENT_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $NEW_BUILD/" project.yml
echo "    Version: $VERSION  Build: $NEW_BUILD"

# ── 2. Generate Xcode project ───────────────────────────────

echo "==> Generating Xcode project..."
xcodegen generate --quiet

# ── 2. Archive ───────────────────────────────────────────────

echo "==> Archiving..."
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -quiet

# ── 3. Export signed .app ────────────────────────────────────

echo "==> Exporting signed app..."

EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR" \
    -quiet

echo "    Signed app: $APP_PATH"

# ── 4. Create DMG ────────────────────────────────────────────

echo "==> Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH" \
    -quiet

echo "    DMG: $DMG_PATH"

# ── 5. Notarize ─────────────────────────────────────────────

if [[ "$SKIP_NOTARIZE" == true ]]; then
    echo "==> Skipping notarization (--skip-notarize)"
else
    echo "==> Submitting for notarization..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
fi

# ── 6. Upload to GitHub Releases ─────────────────────────────

echo "==> Creating GitHub release v$VERSION..."
TAG="v$VERSION"

gh release create "$TAG" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "$APP_NAME $TAG" \
    --notes "Release $APP_NAME $TAG" \
    --draft

echo "    Draft release created. Review and publish at:"
echo "    https://github.com/$GITHUB_REPO/releases"

# ── 7. Update Homebrew cask ──────────────────────────────────

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo "==> Updating Homebrew cask..."

CASK_DIR="$PROJECT_DIR/$TAP_REPO_DIR"
if [[ ! -d "$CASK_DIR" ]]; then
    echo "    Tap repo not found at $CASK_DIR"
    echo "    Clone it first:  gh repo clone nadimkobeissi/homebrew-memorydot $CASK_DIR"
    echo ""
    echo "    Cask values for manual update:"
    echo "    version  \"$VERSION\""
    echo "    sha256   \"$SHA256\""
    exit 0
fi

mkdir -p "$CASK_DIR/Casks"
cat > "$CASK_DIR/Casks/memorydot.rb" <<CASK
cask "memorydot" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$GITHUB_REPO/releases/download/v#{version}/$APP_NAME-#{version}.dmg",
      verified: "github.com/$GITHUB_REPO"

  name "$APP_NAME"
  desc "macOS menu bar app showing system memory pressure"
  homepage "https://github.com/$GITHUB_REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "$APP_NAME.app"

  zap trash: [
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]
end
CASK

cd "$CASK_DIR"
git add -A
git commit -m "Update $APP_NAME to $VERSION"
git push

echo ""
echo "==> Done!"
echo "    1. Review the draft release: https://github.com/$GITHUB_REPO/releases"
echo "    2. Publish it, then users can install with:"
echo "       brew tap nadimkobeissi/memorydot"
echo "       brew install --cask memorydot"
