import AppKit
import Observation

enum PressureLevel: String {
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

@Observable
@MainActor
final class MemoryMonitor {
	/// VM breakdown stats — fetched on demand (only when the menu is open).
	struct VMStats {
		var wiredBytes: UInt64 = 0
		var activeBytes: UInt64 = 0
		var inactiveBytes: UInt64 = 0
		var speculativeBytes: UInt64 = 0
		var compressedBytes: UInt64 = 0
		var freeBytes: UInt64 = 0
	}

	struct Snapshot {
		var pressureLevel: PressureLevel
		var freePercent: Int
		var vmStats: VMStats?
	}

	private(set) var pressureLevel: PressureLevel = .normal
	private(set) var systemFreePercent: Int = 100

	let totalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

	@ObservationIgnored private var timer: Timer?
	@ObservationIgnored private var pressureSource: (any DispatchSourceMemoryPressure)?
	@ObservationIgnored private var cachedDotImage: NSImage?
	@ObservationIgnored private var cachedDotLevel: PressureLevel?

	init() {
		refreshKernelPressure()
		startPolling()
		startPressureSource()
	}

	/// Cached dot image — only rebuilt when pressure level changes.
	var dotImage: NSImage {
		if let cached = cachedDotImage, cachedDotLevel == pressureLevel {
			return cached
		}
		let image = StatusIcon.createDotImage(for: pressureLevel)
		cachedDotImage = image
		cachedDotLevel = pressureLevel
		return image
	}

	func currentSnapshot() -> Snapshot {
		let kernel = Self.readKernelPressure()
		return Snapshot(
			pressureLevel: kernel?.level ?? pressureLevel,
			freePercent: kernel?.freePercent ?? systemFreePercent,
			vmStats: Self.readVMStats()
		)
	}

	/// Timer polls only the lightweight sysctl calls (no Mach traps).
	private func startPolling() {
		let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.refreshKernelPressure()
			}
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	/// Dispatch source fires instantly on kernel pressure events (zero cost when idle).
	private func startPressureSource() {
		let source = DispatchSource.makeMemoryPressureSource(
			eventMask: [.warning, .critical],
			queue: .main
		)
		source.setEventHandler { [weak self] in
			MainActor.assumeIsolated {
				self?.refreshKernelPressure()
			}
		}
		source.activate()
		pressureSource = source
	}

	private func refreshKernelPressure() {
		guard let kernel = Self.readKernelPressure() else { return }
		systemFreePercent = kernel.freePercent
		pressureLevel = kernel.level
	}

	/// Two lightweight sysctl reads — no Mach traps.
	private static func readKernelPressure() -> (level: PressureLevel, freePercent: Int)? {
		var freeLevel: Int32 = 0
		var size = MemoryLayout<Int32>.size
		guard sysctlbyname("kern.memorystatus_level", &freeLevel, &size, nil, 0) == 0 else {
			return nil
		}

		var pressureValue: Int32 = 0
		size = MemoryLayout<Int32>.size
		guard
			sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureValue, &size, nil, 0) == 0
		else {
			return nil
		}

		return (PressureLevel(kernelValue: pressureValue), Int(freeLevel))
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

		let pageSize = UInt64(getpagesize())
		return VMStats(
			wiredBytes: UInt64(stats.wire_count) * pageSize,
			activeBytes: UInt64(stats.active_count) * pageSize,
			inactiveBytes: UInt64(stats.inactive_count) * pageSize,
			speculativeBytes: UInt64(stats.speculative_count) * pageSize,
			compressedBytes: UInt64(stats.compressor_page_count) * pageSize,
			freeBytes: UInt64(stats.free_count) * pageSize
		)
	}
}
