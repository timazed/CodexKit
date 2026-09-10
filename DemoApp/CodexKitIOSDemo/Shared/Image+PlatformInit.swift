import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif canImport(AppKit)
extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif
