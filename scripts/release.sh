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
#   ./scripts/release.sh 1.1 --skip-notarize   # build only, publishes nothing
#───────────────────────────────────────────────────────────────

NOTARYTOOL_PROFILE="MemoryDot"
GITHUB_REPO="nadimkobeissi/memorydot"
TAP_REPO_DIR="../homebrew-memorydot"
SCHEME="MemoryDot"
APP_NAME="MemoryDot"
BUNDLE_ID="com.symbolicsoft.memorydot"

# ── Parse arguments ──────────────────────────────────────────

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--skip-notarize" ) ]]; then
    echo "Usage: $0 <version> [--skip-notarize]"
    echo "  e.g. $0 1.0"
    exit 1
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Invalid version: use one to three dot-separated integers (e.g. 1.3 or 1.3.1)." >&2
    exit 1
fi

SKIP_NOTARIZE=false
PUBLISH=true
if [[ "${2:-}" == "--skip-notarize" ]]; then
    SKIP_NOTARIZE=true
    PUBLISH=false
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# SwiftPM owns .build/release (normally a symlink). Keep release artifacts separate.
BUILD_DIR="$PROJECT_DIR/.build/distribution"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
TAG="v$VERSION"
CASK_DIR="$PROJECT_DIR/$TAP_REPO_DIR"

cd "$PROJECT_DIR"

# Fail before changing project.yml or spending time on an archive.
for tool in git xcodegen xcodebuild hdiutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit or stash your changes first:"
    git status --short
    exit 1
fi

check_tap() {
    [[ -d "$CASK_DIR" ]] || return 0
    local tap_root
    tap_root=$(git -C "$CASK_DIR" rev-parse --show-toplevel) || return 1
    if [[ "$tap_root" != "$(cd "$CASK_DIR" && pwd -P)" ]]; then
        echo "Tap checkout must be a repository root: $CASK_DIR" >&2
        return 1
    fi
    if [[ -n "$(git -C "$CASK_DIR" status --porcelain)" ]]; then
        echo "Tap working tree is not clean. Commit or stash its changes first:" >&2
        git -C "$CASK_DIR" status --short
        return 1
    fi
}

if [[ "$PUBLISH" == true ]]; then
    for tool in gh xcrun shasum; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Required tool not found: $tool" >&2
            exit 1
        fi
    done
    gh auth status
    # Check both refs: the remote tag might not have been fetched locally.
    if git show-ref --verify --quiet "refs/tags/$TAG"; then
        echo "Tag already exists: $TAG" >&2
        exit 1
    fi
    REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/$TAG")
    if [[ -n "$REMOTE_TAG" ]]; then
        echo "Tag already exists on origin: $TAG" >&2
        exit 1
    fi
    check_tap
fi

# Require one numeric build setting so a malformed project cannot reset the build number.
CURRENT_BUILD=$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2 }' project.yml)
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ || ${#CURRENT_BUILD} -gt 9 ]]; then
    echo "Invalid CURRENT_PROJECT_VERSION in project.yml: $CURRENT_BUILD" >&2
    exit 1
fi
NEW_BUILD=$((10#$CURRENT_BUILD + 1))
if [[ $(awk '/^[[:space:]]*MARKETING_VERSION:/ { count++ } END { print count+0 }' project.yml) -ne 1 ]]; then
    echo "Expected exactly one MARKETING_VERSION in project.yml." >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Releasing $APP_NAME v$VERSION"
if [[ "$PUBLISH" == false ]]; then
    echo "    --skip-notarize: building only, nothing will be published"
fi

# ── 1. Update version in project.yml ─────────────────────────

echo "==> Updating version in project.yml..."
sed -i '' "s/^\([[:space:]]*MARKETING_VERSION:\).*/\1 \"$VERSION\"/" project.yml

sed -i '' "s/^\([[:space:]]*CURRENT_PROJECT_VERSION:\).*/\1 $NEW_BUILD/" project.yml
VERSIONED_PROJECT_HASH=$(git hash-object project.yml)
echo "    Version: $VERSION  Build: $NEW_BUILD"

# ── 2. Generate Xcode project ────────────────────────────────

echo "==> Generating Xcode project..."
xcodegen generate --quiet

# ── 3. Archive ───────────────────────────────────────────────

echo "==> Archiving..."
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -quiet

# ── 4. Export signed .app ────────────────────────────────────

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

# ── 5. Create DMG ────────────────────────────────────────────

echo "==> Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH" \
    -quiet

echo "    DMG: $DMG_PATH"

# ── 6. Notarize ──────────────────────────────────────────────

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

# ── 7. Publish release ───────────────────────────────────────

if [[ "$PUBLISH" == false ]]; then
    echo "==> Skipping publication (--skip-notarize)"
    echo "    Built: $DMG_PATH"
    echo "    Note: project.yml is bumped to $VERSION ($NEW_BUILD) but not committed."
    exit 0
fi

echo "==> Committing version bump and tagging $TAG..."
# Refuse to tag sources edited while the archive/notarization was running.
if [[ "$(git status --porcelain)" != " M project.yml" || "$(git hash-object project.yml)" != "$VERSIONED_PROJECT_HASH" ]]; then
    echo "Working tree changed during the release. Review it before committing or publishing." >&2
    git status --short
    exit 1
fi
git add project.yml
git commit --only -m "$VERSION ($NEW_BUILD)" -- project.yml
git tag "$TAG"
git push
git push origin "$TAG"

echo "==> Creating GitHub release $TAG..."
gh release create "$TAG" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --verify-tag \
    --title "$APP_NAME $TAG" \
    --notes "Release $APP_NAME $TAG" \
    --draft

echo "    Draft release created. Review and publish at:"
echo "    https://github.com/$GITHUB_REPO/releases"

# ── 8. Update Homebrew cask ──────────────────────────────────

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo "==> Updating Homebrew cask..."

if [[ ! -d "$CASK_DIR" ]]; then
    echo "    Tap repo not found at $CASK_DIR"
    echo "    Clone it first:  gh repo clone nadimkobeissi/homebrew-memorydot $CASK_DIR"
    echo ""
    echo "    Cask values for manual update:"
    echo "    version  \"$VERSION\""
    echo "    sha256   \"$SHA256\""
    exit 0
fi

# Notarization can take a while; recheck before overwriting the cask.
check_tap
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

  depends_on macos: ">= :sonoma"

  app "$APP_NAME.app"

  zap trash: [
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]
end
CASK

git -C "$CASK_DIR" add -- Casks/memorydot.rb
git -C "$CASK_DIR" commit --only -m "Update $APP_NAME to $VERSION" -- Casks/memorydot.rb

echo ""
echo "==> Done!"
echo "    1. Review and publish the draft release:"
echo "       https://github.com/$GITHUB_REPO/releases"
echo "    2. The cask is committed but NOT pushed, because it points at that"
echo "       release asset. Once the release is published, push it:"
echo "       git -C \"$CASK_DIR\" push"
echo "    3. Users can then install with:"
echo "       brew tap nadimkobeissi/memorydot"
echo "       brew install --cask memorydot"
