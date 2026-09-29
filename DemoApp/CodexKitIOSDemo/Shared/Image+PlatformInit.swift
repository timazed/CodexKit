import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
extension Image {
    init?(platformData: Data) {
        guard let image = UIImage(data: platformData) else { return nil }
        self.init(uiImage: image)
    }

    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif canImport(AppKit)
extension Image {
    init?(platformData: Data) {
        guard let image = NSImage(data: platformData) else { return nil }
        self.init(nsImage: image)
    }

    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif
