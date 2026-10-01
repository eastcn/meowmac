import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum QuotaColorTests {
    static func palette() -> Bool {
        func matches(_ provider: QuotaProvider, _ rgb: [Double]) -> Bool {
            guard let color = QuotaPalette.color(provider).usingColorSpace(.sRGB) else { return false }
            return zip([color.redComponent, color.greenComponent, color.blueComponent], rgb).allSatisfy { abs(Double($0) - $1 / 255) < 0.001 }
        }
        guard matches(.claude, [217, 119, 87]), matches(.deepseek, [77, 107, 254]),
              QuotaPalette.color(.opencodego) == NSColor.systemGray else { return false }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var valid = false
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let actual = QuotaPalette.color(.codex).usingColorSpace(.sRGB)
                let expected = NSColor.labelColor.usingColorSpace(.sRGB)
                valid = actual == expected
            }
            guard valid else { return false }
        }
        return QuotaPalette.peakOpacity(usedPercent: 81, isCurrent: false) == 1
            && QuotaPalette.peakOpacity(usedPercent: 80, isCurrent: false) == 0.55
            && QuotaPalette.peakOpacity(usedPercent: 90, isCurrent: true) == 0.28
    }
}
