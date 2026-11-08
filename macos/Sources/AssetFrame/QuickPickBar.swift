import SwiftUI

/// 工具栏「轻量挑图」进入后常驻在筛选栏上方的那条栏。
/// 挑的结果写既有的颜色标签（绿/红/黄），因此撤销、颜色筛选和批量菜单都不用另建一套。
struct QuickPickBar: View {
    static let keepColor = "绿色"
    static let rejectColor = "红色"
    static let laterColor = "黄色"

    let scope: QuickPickScope
    let counts: QuickPickCounts
    let selectedCount: Int
    let canWrite: Bool
    let canEdit: Bool
    let onScope: (QuickPickScope) -> Void
    let onMark: (String) -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("轻量挑图", systemImage: "hare")
                .font(.callout.weight(.semibold))
                .fixedSize()

            ForEach(QuickPickBucket.allCases) { bucket in
                Button {
                    var next = scope
                    next.bucket = bucket
                    next.day = nil
                    onScope(next)
                } label: {
                    Text("\(bucket.rawValue) \(counts.buckets[bucket] ?? 0)")
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .pickStyle(scope.day == nil && scope.bucket == bucket)
                .help("\(bucket.rawValue)按日历日分桶；当前口径：\(scope.basis.rawValue)")
            }

            Button {
                var next = scope
                next.day = scope.day == nil ? Calendar.current.startOfDay(for: .now) : nil
                onScope(next)
            } label: {
                Label("指定日期", systemImage: "calendar")
            }
            .buttonStyle(.borderless)
            .pickStyle(scope.day != nil)
            .fixedSize()
            .help("只看选中的这一天；再点一次回到今天／昨天／前天／近7天。")

            if scope.day != nil {
                DatePicker("", selection: Binding(
                    get: { scope.day ?? Date.now },
                    set: { value in
                        var next = scope
                        next.day = value
                        onScope(next)
                    }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
                .help("按本地日历日筛选；口径跟随右边的「\(scope.basis.rawValue)」。")
            }

            Menu {
                ForEach(QuickPickBasis.allCases) { basis in
                    Button {
                        var next = scope
                        next.basis = basis
                        onScope(next)
                    } label: {
                        Label(basis.rawValue, systemImage: scope.basis == basis ? "checkmark" : "clock")
                    }
                }
            } label: {
                Text(scope.basis.rawValue).font(.callout)
            }
            .fixedSize()
            .help("按文件生成时间＝这几种图实际生成／保存的那天；按入库时间＝记录进资源库的那天。一次性补导入的历史图，两个口径会差很多。")

            Button {
                var next = scope
                next.unpickedOnly.toggle()
                onScope(next)
            } label: {
                Text(scope.unpickedOnly ? "只看没挑过的" : "含已挑过的")
            }
            .buttonStyle(.borderless)
            .pickStyle(scope.unpickedOnly)
            .help("没挑过＝还没有颜色标签。用这个跳过已经处理过的，而不是截断数量。")

            Divider().frame(height: 18)

            markButton(Self.keepColor, title: "要", symbol: "checkmark")
            markButton(Self.laterColor, title: "待定", symbol: "questionmark")
            markButton(Self.rejectColor, title: "不要", symbol: "xmark")

            Spacer(minLength: 8)

            Text("已挑 \(counts.picked) / \(counts.bucketTotal)　未挑 \(counts.unpicked)")
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(counts.bucketTotal > 0 && counts.unpicked == 0 ? Color.secondary : Color.primary)
            if counts.bucketTotal > 0 && counts.unpicked == 0 {
                Text("这一桶挑完了").font(.callout).foregroundStyle(.secondary)
            }
            if selectedCount > 0 {
                Text("选中 \(selectedCount)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("退出轻量") { if canEdit { onExit() } }
                .disabled(!canEdit)
                .help("退出后回到完整库；类型筛选会一起恢复成全部类型。")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private func markButton(_ color: String, title: String, symbol: String) -> some View {
        Button {
            onMark(color)
        } label: {
            Label(title, systemImage: symbol)
        }
        .disabled(!canWrite || !canEdit || selectedCount == 0)
        .help("把选中的 \(selectedCount) 张标为「\(title)」（颜色标签：\(color)）；可撤销，不写正式分类")
    }
}

private extension View {
    /// 桶与开关都用无边框按钮表达选中态，避免在这条栏里再引入一套控件样式。
    func pickStyle(_ selected: Bool) -> some View {
        foregroundStyle(selected ? Color.accentColor : Color.primary)
            .fontWeight(selected ? .semibold : .regular)
    }
}
