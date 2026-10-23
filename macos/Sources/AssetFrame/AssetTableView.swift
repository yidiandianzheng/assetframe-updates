import SwiftUI

struct AssetTableView: View {
    @ObservedObject var store: AssetStore
    let assets: [AssetItem]
    @ObservedObject var selectionModel: WorkspaceSelectionModel
    let onRequestRemoval: (Set<String>) -> Void

    @AppStorage("assetTable.preset") private var preset: AssetTableViewPreset = .all
    @AppStorage("assetTable.groupBy") private var groupBy: AssetTableGroupOption = .none
    @AppStorage("assetTable.imageScale") private var imageScale: AssetTableImageScale = .standard

    private var fields: [AssetTableField] { preset.fields }
    private var tableWidth: CGFloat {
        fields.reduce(0) { $0 + $1.width(imageScale: imageScale) }
    }
    private var sections: [AssetTableSection] { groupBy.sections(from: assets) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.rawValue)
                        .font(.title2)
                        .bold()
                    Text("\(preset.subtitle) · \(assets.count) 条记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("图片大小", selection: $imageScale) {
                    ForEach(AssetTableImageScale.allCases) { scale in
                        Text(scale.rawValue).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 172)
                .help("调整表格图片和行高")
            }
            .padding(18)

            Divider()

            HStack(spacing: 12) {
                Label("表格视图", systemImage: "rectangle.3.group")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("表格视图", selection: $preset) {
                    ForEach(AssetTableViewPreset.allCases) { view in
                        Text(view.rawValue).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)

                Menu(groupBy.rawValue, systemImage: groupBy.systemImage) {
                    ForEach(AssetTableGroupOption.allCases) { option in
                        Button {
                            groupBy = option
                        } label: {
                            if option == groupBy {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                }

                Spacer()
                Text("显示 \(fields.count) 个字段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            if assets.isEmpty {
                ContentUnavailableView(
                    "当前视图没有记录",
                    systemImage: "tablecells",
                    description: Text("可调整上方筛选条件，或先将图片加入快速筛图")
                )
            } else {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(sections) { section in
                                    if groupBy != .none {
                                        AssetTableGroupHeader(
                                            title: section.title,
                                            count: section.assets.count,
                                            width: max(tableWidth, geometry.size.width),
                                            systemImage: groupBy.systemImage
                                        )
                                    }
                                    ForEach(section.assets) { asset in
                                        AssetTableRow(
                                            store: store,
                                            asset: asset,
                                            fields: fields,
                                            imageScale: imageScale,
                                            isSelected: selectionModel.selectedIDs.contains(asset.id),
                                            onSelect: { selectionModel.selectPrimary(asset.id) },
                                            onDelete: { onRequestRemoval([asset.id]) }
                                        )
                                        Divider()
                                    }
                                }
                            } header: {
                                AssetTableHeader(fields: fields, imageScale: imageScale, minimumWidth: geometry.size.width)
                            }
                        }
                        .frame(width: max(tableWidth, geometry.size.width), alignment: .topLeading)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: preset) { _, newPreset in
            groupBy = newPreset.defaultGroup
        }
        .onAppear {
            selectionModel.reconcile(visibleIDs: assets.map(\.id))
        }
        .onChange(of: assets.map(\.id)) { _, visibleIDs in
            selectionModel.reconcile(visibleIDs: visibleIDs)
        }
        .onDeleteCommand {
            guard !selectionModel.selectedIDs.isEmpty else { return }
            onRequestRemoval(selectionModel.selectedIDs)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up, .left: selectionModel.movePrimary(by: -1)
            case .down, .right: selectionModel.movePrimary(by: 1)
            @unknown default: break
            }
        }
        .onKeyPress(.space) {
            guard let id = selectionModel.primaryID else { return .ignored }
            NotificationCenter.default.post(name: .previewAssetImage, object: nil, userInfo: ["id": id])
            return .handled
        }
    }
}
