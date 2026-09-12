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

@Test(arguments: [UInt64(4_096), UInt64(16_384)])
@MainActor func vmBreakdownCountsSpeculativePagesOnlyOnce(pageSize: UInt64) {
	var raw = vm_statistics64()
	raw.wire_count = 10
	raw.active_count = 20
	raw.inactive_count = 30
	raw.compressor_page_count = 40
	raw.free_count = 100
	raw.speculative_count = 25
	let stats = MemoryMonitor.VMStats(kernelStats: raw, pageSize: pageSize)

	#expect(stats.wiredBytes == 10 * pageSize)
	#expect(stats.activeBytes == 20 * pageSize)
	#expect(stats.inactiveBytes == 30 * pageSize)
	#expect(stats.compressedBytes == 40 * pageSize)
	#expect(stats.speculativeBytes == 25 * pageSize)
	#expect(stats.freeBytes == 75 * pageSize)
	#expect(stats.freeBytes + stats.speculativeBytes == UInt64(raw.free_count) * pageSize)
}

@Test @MainActor func vmBreakdownHandlesChangingFreeCountersWithoutUnderflow() {
	var raw = vm_statistics64()
	raw.free_count = 10
	raw.speculative_count = 11
	let stats = MemoryMonitor.VMStats(kernelStats: raw, pageSize: 16_384)
	#expect(stats.freeBytes == 0)
	#expect(stats.speculativeBytes == 11 * 16_384)
}

@Test @MainActor func vmBreakdownConvertsLargePageCountsWithoutOverflow() {
	var raw = vm_statistics64()
	raw.active_count = .max
	let stats = MemoryMonitor.VMStats(kernelStats: raw, pageSize: 16_384)
	#expect(stats.activeBytes == UInt64(UInt32.max) * 16_384)
}

@Test @MainActor func readingVMStatsDoesNotLeakMachPorts() throws {
	let host = mach_host_self()
	defer { mach_port_deallocate(mach_task_self_, host) }

	func sendRights() throws -> mach_port_urefs_t {
		var refs: mach_port_urefs_t = 0
		try #require(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &refs) == KERN_SUCCESS)
		return refs
	}

	#expect(MemoryMonitor.readVMStats() != nil)

	let before = try sendRights()
	for _ in 0..<200 {
		_ = MemoryMonitor.readVMStats()
	}
	#expect(try sendRights() == before)
}
