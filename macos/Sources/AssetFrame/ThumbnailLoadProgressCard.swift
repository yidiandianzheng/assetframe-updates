import SwiftUI

struct ThumbnailLoadProgressCard: View {
    let progress: ThumbnailLoadProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在读取图片预览")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(progress.completed) / \(progress.total) · \(progress.remainingText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
            Text(progress.failed == 0 ? "后台生成首屏及附近缩略图，可以继续操作" : "有 \(progress.failed) 项预览读取失败，原素材记录仍保留")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 350)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("图片预览读取进度 \(progress.completed) / \(progress.total)，\(progress.remainingText)")
    }
}
