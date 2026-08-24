import Foundation
import Testing

@testable import MemoryDot

@Test func pressureLevelMapsKernelValues() {
	#expect(PressureLevel(kernelValue: 4) == .critical)
	#expect(PressureLevel(kernelValue: 2) == .warning)
	#expect(PressureLevel(kernelValue: 1) == .normal)
	#expect(PressureLevel(kernelValue: 0) == .normal)
	#expect(PressureLevel(kernelValue: 99) == .normal)
	#expect(PressureLevel(kernelValue: -1) == .normal)
}

@Test func pressureLevelsAreVisuallyDistinctWithoutColor() {
	let glyphs = [PressureLevel.normal, .warning, .critical].map(\.glyph)
	#expect(Set(glyphs).count == glyphs.count)
}

@Test func formatsGigabytesWithOneDecimal() {
	#expect(ByteFormat.short(1_073_741_824) == "1.0 GB")
	#expect(ByteFormat.short(3_650_722_201) == "3.4 GB")
	#expect(ByteFormat.short(17_179_869_184) == "16.0 GB")
}

@Test func formatsSubGigabyteAsWholeMegabytes() {
	#expect(ByteFormat.short(0) == "0 MB")
	#expect(ByteFormat.short(1_048_576) == "1 MB")
	#expect(ByteFormat.short(536_870_912) == "512 MB")
}

@Test @MainActor func readingVMStatsDoesNotLeakMachPorts() {
	let host = mach_host_self()
	defer { mach_port_deallocate(mach_task_self_, host) }

	func sendRights() -> mach_port_urefs_t {
		var refs: mach_port_urefs_t = 0
		mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &refs)
		return refs
	}

	#expect(MemoryMonitor.readVMStats() != nil)

	let before = sendRights()
	for _ in 0..<200 {
		_ = MemoryMonitor.readVMStats()
	}
	#expect(sendRights() == before)
}
