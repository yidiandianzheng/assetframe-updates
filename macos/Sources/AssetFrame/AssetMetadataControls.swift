import SwiftUI

struct AssetRatingControl: View {
    let rating: Int
    var compact = false
    let onChange: (Int) -> Void
    @State private var hoveredRating: Int?

    private var previewRating: Int { hoveredRating ?? rating }

    var body: some View {
        HStack(spacing: compact ? 1 : 3) {
            ForEach(1...5, id: \.self) { value in
                Button("设置为 \(value) 星", systemImage: value <= previewRating ? "star.fill" : "star") {
                    onChange(AssetRatingInteraction.rating(current: rating, selecting: value))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(compact ? .caption : .title3)
                .foregroundStyle(value <= previewRating ? GraphiteTheme.star : Color.secondary)
                .frame(width: compact ? 18 : 24, height: compact ? 24 : 28)
                .contentShape(Rectangle())
                .onHover { isHovering in hoveredRating = isHovering ? value : nil }
                .accessibilityLabel("设置为 \(value) 星")
                .accessibilityValue(value == rating ? "当前评分" : "")
                .help(value == 5 ? "点击设为 5 星，并复制到 SSD 资产库" : "点击设为 \(value) 星")
            }

            if !compact {
                Text(previewRating == 0 ? "未评分" : "\(previewRating) 星")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                if rating > 0 {
                    Button("清除评分", systemImage: "xmark.circle") {
                        onChange(AssetRatingInteraction.clearedRating())
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除评分")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("素材评分")
        .accessibilityValue(rating == 0 ? "未评分" : "\(rating) 星")
    }
}

struct AssetTagEditor: View {
    let tags: [String]
    let suggestions: [String]
    let onChange: ([String]) -> Void
    @State private var draft = ""

    private let columns = [GridItem(.adaptive(minimum: 82), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tags.isEmpty {
                Text("还没有标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Text(tag).lineLimit(1)
                            Button {
                                onChange(tags.filter { $0 != tag })
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除标签 \(tag)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("输入标签，按回车添加", text: $draft)
                    .onSubmit(addDraft)
                Button("添加标签", systemImage: "plus", action: addDraft)
                    .labelStyle(.iconOnly)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            let unusedSuggestions = suggestions.filter { !tags.contains($0) }
            if !unusedSuggestions.isEmpty {
                Menu("从已有标签选择", systemImage: "tag") {
                    ForEach(unusedSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { add(suggestion) }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func addDraft() {
        let values = draft
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return }
        onChange(Array(Set(tags + values)).sorted())
        draft = ""
    }

    private func add(_ tag: String) {
        onChange(Array(Set(tags + [tag])).sorted())
    }
}

struct MasterAssetControl: View {
    let isMaster: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isMaster)
        } label: {
            Label(isMaster ? "已加入通用资产" : "加入通用资产", systemImage: isMaster ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isMaster ? .indigo : .accentColor)
        .help("加入跨项目通用资产库，并额外复制到 SSD 受管目录；原图始终保留")
    }
}
