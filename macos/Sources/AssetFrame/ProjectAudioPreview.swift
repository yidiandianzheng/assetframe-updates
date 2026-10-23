import SwiftUI
import AVFoundation

struct ProjectAudioPreview: View {
    let media: ProjectWorkbenchIndex.Media
    @ObservedObject private var playback = MaterialPlaybackController.shared
    @State private var host = UUID()
    @State private var duration = 0.0
    private var active: Bool { playback.currentMaterialID == media.material.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(active && playback.playing ? "暂停试听" : "试听声音", systemImage: active && playback.playing ? "pause.fill" : "play.fill") {
                    playback.attach(media.material, hostID: host); playback.toggle()
                }.disabled(!media.exists)
                Text(media.material.name).font(.caption).lineLimit(2)
            }
            if active {
                HStack {
                    Text(MaterialThumbnailView.durationText(playback.time)).monospacedDigit().font(.caption)
                    Slider(value: Binding(get: { playback.time }, set: { playback.scrub(to: $0) }), in: 0...max(duration, 0.1), onEditingChanged: {
                        if $0 { playback.beginScrubbing() } else { playback.endScrubbing() }
                    }).accessibilityLabel("声音试听进度")
                    Text(MaterialThumbnailView.durationText(duration)).monospacedDigit().font(.caption)
                }
                if let error = playback.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Text(media.exists ? media.status : "声音文件失联").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: media.id) {
            guard media.exists, let path = media.material.sourcePath else { return }
            if let time = try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration), time.seconds.isFinite { duration = time.seconds }
        }
        .onDisappear { playback.detach(hostID: host) }
    }
}
