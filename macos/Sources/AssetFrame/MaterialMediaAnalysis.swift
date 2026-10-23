import Foundation
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct MaterialMediaAnalysis: Codable, Sendable {
    var waveform: [Float] = []
    var frames: [Data] = []
    var times: [Double] = []
    var issue: String?

    static func load(_ material: MaterialRecord, cacheRoot: URL) async -> MaterialMediaAnalysis {
        let identity = "\(material.fingerprint)|\(material.sourceModifiedAt?.timeIntervalSince1970 ?? 0)|v1"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = cacheRoot.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: cache), let result = try? JSONDecoder().decode(Self.self, from: data) { SSDPreviewCache.recordAccess(cache); return result }
        guard let path = material.sourcePath else { return Self(issue: "文件缺失") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        var result = Self()
        do {
            try Task.checkCancellation()
            guard try await asset.load(.isPlayable) else { return Self(issue: "编码不支持或媒体损坏；可尝试系统预览") }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return Self(issue: "无法读取有效时长") }
            if material.kind == .video {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 160)
                for index in 0..<8 {
                    try Task.checkCancellation()
                    let time = duration * Double(index) / 8
                    let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                    let data = NSMutableData()
                    if let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, frame.image, nil)
                        if CGImageDestinationFinalize(destination) { result.frames.append(data as Data); result.times.append(time) }
                    }
                }
            }
            if material.kind == .audio, let track = try await asset.loadTracks(withMediaType: .audio).first {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { return Self(issue: "该音频无法生成波形") }
                reader.add(output)
                guard reader.startReading() else { return Self(issue: reader.error?.localizedDescription ?? "无法读取音频") }
                var peaks = [Float](repeating: 0, count: 256)
                while reader.status == .reading {
                    if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                    let hasSample = autoreleasepool { () -> Bool in
                        guard let sample = output.copyNextSampleBuffer() else { return false }
                        guard let block = CMSampleBufferGetDataBuffer(sample) else { return true }
                        let size = CMBlockBufferGetDataLength(block)
                        var floats = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
                        let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
                        guard status == kCMBlockBufferNoErr else { return true }
                        let base = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        for (i, value) in floats.enumerated() where value.isFinite {
                            let bin = min(255, max(0, Int((base + Double(i) / 8000) / duration * 256)))
                            peaks[bin] = max(peaks[bin], abs(value))
                        }
                        return true
                    }
                    if !hasSample { break }
                }
                if reader.status == .failed { throw reader.error ?? NSError(domain: "MediaReader", code: 1) }
                result.waveform = peaks
            }
            try Task.checkCancellation()
            guard SSDPreviewCache.prepare(cacheRoot) else { return result }
            _ = SSDPreviewCache.write(try JSONEncoder().encode(result), to: cache)
        } catch is CancellationError { return Self(issue: "已取消") }
        catch { result.issue = error.localizedDescription }
        return result
    }
}
