import ServiceManagement
import SwiftUI

struct MenuContentView: View {
	let monitor: MemoryMonitor

	@State private var launchAtLogin = SMAppService.mainApp.status == .enabled

	var body: some View {
		// VM stats fetched on demand — only when the menu is open.
		let stats = monitor.fetchVMStats()

		VStack(alignment: .leading, spacing: 4) {
			Label {
				Text("Memory Pressure: \(monitor.pressureLevel.rawValue)")
			} icon: {
				Image(systemName: "circle.fill")
					.foregroundStyle(Color(nsColor: monitor.dotColor))
					.font(.system(size: 8))
			}

			Text("\(monitor.systemFreePercent)% free")
				.font(.subheadline)
				.foregroundStyle(.secondary)
		}

		Divider()

		Text("Wired:        \(formattedBytes(stats.wiredBytes))")
			.font(.system(.caption, design: .monospaced))
		Text("Active:       \(formattedBytes(stats.activeBytes))")
			.font(.system(.caption, design: .monospaced))
		Text("Inactive:     \(formattedBytes(stats.inactiveBytes))")
			.font(.system(.caption, design: .monospaced))
		Text("Compressed:   \(formattedBytes(stats.compressedBytes))")
			.font(.system(.caption, design: .monospaced))
		Text("Free:         \(formattedBytes(stats.freeBytes))")
			.font(.system(.caption, design: .monospaced))

		Divider()

		Text("Total: \(formattedBytes(monitor.totalBytes))")
			.font(.system(.caption, design: .monospaced))

		Divider()

		Text(
			"MemoryDot v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
		)
		.font(.system(.caption, design: .monospaced))
		.foregroundStyle(.secondary)

		Toggle("Launch at Login", isOn: $launchAtLogin)
			.onChange(of: launchAtLogin) { _, newValue in
				do {
					if newValue {
						try SMAppService.mainApp.register()
					} else {
						try SMAppService.mainApp.unregister()
					}
				} catch {
					launchAtLogin = SMAppService.mainApp.status == .enabled
				}
			}

		Button("Website") {
			NSWorkspace.shared.open(URL(string: "https://github.com/nadimkobeissi/memorydot")!)
		}

		Divider()

		Button("Quit") {
			NSApplication.shared.terminate(nil)
		}
		.keyboardShortcut("q")
	}

	private func formattedBytes(_ bytes: UInt64) -> String {
		let gb = Double(bytes) / 1_073_741_824
		if gb >= 1 {
			return String(format: "%.1f GB", gb)
		}
		let mb = Double(bytes) / 1_048_576
		return String(format: "%.0f MB", mb)
	}
}
