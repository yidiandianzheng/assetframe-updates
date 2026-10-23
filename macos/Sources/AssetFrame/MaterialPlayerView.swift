import SwiftUI
import AVKit

struct MaterialPlayerView: View {
    let material: MaterialRecord
    let cacheRoot: URL
    let onCover: (Double) -> Void
    let onRange: (Double, Double) -> Void
    @ObservedObject private var playback = MaterialPlaybackController.shared
    @State private var analysis = MaterialMediaAnalysis()
    @State private var videoFrames: [CachedMaterialVideoFrame] = []
    @State private var loading = true
    @State private var playbackHostID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if material.kind == .video {
                NativeMaterialVideoPlayer(player: playback.player).frame(minHeight: 200)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(videoFrames.indices, id: \.self) { i in
                            Button {
                                playback.attach(material, hostID: playbackHostID)
                                playback.seek(videoFrames[i].time)
                            } label: {
                                Image(nsImage: videoFrames[i].image).resizable().scaledToFit().frame(width: 85, height: 58)
                            }.buttonStyle(.plain).accessibilityLabel("跳到 \(videoFrames[i].time.formatted()) 秒")
                        }
                    }
                }
                Button("设当前帧为封面") { onCover(playback.time) }
            } else {
                Canvas { context, size in
                    for (i, peak) in analysis.waveform.enumerated() {
                        let x = size.width * Double(i) / Double(max(1, analysis.waveform.count))
                        let height = max(1, Double(min(1, peak)) * size.height)
                        context.fill(Path(CGRect(x: x, y: (size.height - height) / 2, width: max(1, size.width / 256), height: height)), with: .color(.accentColor))
                    }
                }.frame(height: 70).accessibilityLabel("音频波形；使用下方进度滑杆定位")
            }
            if loading { ProgressView("读取媒体预览…") }
            if let issue = playback.error ?? analysis.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(playback.playing ? "暂停" : "播放", systemImage: playback.playing ? "pause.fill" : "play.fill") {
                    playback.attach(material, hostID: playbackHostID)
                    playback.toggle()
                }
                Text(MaterialThumbnailView.durationText(playback.time)).monospacedDigit()
                Slider(value: Binding(get: { playback.time }, set: { playback.scrub(to: $0) }),
                       in: 0...max(0.1, material.mediaMetadata?.durationSeconds ?? 0),
                       onEditingChanged: { editing in
                           if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
                       })
                    .accessibilityLabel("播放位置")
            }
            HStack {
                Button("设入点") { playback.start = playback.time }
                Button("设出点") { playback.end = playback.time }
                Toggle("循环", isOn: $playback.loops)
            }
            Text("区间：\(playback.start.formatted(.number.precision(.fractionLength(2)))) — \(playback.end.formatted(.number.precision(.fractionLength(2)))) 秒").font(.caption)
            Button("将区间带入镜头引用") { onRange(playback.start, playback.end) }
                .disabled(playback.end <= playback.start)
        }
        .task(id: material.id) {
            guard !Task.isCancelled else { return }
            playback.attach(material, hostID: playbackHostID); loading = true
            analysis = MaterialMediaAnalysis(); videoFrames = []
            let worker = Task.detached(priority: .utility) { await MaterialMediaAnalysis.load(material, cacheRoot: cacheRoot) }
            let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled {
                analysis = value
                videoFrames = CachedMaterialVideoFrame.prepare(value)
                loading = false
            }
        }
        .onDisappear { playback.detach(hostID: playbackHostID) }
    }
}
