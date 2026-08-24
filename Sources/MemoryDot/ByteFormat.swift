import Foundation

enum ByteFormat {
	static func short(_ bytes: UInt64) -> String {
		let gb = Double(bytes) / 1_073_741_824
		if gb >= 1 {
			return String(format: "%.1f GB", gb)
		}
		let mb = Double(bytes) / 1_048_576
		return String(format: "%.0f MB", mb)
	}
}
