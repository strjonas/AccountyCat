import Foundation
import ScreenCaptureKit

func test() {
    Task {
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }
}
