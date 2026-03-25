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

- **Green**: Normal — the system has plenty of available memory.
- **Yellow**: Warning — the kernel is under memory pressure.
- **Red**: Critical — severe memory pressure, heavy swapping/compression.

Click the dot to see a breakdown of your system's memory (wired, active, inactive, compressed, free) and the kernel's free percentage.

## Performance

MemoryDot is designed to be invisible in terms of resource usage:

- **Idle polling**: Two lightweight `sysctl` reads every 3 seconds (no Mach traps).
- **Event-driven**: A `DispatchSource` memory pressure listener fires instantly on kernel pressure changes with zero idle cost.
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

### With Xcode (via xcodegen)

```bash
brew install xcodegen  # if not already installed
xcodegen generate
open MemoryDot.xcodeproj
```

Then build and run with Cmd+R.

## License

GNU GPL 2.0

## Author

[Nadim Kobeissi](https://nadim.computer)
