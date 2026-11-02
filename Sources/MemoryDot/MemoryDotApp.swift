import AppKit

@main
@MainActor
enum MemoryDotApp {
	static func main() {
		let app = NSApplication.shared
		let controller = StatusItemController()
		withExtendedLifetime(controller) {
			app.run()
		}
	}
}
