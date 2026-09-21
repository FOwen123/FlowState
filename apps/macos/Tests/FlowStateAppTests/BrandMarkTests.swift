import AppKit
import SwiftUI
import Testing
@testable import FlowStateApp

@Test("menu-bar brand uses a correctly sized native template image")
@MainActor func menuBarBrandUsesNativeTemplate() throws {
    let image = FlowStateBrandMark.menuBarImage
    #expect(image.isTemplate)
    #expect(image.size == NSSize(width: 22, height: 22))
    let data = try #require(image.tiffRepresentation)
    let raster = try #require(NSBitmapImageRep(data: data))
    // The openings between the waves must remain transparent, not a filled disc.
    #expect(try #require(raster.colorAt(x: raster.pixelsWide / 2, y: raster.pixelsHigh / 2)).alphaComponent < 0.05)
    #expect(try #require(raster.colorAt(x: raster.pixelsWide / 2, y: raster.pixelsHigh / 8)).alphaComponent > 0.9)
}

@Test("the settings brand mark renders visible artwork")
@MainActor func settingsBrandMarkRendersArtwork() throws {
    let renderer = ImageRenderer(content: FlowStateBrandMark(size: 30).foregroundStyle(.white))
    let image = try #require(renderer.cgImage)
    let raster = NSBitmapImageRep(cgImage: image)
    var visiblePixels = 0
    for y in 0..<raster.pixelsHigh {
        for x in 0..<raster.pixelsWide {
            if (raster.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { visiblePixels += 1 }
        }
    }
    #expect(visiblePixels > 80)
    #expect(visiblePixels < 600)
}
