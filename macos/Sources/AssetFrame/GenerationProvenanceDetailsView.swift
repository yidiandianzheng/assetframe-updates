import SwiftUI

struct GenerationProvenanceDetailsView: View {
    let provenance: GenerationProvenance
    let batch: GenerationBatchRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("来源", value: provenance.generationPlatform)
            LabeledContent("Codex任务", value: provenance.taskTitle)
            LabeledContent("生成批次", value: provenance.batchID)
            LabeledContent("生成方式", value: provenance.operation.displayName)
            LabeledContent("候选位置", value: provenance.candidateLabel)
            if let modelName = provenance.modelName {
                LabeledContent("实际模型", value: modelName)
            }
            if provenance.parentBatchID != nil
                || provenance.parentAssetID != nil
                || provenance.parentFingerprint != nil {
                LabeledContent("父级来源") {
                    Text(parentLabel)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("生成时间") {
                Text(provenance.generatedAt, format: .dateTime.year().month().day().hour().minute().second())
            }
            if let batch, !batch.prompt.isEmpty {
                DisclosureGroup("完整提示词") {
                    Text(batch.prompt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
            LabeledContent("内容指纹") {
                Text(provenance.contentSHA256)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var parentLabel: String {
        [
            provenance.parentBatchID.map { "批次 \($0)" },
            provenance.parentAssetID.map { "资产 \($0)" },
            provenance.parentFingerprint.map { "指纹 \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
