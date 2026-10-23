import AppKit
import SwiftUI

@MainActor
enum GraphiteTheme {
    static var accent: Color { Color(red: 0.16, green: 0.59, blue: 1.0) }
    static var star: Color { Color(red: 1.0, green: 0.80, blue: 0.0) }
    static var panelText: Color { Color(nsColor: .labelColor) }
    static var panelSecondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    static var panelMutedText: Color { Color(nsColor: .tertiaryLabelColor) }
    static var panelStroke: Color { Color(nsColor: .separatorColor) }

    static var canvas: Color { Color(nsColor: canvasNSColor) }
    static var sidebar: Color { Color(nsColor: sidebarNSColor) }
    static var inspector: Color { Color(nsColor: inspectorNSColor) }
    static var toolbar: Color { Color(nsColor: toolbarNSColor) }
    static var card: Color { Color(nsColor: cardNSColor) }
    static var assetWell: Color { Color(nsColor: assetWellNSColor) }
    static var previewCanvas: Color { Color(nsColor: previewCanvasNSColor) }

    static var canvasNSColor: NSColor {
        dynamicColor(name: "AssetFrame.Graphite.Canvas", light: .windowBackgroundColor, dark: rgb(0x17, 0x17, 0x19))
    }

    static var sidebarNSColor: NSColor {
        dynamicColor(name: "AssetFrame.Graphite.Sidebar", light: .controlBackgroundColor, dark: rgb(0x20, 0x21, 0x24))
    }

    static var inspectorNSColor: NSColor {
        dynamicColor(name: "AssetFrame.Graphite.Inspector", light: .controlBackgroundColor, dark: rgb(0x1D, 0x1E, 0x21))
    }

    static var toolbarNSColor: NSColor {
        dynamicColor(name: "AssetFrame.Graphite.Toolbar", light: .windowBackgroundColor, dark: rgb(0x1C, 0x1D, 0x20))
    }

    static var cardNSColor: NSColor {
        dynamicColor(name: "AssetFrame.Graphite.Card", light: .controlBackgroundColor, dark: rgb(0x29, 0x2B, 0x30))
    }

    static var assetWellNSColor: NSColor {
        dynamicColor(name: "AssetFrame.Graphite.AssetWell", light: .white, dark: rgb(0x22, 0x23, 0x27))
    }

    static var previewCanvasNSColor: NSColor {
        dynamicColor(
            name: "AssetFrame.Graphite.PreviewCanvas",
            light: rgb(0x12, 0x12, 0x14),
            dark: rgb(0x0D, 0x0E, 0x10)
        )
    }

    private static func dynamicColor(name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}
