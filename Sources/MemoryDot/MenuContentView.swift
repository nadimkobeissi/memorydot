import ServiceManagement
import SwiftUI

struct MenuContentView: View {
	let monitor: MemoryMonitor

	var body: some View {
		// VM stats fetched on demand — only when the menu is open.
		let snapshot = monitor.currentSnapshot()
		let launchAtLogin = SMAppService.mainApp.status == .enabled

		VStack(alignment: .leading, spacing: 4) {
			Label {
				Text("Memory Pressure: \(snapshot.pressureLevel.displayName)")
			} icon: {
				Image(systemName: "circle.fill")
					.foregroundStyle(Color(nsColor: snapshot.pressureLevel.color))
					.font(.system(size: 8))
			}

			Text("\(snapshot.freePercent)% free")
				.font(.subheadline)
				.foregroundStyle(.secondary)
		}

		Divider()

		if let stats = snapshot.vmStats {
			Text("Wired:        \(formattedBytes(stats.wiredBytes))")
				.font(.system(.caption, design: .monospaced))
			Text("Active:       \(formattedBytes(stats.activeBytes))")
				.font(.system(.caption, design: .monospaced))
			Text("Inactive:     \(formattedBytes(stats.inactiveBytes))")
				.font(.system(.caption, design: .monospaced))
			Text("Speculative:  \(formattedBytes(stats.speculativeBytes))")
				.font(.system(.caption, design: .monospaced))
			Text("Compressed:   \(formattedBytes(stats.compressedBytes))")
				.font(.system(.caption, design: .monospaced))
			Text("Free:         \(formattedBytes(stats.freeBytes))")
				.font(.system(.caption, design: .monospaced))
		} else {
			Text("Breakdown unavailable")
				.font(.system(.caption, design: .monospaced))
				.foregroundStyle(.secondary)
		}

		Divider()

		Text("Physical Memory: \(formattedBytes(monitor.totalBytes))")
			.font(.system(.caption, design: .monospaced))

		Divider()

		Text(
			"MemoryDot v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
		)
		.font(.system(.caption, design: .monospaced))
		.foregroundStyle(.secondary)

		Toggle(
			"Launch at Login",
			isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })
		)

		Button("Website") {
			NSWorkspace.shared.open(URL(string: "https://github.com/nadimkobeissi/memorydot")!)
		}

		Divider()

		Button("Quit") {
			NSApplication.shared.terminate(nil)
		}
		.keyboardShortcut("q")
	}

	private func setLaunchAtLogin(_ enabled: Bool) {
		do {
			if enabled {
				try SMAppService.mainApp.register()
			} else {
				try SMAppService.mainApp.unregister()
			}
		} catch {
			NSLog("MemoryDot: could not update login item: %@", error.localizedDescription)
		}
	}

	private func formattedBytes(_ bytes: UInt64) -> String {
		ByteFormat.short(bytes)
	}
}
