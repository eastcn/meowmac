import Foundation
import MeowMacUI

@main
enum MeowMacMain {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if let status = AIAgentTerminalLauncher.handleCommandLine(args) { exit(status) }
        if args.first == "--snapshot-json" {
            do {
                guard args.count == 1 || (args.count == 3 && args[1] == "--dump-raw") else { throw CocoaError(.validationMissingMandatoryProperty) }
                let directory = args.count == 3 ? URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() : nil
                if let directory {
                    let boundary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
                    guard directory.path == boundary.path || directory.path.hasPrefix(boundary.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
                }
                let state = try await SnapshotCollector.collect(rawDirectory: directory)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let output = try encoder.encode(PanelSnapshot(state: state))
                FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { fputs("快照采集失败：\(error)\n", stderr); exit(1) }
            return
        }
        if args.count == 2, args[0] == "--export-icon" {
            let directory = URL(fileURLWithPath: args[1], isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for size in [16, 32, 128, 256, 512] {
                    for scale in [1, 2] {
                        let suffix = scale == 2 ? "@2x" : ""
                        let data = AppIcon.png(size: size * scale)
                        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
                    }
                }
            } catch {
                fputs("图标导出失败：\(error)\n", stderr)
                exit(1)
            }
            return
        }
        MeowMacApplication.run()
    }
}
