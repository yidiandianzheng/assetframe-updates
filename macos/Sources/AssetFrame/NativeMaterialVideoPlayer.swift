import AVKit
import SwiftUI

/// Avoid the SwiftUI VideoPlayer bridge, which aborts while initializing its
/// superclass metadata on the user's current macOS runtime.
@MainActor
struct NativeMaterialVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        Self.makePlayerView(player: player)
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Playback progress updates SwiftUI frequently; assigning the same
        // player again should not rebuild AVKit's presentation pipeline.
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        // The shared controller owns playback. An outgoing view must only
        // detach, without pausing a newly selected item's shared player.
        view.player = nil
    }

    static func makePlayerView(player: AVPlayer) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
}
