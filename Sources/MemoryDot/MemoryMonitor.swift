import AppKit
import Observation

enum PressureLevel: String {
	case normal = "Normal"
	case warning = "Warning"
	case critical = "Critical"
}

@Observable
@MainActor
final class MemoryMonitor {
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

	var dotColor: NSColor {
		switch pressureLevel {
		case .normal: .systemGreen
		case .warning: .systemYellow
		case .critical: .systemRed
		}
	}

	/// Cached dot image — only rebuilt when pressure level changes.
	var dotImage: NSImage {
		if let cached = cachedDotImage, cachedDotLevel == pressureLevel {
			return cached
		}
		let image = StatusIcon.createDotImage(color: dotColor)
		cachedDotImage = image
		cachedDotLevel = pressureLevel
		return image
	}

	/// VM breakdown stats — fetched on demand (only when the menu is open).
	struct VMStats {
		var wiredBytes: UInt64 = 0
		var activeBytes: UInt64 = 0
		var inactiveBytes: UInt64 = 0
		var compressedBytes: UInt64 = 0
		var freeBytes: UInt64 = 0
	}

	func fetchVMStats() -> VMStats {
		var stats = vm_statistics64()
		var count = mach_msg_type_number_t(
			MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
		)

		let result = withUnsafeMutablePointer(to: &stats) { ptr in
			ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
			}
		}

		guard result == KERN_SUCCESS else { return VMStats() }

		let pageSize = UInt64(getpagesize())
		return VMStats(
			wiredBytes: UInt64(stats.wire_count) * pageSize,
			activeBytes: UInt64(stats.active_count) * pageSize,
			inactiveBytes: UInt64(stats.inactive_count) * pageSize,
			compressedBytes: UInt64(stats.compressor_page_count) * pageSize,
			freeBytes: UInt64(stats.free_count) * pageSize
		)
	}

	/// Timer polls only the lightweight sysctl calls (no Mach traps).
	private func startPolling() {
		timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
			Task { @MainActor in
				self?.refreshKernelPressure()
			}
		}
	}

	/// Dispatch source fires instantly on kernel pressure events (zero cost when idle).
	private func startPressureSource() {
		let source = DispatchSource.makeMemoryPressureSource(
			eventMask: [.warning, .critical],
			queue: .main
		)
		source.setEventHandler { [weak self] in
			Task { @MainActor in
				self?.refreshKernelPressure()
			}
		}
		source.activate()
		pressureSource = source
	}

	/// Two lightweight sysctl reads — no Mach traps.
	private func refreshKernelPressure() {
		var level: Int32 = 0
		var size = MemoryLayout<Int32>.size
		if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 {
			systemFreePercent = Int(level)
		}

		var pressureValue: Int32 = 0
		size = MemoryLayout<Int32>.size
		if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureValue, &size, nil, 0) == 0 {
			switch pressureValue {
			case 4: pressureLevel = .critical
			case 2: pressureLevel = .warning
			default: pressureLevel = .normal
			}
		}
	}
}
