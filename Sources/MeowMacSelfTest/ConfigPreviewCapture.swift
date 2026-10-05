import AppKit
import Foundation

@MainActor
enum ConfigPreviewCapture {
    /// 只截合成数据的实际窗口；玻璃由系统合成，不能用 bitmap 缓存替代。
    static func capture(_ window: NSWindow, to file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        process.standardOutput = Pipe(); let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            print("合成窗口截图失败：" + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
