import Foundation
import MeowMacCore
import MeowMacUI

enum CatPackageTests {
    static func core() -> Bool {
        do {
            let fixture = try Data(contentsOf: URL(fileURLWithPath: "Sources/MeowMacUI/Resources/Cats/builtin.slim.cat/manifest.json"))
            guard let object = try JSONSerialization.jsonObject(with: fixture) as? [String: Any] else { return false }
            func rejected(_ edit: (inout [String: Any]) -> Void) -> Bool {
                var altered = object; edit(&altered)
                guard let bytes = try? JSONSerialization.data(withJSONObject: altered, options: [.fragmentsAllowed]) else { return false }
                return (try? CatPackage.parse(bytes, builtin: true)) == nil
            }
            guard (try CatPackage.parse(fixture, builtin: true)).frames.count == 5,
                  rejected({ $0["unexpected"] = true }), rejected({ $0.removeValue(forKey: "name") }),
                  rejected({ $0["schemaVersion"] = 2 }), rejected({ $0["schemaVersion"] = "1" }),
                  rejected({ $0["id"] = "../escape" }), rejected({ $0["name"] = "\n" }),
                  rejected({ root in
                      var run = root["run"] as! [String: Any]
                      run["topPadding"] = Int.max; root["run"] = run
                  }),
                  rejected({ $0["run"] = ["image": "/tmp/escape.png"] }),
                  rejected({ root in
                      var severe = root["severe"] as! [String: Any]
                      severe["zzAnchorFraction"] = "NaN"; root["severe"] = severe
                  }), rejected({ root in
                      var severe = root["severe"] as! [String: Any]
                      severe["bounds"] = [0, 0, 3000, 3000]; root["severe"] = severe
                  }), rejected({ root in
                      var run = root["run"] as! [String: Any]
                      run["frames"] = []; root["run"] = run
                  }) else { return false }
            return true
        } catch { print("清单测试失败：\(error)"); return false }
    }

    static func ui() -> Bool {
        do {
            for id in CatPackageLoader.builtinIDs {
                let cat = try CatPackageLoader.builtin(id)
                guard cat.id == id, cat.run.width == cat.package.runSize[0], cat.severe.height == cat.package.severeSize[1] else { return false }
            }
            let root = URL(fileURLWithPath: "build/acceptance/cat-tests/package-fixture", isDirectory: true)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
            let original = URL(fileURLWithPath: "Sources/MeowMacUI/Resources/Cats/builtin.slim.cat", isDirectory: true)
            func reset() throws {
                if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
                try fileManager.copyItem(at: original, to: root)
            }
            func rejects(_ mutate: () throws -> Void) throws -> Bool {
                try reset(); try mutate()
                return (try? CatPackageLoader.load(at: root, builtin: true)) == nil
            }
            guard try rejects({ try Data("bad".utf8).write(to: root.appendingPathComponent("run.png")) }),
                  try rejects({ try Data().write(to: root.appendingPathComponent("run.png")) }),
                  try rejects({ try Data().write(to: root.appendingPathComponent("manifest.json")) }),
                  try rejects({
                      let manifest = root.appendingPathComponent("manifest.json")
                      var value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
                      var severe = value["severe"] as! [String: Any]
                      severe["image"] = "run.png"; value["severe"] = severe
                      try JSONSerialization.data(withJSONObject: value).write(to: manifest)
                      try fileManager.removeItem(at: root.appendingPathComponent("severe.png"))
                  }),
                  try rejects({ try Data().write(to: root.appendingPathComponent("extra")) }),
                  try rejects({
                      try fileManager.removeItem(at: root.appendingPathComponent("run.png"))
                      try fileManager.createSymbolicLink(at: root.appendingPathComponent("run.png"), withDestinationURL: original.appendingPathComponent("run.png"))
                  }),
                  try rejects({
                      try Data(repeating: 0, count: 65_537).write(to: root.appendingPathComponent("manifest.json"))
                  }) else { return false }
            try reset()
            let link = root.deletingLastPathComponent().appendingPathComponent("root-link.cat")
            if fileManager.fileExists(atPath: link.path) { try fileManager.removeItem(at: link) }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: root)
            defer { try? fileManager.removeItem(at: link) }
            return (try? CatPackageLoader.load(at: link, builtin: true)) == nil
        } catch { print("资源测试失败：\(error)"); return false }
    }
}
