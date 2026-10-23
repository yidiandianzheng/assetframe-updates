import SwiftUI

struct ProjectLoadContentContainer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isLoading: Bool
    let showsProgress: Bool
    let progress: ProjectLoadProgress?
    let errorMessage: String?
    let retry: () -> Void
    let revealProjectData: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
                .allowsHitTesting(!isLoading && errorMessage == nil)
                .accessibilityHidden(isLoading || errorMessage != nil)

            if let errorMessage {
                GraphiteTheme.canvas
                    .ignoresSafeArea()
                    .transition(.opacity)
                failureView(message: errorMessage)
                    .transition(.opacity)
            } else if isLoading, showsProgress, let progress {
                GraphiteTheme.canvas
                    .ignoresSafeArea()
                    .transition(.opacity)
                ProjectLoadingPlaceholder(progress: progress)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isLoading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsProgress)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: errorMessage)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            QueryAwareEmptyState(
                kind: .loadFailure,
                primaryActionTitle: "重试",
                primaryAction: retry,
                secondaryActionTitle: "在 Finder 中显示项目数据",
                secondaryAction: revealProjectData
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .textSelection(.enabled)
        }
        .padding(28)
    }
}

private struct ProjectLoadingPlaceholder: View {
    let progress: ProjectLoadProgress

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0..<16, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(index.isMultiple(of: 3) ? GraphiteTheme.card : GraphiteTheme.assetWell)
                            .aspectRatio(1.12, contentMode: .fit)
                    }
                }
                .padding(18)
            }
            .allowsHitTesting(false)
            .opacity(0.55)

            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(progress.projectName)
                    .font(.headline)
                    .lineLimit(1)
                Text(progress.stage.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 240)
                    Text("\(progress.completed.formatted()) / \((progress.total ?? 0).formatted())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在打开项目 \(progress.projectName)，\(progress.stage.statusText)")
    }
}
