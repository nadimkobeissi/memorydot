import AppKit
import ServiceManagement

/// Owns the menu bar item. AppKit calls `menuNeedsUpdate(_:)` right before the menu
/// is displayed, so every open shows a fresh snapshot and nothing is read while it is closed.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
	private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let monitor = MemoryMonitor()

	override init() {
		super.init()
		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu
		showPressureLevel(monitor.pressureLevel)
		monitor.onPressureLevelChange = { [weak self] level in
			self?.showPressureLevel(level)
		}
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.items = Self.menuItems(
			for: monitor.snapshot(),
			loginItemStatus: SMAppService.mainApp.status,
			target: self
		)
	}

	/// The image is only redrawn here, on an actual level change.
	private func showPressureLevel(_ level: PressureLevel) {
		statusItem.button?.image = StatusIcon.createDotImage(for: level)
	}

	static func menuItems(
		for snapshot: MemoryMonitor.Snapshot,
		loginItemStatus: SMAppService.Status,
		target: AnyObject?
	) -> [NSMenuItem] {
		let level = snapshot.pressureLevel?.displayName ?? String(localized: "Unavailable")
		let header = infoItem(String(localized: "Memory Pressure: \(level)"))
		header.image = snapshot.pressureLevel.map { StatusIcon.createDotImage(for: $0, size: 16) }
		var items = [header]
		if let percent = snapshot.availablePercent {
			items.append(infoItem(String(localized: "\(percent)% available"), font: secondaryFont))
		}
		items.append(.separator())

		var rows: [(label: String, bytes: UInt64)] = []
		if let stats = snapshot.vmStats {
			rows = [
				(String(localized: "Wired:"), stats.wiredBytes),
				(String(localized: "Active:"), stats.activeBytes),
				(String(localized: "Inactive:"), stats.inactiveBytes),
				(String(localized: "Speculative:"), stats.speculativeBytes),
				(String(localized: "Compressed:"), stats.compressedBytes),
				(String(localized: "Free:"), stats.freeBytes),
			]
		}
		rows.append((String(localized: "Physical Memory:"), snapshot.physicalBytes))
		var column = columnItems(rows)
		let physicalMemory = column.removeLast()
		if column.isEmpty {
			column = [infoItem(String(localized: "Breakdown unavailable"), font: secondaryFont)]
		}
		items += column
		items += [.separator(), physicalMemory, .separator()]

		items.append(infoItem(versionDescription, font: secondaryFont))
		let launchAtLogin = actionItem(
			String(localized: "Launch at Login"), #selector(toggleLaunchAtLogin), target)
		launchAtLogin.state = loginItemStatus == .enabled ? .on : .off
		items.append(launchAtLogin)
		if loginItemStatus == .requiresApproval {
			items.append(actionItem(
				String(localized: "Approve Launch at Login…"), #selector(openLoginItemsSettings), target))
		}
		items.append(actionItem(String(localized: "Website"), #selector(openWebsite), target))
		items.append(.separator())
		items.append(NSMenuItem(
			title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
		return items
	}

	/// Monospaced rows whose values share one right-aligned column.
	private static func columnItems(_ rows: [(label: String, bytes: UInt64)]) -> [NSMenuItem] {
		let cells = rows.map { (label: $0.label, value: ByteFormat.short($0.bytes)) }
		let width = cells.map { $0.label.count + 1 + $0.value.count }.max() ?? 0
		let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		return cells.map { cell in
			let gap = String(repeating: " ", count: width - cell.label.count - cell.value.count)
			return infoItem(cell.label + gap + cell.value, font: font)
		}
	}

	private static var secondaryFont: NSFont {
		.menuFont(ofSize: NSFont.smallSystemFontSize)
	}

	/// A display-only row. Having no action, it is disabled by menu validation.
	private static func infoItem(_ title: String, font: NSFont? = nil) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		if let font {
			item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
		}
		return item
	}

	private static func actionItem(_ title: String, _ action: Selector, _ target: AnyObject?) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.target = target
		return item
	}

	private static var versionDescription: String {
		guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
			return String(localized: "MemoryDot (Development)")
		}
		return "MemoryDot v\(version)"
	}

	/// Acts on the service's status at click time, not on what the menu showed when it opened.
	@objc private func toggleLaunchAtLogin() {
		let service = SMAppService.mainApp
		do {
			switch service.status {
			case .enabled:
				try service.unregister()
			case .requiresApproval:
				SMAppService.openSystemSettingsLoginItems()
			default:
				try service.register()
				if service.status == .requiresApproval {
					SMAppService.openSystemSettingsLoginItems()
				}
			}
		} catch {
			NSLog("MemoryDot: could not update login item: %@", error.localizedDescription)
			let alert = NSAlert()
			alert.messageText = String(localized: "Couldn’t Update Launch at Login")
			alert.informativeText = error.localizedDescription
			NSApp.activate()
			alert.runModal()
		}
	}

	@objc private func openLoginItemsSettings() {
		SMAppService.openSystemSettingsLoginItems()
	}

	@objc private func openWebsite() {
		NSWorkspace.shared.open(URL(string: "https://github.com/nadimkobeissi/memorydot")!)
	}
}
