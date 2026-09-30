import Foundation
import MeowMacCore

public enum MoHistoryReader {
    public static func latest(executable: String) throws -> CleaningRecord? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["history", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return try MoHistoryParser.latest(data)
    }
}
