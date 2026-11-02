import AppKit

enum PressureLevel {
	case normal
	case warning
	case critical

	init(kernelValue: Int32) {
		switch kernelValue {
		case 4: self = .critical
		case 2: self = .warning
		default: self = .normal
		}
	}

	var displayName: String {
		switch self {
		case .normal: String(localized: "Normal")
		case .warning: String(localized: "Warning")
		case .critical: String(localized: "Critical")
		}
	}

	var glyph: String {
		switch self {
		case .normal: "M"
		case .warning: "!"
		case .critical: "!!"
		}
	}

	var color: NSColor {
		switch self {
		case .normal: .systemGreen
		case .warning: .systemYellow
		case .critical: .systemRed
		}
	}
}

@MainActor
final class MemoryMonitor {
	/// VM breakdown stats — fetched on demand (only when the menu opens).
	struct VMStats {
		let wiredBytes: UInt64
		let activeBytes: UInt64
		let inactiveBytes: UInt64
		let speculativeBytes: UInt64
		let compressedBytes: UInt64
		let freeBytes: UInt64

		init(kernelStats stats: vm_statistics64, pageSize: UInt64) {
			wiredBytes = UInt64(stats.wire_count) * pageSize
			activeBytes = UInt64(stats.active_count) * pageSize
			inactiveBytes = UInt64(stats.inactive_count) * pageSize
			speculativeBytes = UInt64(stats.speculative_count) * pageSize
			compressedBytes = UInt64(stats.compressor_page_count) * pageSize
			// The kernel includes speculative pages in free_count. Show them only
			// in their own row, clamping because these counters can change mid-read.
			let freePages = stats.free_count - min(stats.free_count, stats.speculative_count)
			freeBytes = UInt64(freePages) * pageSize
		}
	}

	/// Everything the menu shows, read at one moment. A `nil` field means the
	/// kernel read failed; the menu says so rather than showing a stand-in value.
	struct Snapshot {
		var pressureLevel: PressureLevel?
		var availablePercent: Int?
		var vmStats: VMStats?
		var physicalBytes: UInt64
	}

	private(set) var pressureLevel: PressureLevel = .normal {
		didSet {
			if pressureLevel != oldValue {
				onPressureLevelChange?(pressureLevel)
			}
		}
	}
	/// Called on the main thread whenever `pressureLevel` changes.
	var onPressureLevelChange: ((PressureLevel) -> Void)?

	private var pressureSource: (any DispatchSourceMemoryPressure)?

	init() {
		refreshPressureLevel()
		startPolling()
		startPressureSource()
	}

	/// Reads everything at once, including the expensive VM breakdown. Records the
	/// fresh pressure level too, so the menu bar dot never disagrees with the menu.
	func snapshot() -> Snapshot {
		let level = Self.readPressureLevel()
		if let level {
			pressureLevel = level
		}
		return Snapshot(
			pressureLevel: level,
			availablePercent: Self.readAvailablePercent(),
			vmStats: Self.readVMStats(),
			physicalBytes: ProcessInfo.processInfo.physicalMemory
		)
	}

	/// Timer polls only the lightweight sysctl call (no Mach traps).
	private func startPolling() {
		let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] timer in
			guard let self else {
				// The run loop retains repeating timers even after the monitor dies.
				timer.invalidate()
				return
			}
			MainActor.assumeIsolated {
				self.refreshPressureLevel()
			}
		}
		timer.tolerance = 1.0
		RunLoop.main.add(timer, forMode: .common)
	}

	/// Dispatch source fires instantly on kernel pressure events (zero cost when idle).
	private func startPressureSource() {
		let source = DispatchSource.makeMemoryPressureSource(
			eventMask: [.normal, .warning, .critical],
			queue: .main
		)
		source.setEventHandler { [weak self] in
			MainActor.assumeIsolated {
				self?.refreshPressureLevel()
			}
		}
		source.activate()
		pressureSource = source
	}

	private func refreshPressureLevel() {
		if let level = Self.readPressureLevel() {
			pressureLevel = level
		}
	}

	/// `kern.memorystatus_vm_pressure_level`: the level the kernel reports to
	/// dispatch memory pressure sources (1 normal, 2 warning, 4 critical).
	static func readPressureLevel() -> PressureLevel? {
		readSysctl("kern.memorystatus_vm_pressure_level").map(PressureLevel.init(kernelValue:))
	}

	/// `kern.memorystatus_level`: the percentage of memory the kernel counts as
	/// available. `memory_pressure` prints it as the "free percentage", but it is
	/// far larger than the Free row, so the menu calls it "available".
	static func readAvailablePercent() -> Int? {
		readSysctl("kern.memorystatus_level").map(Int.init)
	}

	private static func readSysctl(_ name: String) -> Int32? {
		var value: Int32 = 0
		var size = MemoryLayout<Int32>.size
		guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
			return nil
		}
		return value
	}

	static func readVMStats() -> VMStats? {
		var stats = vm_statistics64()
		var count = mach_msg_type_number_t(
			MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
		)

		let host = mach_host_self()
		defer { mach_port_deallocate(mach_task_self_, host) }

		let result = withUnsafeMutablePointer(to: &stats) { ptr in
			ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				host_statistics64(host, HOST_VM_INFO64, $0, &count)
			}
		}

		guard result == KERN_SUCCESS else { return nil }

		return VMStats(kernelStats: stats, pageSize: UInt64(getpagesize()))
	}
}
