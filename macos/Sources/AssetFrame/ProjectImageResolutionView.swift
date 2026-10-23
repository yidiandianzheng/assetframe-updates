import SwiftUI

struct ProjectImageResolutionView: View {
    let material: MaterialRecord
    @State private var resolution: ProjectImageResolution?
    private var known: ProjectImageResolution? {
        guard let width = material.mediaMetadata?.pixelWidth, let height = material.mediaMetadata?.pixelHeight,
              width > 0, height > 0 else { return nil }
        return .init(width: width, height: height)
    }
    var body: some View {
        Text((known ?? resolution)?.label ?? "分辨率：暂不可读取")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .task(id: "\(material.sourcePath ?? "")|\(material.fileSize ?? 0)") {
                resolution = nil
                guard known == nil, let path = material.sourcePath else { return }
                let value = await Task.detached(priority: .utility) { ProjectImageResolution.read(path: path) }.value
                if !Task.isCancelled { resolution = value }
            }
    }
}
