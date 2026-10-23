import SwiftUI

struct FileFormatFilterPopover: View {
    @Binding var selectedFormats: Set<String>
    let counts: [String: Int]
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("文件格式", systemImage: "doc.badge.ellipsis")
                    .font(.headline)
                    .foregroundStyle(GraphiteTheme.panelText)
                Spacer()
                if !selectedFormats.isEmpty {
                    Button("清除", systemImage: "xmark.circle") {
                        selectedFormats.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(GraphiteTheme.accent)
                }
            }

            TextField("搜索格式…", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索文件格式")

            if visibleFormats.isEmpty {
                ContentUnavailableView("没有匹配的格式", systemImage: "doc.text.magnifyingglass")
                    .frame(height: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleFormats, id: \.self) { format in
                            formatRow(format)
                        }
                    }
                }
                .frame(maxHeight: 310)
            }

            Text("这里只显示当前范围内实际存在的格式；主画册只统计图片，MP3 等音频请在“素材总库”查看。")
                .font(.caption)
                .foregroundStyle(GraphiteTheme.panelSecondaryText)
        }
        .padding(16)
        .frame(width: 270)
        .background(GraphiteTheme.inspector)
        .foregroundStyle(GraphiteTheme.panelText)
    }

    private var visibleFormats: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return counts.keys
            .filter { query.isEmpty || $0.localizedStandardContains(query) }
            .sorted { lhs, rhs in
                let leftCount = counts[lhs, default: 0]
                let rightCount = counts[rhs, default: 0]
                return leftCount == rightCount ? lhs < rhs : leftCount > rightCount
            }
    }

    private func formatRow(_ format: String) -> some View {
        let selected = selectedFormats.contains(format)
        return Button {
            if selected {
                selectedFormats.remove(format)
            } else {
                selectedFormats.insert(format)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? GraphiteTheme.accent : GraphiteTheme.panelSecondaryText)
                    .frame(width: 16)
                Text(format.uppercased())
                    .font(.callout.monospaced())
                    .foregroundStyle(GraphiteTheme.panelText)
                Spacer()
                Text(counts[format, default: 0], format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(GraphiteTheme.panelSecondaryText)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(selected ? GraphiteTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(format.uppercased())，\(counts[format, default: 0]) 项")
        .accessibilityValue(selected ? "已选择" : "未选择")
    }
}
