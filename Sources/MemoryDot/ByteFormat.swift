import Foundation

enum ByteFormat {
	static func short(_ bytes: UInt64) -> String {
		let mb = Double(bytes) / 1_048_576
		// Decide on the rounded value, so 1023.6 MB reads "1.0 GB" rather than "1024 MB".
		if mb.rounded() < 1024 {
			return String(format: "%.0f MB", mb)
		}
		return String(format: "%.1f GB", mb / 1024)
	}
}
