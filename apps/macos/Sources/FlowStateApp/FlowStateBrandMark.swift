import SwiftUI

struct FlowStateBrandMark: View {
    var size: CGFloat = 32

    // MenuBarExtra needs the image's native point size; a resizable SwiftUI
    // wrapper does not reliably constrain the status-item image on macOS.
    static let menuBarImage: NSImage = {
        let url = Bundle.module.url(forResource: "FlowStateLogo", withExtension: "png")!
        let image = NSImage(contentsOf: url)!
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.menuBarImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
