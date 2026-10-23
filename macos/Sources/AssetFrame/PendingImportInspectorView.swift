import SwiftUI

struct PendingImportInspectorView: View {
    @ObservedObject var store: AssetStore
    let itemID: String?
    let onHide: () -> Void

    private var item: PendingImportItem? {
        itemID.flatMap(store.pendingImport(withID:))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("图片详情")
                        .font(.headline)
                    Text("当前查看的待导入图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("隐藏", systemImage: "sidebar.right", action: onHide)
                    .buttonStyle(.borderless)
                    .help("隐藏右侧图片详情；可用顶部的侧栏按钮恢复")
            }
            .padding(16)

            Divider()

            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Button {
                            preview(item)
                        } label: {
                            AssetInspectorPreview(asset: item.previewAsset, opensPreview: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看“\(item.name)”高清原图")
                        .accessibilityHint("在独立窗口中打开")
                        .help("点击查看高清原图")

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.title3)
                                .bold()
                                .lineLimit(2)
                            Text(item.originalFilename)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        PendingImportNameEditor(
                            itemID: item.id,
                            currentName: item.name,
                            onSave: { store.updatePendingImport(item.id, preferredName: $0) }
                        )

                        HStack(spacing: 10) {
                            Label(item.resolutionLabel, systemImage: "sparkles.rectangle.stack")
                            Text(item.dimensionText)
                            Spacer()
                        }
                        .font(.callout)

                        GroupBox("资产分类") {
                            VStack(spacing: 10) {
                                Picker("资产类型", selection: typeBinding(item.id)) {
                                    ForEach(AssetType.allCases) { type in
                                        Text(type.rawValue).tag(type)
                                    }
                                }
                                Picker("资产归类", selection: categoryBinding(item.id)) {
                                    ForEach(AssetCategory.allCases) { category in
                                        Text(category.rawValue).tag(category)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }

                        GroupBox("标签") {
                            AssetTagEditor(
                                tags: item.normalizedManualTags,
                                suggestions: store.availableTags,
                                onChange: { store.updatePendingImport(item.id, manualTags: $0) }
                            )
                            .padding(.top, 4)
                        }

                        if let provenance = item.generationProvenance {
                            GroupBox("Codex 生成谱系") {
                                GenerationProvenanceDetailsView(
                                    provenance: provenance,
                                    batch: store.generationBatch(for: item)
                                )
                                .padding(.top, 4)
                            }
                        }

                        Divider()

                        LabeledContent("添加日期") {
                            Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                        }
                        LabeledContent("创建日期") {
                            if let sourceCreatedAt = item.sourceCreatedAt {
                                Text(sourceCreatedAt, format: .dateTime.year().month().day().hour().minute())
                            } else {
                                Text("待识别")
                            }
                        }
                        LabeledContent("修改日期") {
                            if let sourceModifiedAt = item.sourceModifiedAt {
                                Text(sourceModifiedAt, format: .dateTime.year().month().day().hour().minute())
                            } else {
                                Text("待识别")
                            }
                        }
                        LabeledContent("原图位置") {
                            Text(item.originalSourcePath)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(4)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        LabeledContent("文件状态") {
                            Text(pendingSourceExists(item) ? "原图可用" : "原图待重新定位")
                                .foregroundStyle(pendingSourceExists(item) ? Color.secondary : Color.orange)
                        }

                        HStack {
                            Button("查看高清原图", systemImage: "arrow.up.left.and.arrow.down.right") {
                                preview(item)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("在 Finder 中显示", systemImage: "folder") {
                                store.revealPendingImportSource(item.id)
                            }
                            .buttonStyle(.bordered)
                            if !pendingSourceExists(item) {
                                Button("重新定位", systemImage: "link.badge.plus") {
                                    store.relinkPendingImportSource(item.id)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .scrollIndicators(.visible)
            } else {
                ContentUnavailableView(
                    "选择一张图片",
                    systemImage: "photo.on.rectangle",
                    description: Text("点击待导入列表中的图片，右侧会显示大图、尺寸和分类")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func typeBinding(_ id: String) -> Binding<AssetType> {
        Binding(
            get: { store.pendingImport(withID: id)?.suggestedType ?? .unclassified },
            set: { store.updatePendingImport(id, type: $0) }
        )
    }

    private func categoryBinding(_ id: String) -> Binding<AssetCategory> {
        Binding(
            get: { store.pendingImport(withID: id)?.category ?? .pending },
            set: { store.updatePendingImport(id, category: $0) }
        )
    }

    private func preview(_ item: PendingImportItem) {
        AssetPreviewWindowController.shared.show(asset: item.previewAsset)
    }

    private func pendingSourceExists(_ item: PendingImportItem) -> Bool {
        FileManager.default.fileExists(atPath: item.originalSourcePath)
            || FileManager.default.fileExists(atPath: item.stagedPath)
    }
}
