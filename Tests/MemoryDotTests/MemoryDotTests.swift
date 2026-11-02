import AppKit
import ServiceManagement
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

@Test func switchesToGigabytesWhenMegabytesWouldRoundTo1024() {
	#expect(ByteFormat.short(1023 * 1_048_576 + 400_000) == "1023 MB")
	#expect(ByteFormat.short(1023 * 1_048_576 + 600_000) == "1.0 GB")
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

@Test @MainActor func liveBreakdownAccountsForMostButNotMoreThanPhysicalMemory() throws {
	let stats = try #require(MemoryMonitor.readVMStats())
	let accounted = stats.wiredBytes + stats.activeBytes + stats.inactiveBytes
		+ stats.speculativeBytes + stats.compressedBytes + stats.freeBytes
	let physical = ProcessInfo.processInfo.physicalMemory
	#expect(accounted > physical / 2)
	#expect(accounted <= physical)
}

@Test @MainActor func liveKernelPressureIsReadable() throws {
	_ = try #require(MemoryMonitor.readPressureLevel())
	let percent = try #require(MemoryMonitor.readAvailablePercent())
	#expect((0...100).contains(percent))
}

// MARK: - Menu

private let gib: UInt64 = 1 << 30
private let mib: UInt64 = 1 << 20

@MainActor private func titles(_ snapshot: MemoryMonitor.Snapshot, loginItem: SMAppService.Status = .notRegistered) -> [String] {
	StatusItemController.menuItems(for: snapshot, loginItemStatus: loginItem, target: nil)
		.filter { !$0.isSeparatorItem }
		.map(\.title)
}

@MainActor private func sampleStats() -> MemoryMonitor.VMStats {
	var raw = vm_statistics64()
	raw.wire_count = UInt32(3 * gib / 16_384)
	raw.active_count = UInt32(4 * gib / 16_384)
	raw.inactive_count = UInt32(2 * gib / 16_384)
	raw.speculative_count = UInt32(7 * mib / 16_384)
	raw.compressor_page_count = UInt32(gib / 16_384)
	raw.free_count = UInt32(519 * mib / 16_384)
	return MemoryMonitor.VMStats(kernelStats: raw, pageSize: 16_384)
}

@Test @MainActor func menuShowsTheSnapshotItWasBuiltFrom() {
	let snapshot = MemoryMonitor.Snapshot(pressureLevel: .warning, availablePercent: 47, vmStats: sampleStats(), physicalBytes: 16 * gib)
	let shown = titles(snapshot)

	#expect(shown.prefix(2) == ["Memory Pressure: Warning", "47% available"])
	#expect(shown.contains("Wired:            3.0 GB"))
	#expect(shown.contains("Speculative:        7 MB"))
	#expect(shown.contains("Free:             512 MB"))
	#expect(shown.contains("Physical Memory: 16.0 GB"))
}

@Test @MainActor func menuValuesShareOneRightAlignedColumn() {
	let snapshot = MemoryMonitor.Snapshot(pressureLevel: .normal, availablePercent: 50, vmStats: sampleStats(), physicalBytes: 16 * gib)
	let rows = StatusItemController.menuItems(for: snapshot, loginItemStatus: .notRegistered, target: nil)
		.filter { ($0.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch == true }
		.map(\.title)
	#expect(rows.count == 7)
	#expect(Set(rows.map(\.count)).count == 1)
}

@Test @MainActor func menuHeaderDotKeepsItsColor() throws {
	let snapshot = MemoryMonitor.Snapshot(pressureLevel: .critical, availablePercent: 5, vmStats: nil, physicalBytes: 16 * gib)
	let header = try #require(StatusItemController.menuItems(for: snapshot, loginItemStatus: .notRegistered, target: nil).first)
	let image = try #require(header.image)
	#expect(!image.isTemplate)
}

@Test @MainActor func menuSaysUnavailableInsteadOfShowingInventedValues() {
	let snapshot = MemoryMonitor.Snapshot(pressureLevel: nil, availablePercent: nil, vmStats: nil, physicalBytes: 16 * gib)
	let shown = titles(snapshot)

	#expect(shown.first == "Memory Pressure: Unavailable")
	#expect(!shown.contains { $0.hasSuffix("% available") })
	#expect(shown.contains("Breakdown unavailable"))
	#expect(shown.contains("Physical Memory: 16.0 GB"))
}

@Test(arguments: [
	(SMAppService.Status.enabled, NSControl.StateValue.on, false),
	(.notRegistered, .off, false),
	(.notFound, .off, false),
	(.requiresApproval, .off, true),
])
@MainActor func launchAtLoginItemReflectsServiceStatus(status: SMAppService.Status, state: NSControl.StateValue, offersApproval: Bool) throws {
	let snapshot = MemoryMonitor.Snapshot(pressureLevel: .normal, availablePercent: 50, vmStats: nil, physicalBytes: 16 * gib)
	let items = StatusItemController.menuItems(for: snapshot, loginItemStatus: status, target: nil)
	let toggle = try #require(items.first { $0.title == "Launch at Login" })
	#expect(toggle.state == state)
	#expect(items.contains { $0.title == "Approve Launch at Login…" } == offersApproval)
}
