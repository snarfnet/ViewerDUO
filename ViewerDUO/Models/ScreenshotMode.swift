import Foundation

enum ScreenshotMode {
    static let target: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-screenshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    static var isActive: Bool { target != nil }
}
