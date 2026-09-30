import Foundation
import MeowMacUI

@main
enum MeowMacMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
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
