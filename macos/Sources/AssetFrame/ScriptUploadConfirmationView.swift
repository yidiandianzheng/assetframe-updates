import SwiftUI

struct ScriptUploadConfirmationView: View {
    let consent: ScriptUploadConsent
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(consent.isDuplicate ? "重新分析这份剧本？" : "上传剧本文字进行查缺？", systemImage: "doc.text.magnifyingglass")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("文件", value: consent.url.lastPathComponent)
                LabeledContent("文字量", value: "\(consent.characterCount) 字")
                LabeledContent("预计请求", value: "\(consent.chunkCount) 段")
            }

            if consent.isDuplicate {
                Label("软件中已有相同文本的拆解记录。继续会新增一份记录，不覆盖旧清单。", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.orange)
            }

            Label("只上传你主动选择的剧本文字，不上传图片。DeepSeek只生成候选清单，正式资产和主图必须人工绑定。", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(consent.isDuplicate ? "确认重新分析" : "确认上传并分析", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
