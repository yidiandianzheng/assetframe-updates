import SwiftUI

struct LibraryAuditView: View {
    @ObservedObject var store: AssetStore
    @State private var showAISettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 580)
        .sheet(isPresented: $showAISettings) {
            DeepSeekSettingsView(
                task: .libraryAudit,
                startsAfterSave: true,
                usageDescription: "只上传本地规则发现的问题及相关文字字段，不上传图片、绝对路径、调用编号、版本或文件指纹。",
                onSave: { configuration in
                    showAISettings = false
                    store.startLibraryAuditAI(configuration: configuration)
                },
                onCancel: { showAISettings = false }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("资产体检")
                        .font(.title2)
                        .bold()
                    Text(store.libraryAuditSession?.scopeDescription ?? "当前资产范围")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLibraryAuditAnalyzing {
                    Button("取消AI解释", action: store.cancelLibraryAuditAI)
                } else if !(store.libraryAuditSession?.issues.isEmpty ?? true) {
                    Button("AI生成修复建议", systemImage: "sparkles", action: startAI)
                        .buttonStyle(.borderedProminent)
                }
                Button("关闭", action: store.dismissLibraryAudit)
                    .keyboardShortcut(.cancelAction)
            }
            if let session = store.libraryAuditSession {
                HStack(spacing: 8) {
                    if session.isAnalyzing { ProgressView().controlSize(.small) }
                    Text(session.message)
                        .font(.callout)
                        .foregroundStyle(session.phase == .failed ? Color.red : Color.secondary)
                }
            }
            Label("AI只能建议名称、类型、标签和说明；不能删除资产、换主图、锁定形态或修改受保护字段。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    @ViewBuilder private var content: some View {
        if let session = store.libraryAuditSession, !session.issues.isEmpty {
            List(session.issues) { issue in
                let suggestion = session.suggestions.first { $0.issueID == issue.id }
                LibraryAuditIssueRow(
                    issue: issue,
                    suggestion: suggestion,
                    isApplied: session.appliedSuggestionIDs.contains(issue.id),
                    onApply: { store.applyLibraryAuditSuggestion(issue.id) }
                )
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView(
                "本地规则未发现问题",
                systemImage: "checkmark.shield",
                description: Text("当前范围没有源文件、分类、审核、4K目标或形态裁定风险")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func startAI() {
        guard let configuration = DeepSeekAPISettings.storedConfiguration(for: .libraryAudit) else {
            showAISettings = true
            return
        }
        store.startLibraryAuditAI(configuration: configuration)
    }
}
