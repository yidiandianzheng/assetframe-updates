import AppKit

@MainActor
enum GalleryCardChrome {
    static let cornerRadius: CGFloat = 7

    static func backgroundColor(isSelected: Bool) -> NSColor {
        isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.10) : .clear
    }

    static func borderColor(isSelected: Bool) -> NSColor {
        isSelected ? .controlAccentColor : .clear
    }

    static func borderWidth(isSelected: Bool) -> CGFloat {
        isSelected ? 2 : 0
    }
}
