<img src="SupportingFiles/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="64" align="left" style="margin-right: 16px;border-radius:10px" />

# MemoryDot

A lightweight macOS menu bar app that shows your system's memory pressure at a glance. A colored dot sits in your menu bar and changes color based on the kernel's own memory pressure assessment.

On macOS, "free RAM" is a misleading number. The system aggressively caches files, compresses inactive pages, and reclaims memory on demand — so low free RAM doesn't mean your system is struggling. What actually matters is *memory pressure*: how hard the kernel has to work to provide memory when apps need it. Few applications surface this metric, and those that do tend to be heavyweight system monitors that track dozens of things you don't care about. MemoryDot does one thing well: it puts the kernel's own pressure assessment in your menu bar so you can see at a glance whether your system is actually constrained, without loading a full analytics suite.

## Installation

```bash
brew tap nadimkobeissi/memorydot
brew install --cask memorydot
```

## How It Works

MemoryDot reads macOS's real memory pressure metrics — the same ones used by the `memory_pressure` command-line tool — not naive "free vs. used" calculations.

- **Green `M`**: Normal — the system has plenty of available memory.
- **Yellow `!`**: Warning — the kernel is under memory pressure.
- **Red `!!`**: Critical — severe memory pressure, heavy swapping/compression.

Click the dot to see a breakdown of your system's memory (wired, active, inactive, speculative, compressed, free) and the kernel's free percentage. The Free row excludes pages shown in the Speculative row. The breakdown does not account for every physical page, so its rows need not add up to Physical Memory.

Enable **Launch at Login** in the menu to start MemoryDot automatically. If macOS requires approval, **Approve Launch at Login…** opens the Login Items settings.

## Performance

MemoryDot is designed to be invisible in terms of resource usage:

- **Idle polling**: Two lightweight `sysctl` reads every 10 seconds, with one second of timer tolerance to let macOS coalesce wakeups (no Mach traps).
- **Event-driven**: A `DispatchSource` memory pressure listener fires instantly on warning, critical, and recovery-to-normal events with zero idle cost.
- **On-demand stats**: The detailed VM breakdown (`host_statistics64`) is only fetched when you open the menu.
- **Cached icon**: The menu bar image is only redrawn when the pressure level actually changes.

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 6

## Building

### With Swift Package Manager

```bash
swift build
.build/debug/MemoryDot
```

This produces a development executable without an app bundle, so it shows a Dock icon and “MemoryDot (Development)” in the menu. Use the Xcode build for the app icon, bundled version, and Launch at Login support.

### With Xcode (via xcodegen)

```bash
brew install xcodegen  # if not already installed
xcodegen generate
open MemoryDot.xcodeproj
```

Then build and run with Cmd+R.

## Testing

```bash
swift test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/ReleaseScriptTests -v
```

Swift tests cover pressure levels, byte formatting, VM page accounting, and Mach port ownership. Release-script tests use temporary Git repositories and mock the build, signing, and publication tools; they do not publish releases or change your Homebrew tap.

## Releasing

```bash
./scripts/release.sh 1.4 --skip-notarize  # build only
./scripts/release.sh 1.4                  # notarize and create a draft release
```

Run from a clean working tree. The script validates the version and tools before building, checks for existing release tags, and requires a clean sibling tap checkout if present. Artifacts go in `.build/distribution/`. Build-only mode leaves the version bump uncommitted and skips notarization and publication.

For a full release, follow the one-time setup in `scripts/release.sh`. After reviewing and publishing the draft on GitHub, push the cask commit from `../homebrew-memorydot` using the command printed by the script.

## License

GNU GPL 2.0

## Author

[Nadim Kobeissi](https://nadim.computer)
