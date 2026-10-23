import AppKit

/// Decode the small filmstrip once per completed analysis, rather than every
/// playback-clock refresh. Keep each timestamp paired with its decoded image.
@MainActor
struct CachedMaterialVideoFrame {
    let image: NSImage
    let time: Double

    static func prepare(_ analysis: MaterialMediaAnalysis) -> [Self] {
        zip(analysis.frames, analysis.times).compactMap { data, time in
            guard time.isFinite, let image = NSImage(data: data) else { return nil }
            return Self(image: image, time: time)
        }
    }
}
