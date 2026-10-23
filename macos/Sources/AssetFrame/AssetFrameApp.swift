import SwiftUI

@main
struct AssetFrameApp: App {
    @NSApplicationDelegateAdaptor(MaterialAppDelegate.self) private var appDelegate
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.defaultValue.rawValue
    @StateObject private var updateController = UpdateController()
    private let qaDataRoot: URL?
    @StateObject private var librarySession: LibrarySession
    @StateObject private var localCLI = LocalCLIService()

    init() {
        do {
            let resolved = try AssetFrameQADataRoot.resolve()
            qaDataRoot = resolved
            _librarySession = StateObject(wrappedValue: LibrarySession(qaRoot: resolved))
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: appearanceRawValue) ?? .defaultValue {
        case .graphite: .dark
        case .system: nil
        case .light: .light
        }
    }

    var body: some Scene {
        WindowGroup(AppProduct.current.title + " · " + AppVersion.annotatedDisplay) {
            UnifiedLibraryWorkspace(session: librarySession)
                .environmentObject(localCLI)
                .onAppear { localCLI.start(session: librarySession, qaRoot: qaDataRoot) }
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            if AppProduct.current == .story { ManjuAppCommands() }
            else {
            CommandGroup(replacing: .newItem) {
                Button("打开资源库…") {
                    NotificationCenter.default.post(name: .openProjectFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("链接素材文件夹…") {
                    NotificationCenter.default.post(name: .linkMaterialFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("导入素材…") {
                    NotificationCenter.default.post(name: .importAssetImages, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])
                Button("扫描文件夹") {
                    NotificationCenter.default.post(name: .scanCurrentProject, object: nil)
                }
                Divider()
                Button("导出 CSV…") {
                    NotificationCenter.default.post(name: .exportAssetCSV, object: nil)
                }
            }

            CommandMenu("显示") {
                Button("显示／隐藏侧栏") {
                    NotificationCenter.default.post(name: .toggleAssetSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("显示／隐藏详情") {
                    NotificationCenter.default.post(name: .toggleAssetInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("素材总库") { NotificationCenter.default.post(name: .showMaterialLibrary, object: nil) }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("导出库") { NotificationCenter.default.post(name: .showExportLibrary, object: nil) }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("回收站") { NotificationCenter.default.post(name: .showAssetTrash, object: nil) }
                    .keyboardShortcut("5", modifiers: [.command])
            }

            CommandMenu("资产") {
                Button("撤销素材整理") { NotificationCenter.default.post(name: .undoMaterialEdit, object: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                Button("重做素材整理") { NotificationCenter.default.post(name: .redoMaterialEdit, object: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                Divider()
                Button("搜索当前页面") {
                    NotificationCenter.default.post(name: .focusWorkspaceSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
                Button("预览所选") {
                    NotificationCenter.default.post(name: .previewSelectedAsset, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])
                Divider()
                ForEach(1...5, id: \.self) { rating in
                    Button("评为 \(rating) 星") {
                        NotificationCenter.default.post(name: .rateSelectedAssets, object: nil, userInfo: ["rating": rating])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(rating)")), modifiers: [.control])
                }
            }

            CommandGroup(after: .appSettings) {
                CheckForUpdatesCommand(controller: updateController)
            }

            CommandGroup(replacing: .help) {
                Button("更新日志…") {
                    NotificationCenter.default.post(name: .showUpdateLog, object: nil)
                }
                Button("AssetFrame 功能状态") {
                    NotificationCenter.default.post(name: .showFeatureStatus, object: nil)
                }
            }
            }
        }

        Settings {
            Group {
                if AppProduct.current == .story { ManjuSettingsView() }
                else { AssetFrameSettingsView(updateController: updateController) }
            }.preferredColorScheme(preferredColorScheme)
        }
    }
}

extension Notification.Name {
    static let manageStoryProjects = Notification.Name("manageStoryProjects")
    static let undoMaterialEdit = Notification.Name("undoMaterialEdit")
    static let redoMaterialEdit = Notification.Name("redoMaterialEdit")
    static let importAssetImages = Notification.Name("importAssetImages")
    static let recordOptimizationFeedback = Notification.Name("recordOptimizationFeedback")
    static let showOptimizationNotes = Notification.Name("showOptimizationNotes")
    static let toggleLocalFolderFocus = Notification.Name("toggleLocalFolderFocus")
    static let focusWorkspaceSearch = Notification.Name("focusWorkspaceSearch")
    static let openProjectFolder = Notification.Name("openProjectFolder")
    static let linkMaterialFolder = Notification.Name("linkMaterialFolder")
    static let scanCurrentProject = Notification.Name("scanCurrentProject")
    static let exportAssetCSV = Notification.Name("exportAssetCSV")
    static let toggleAssetSidebar = Notification.Name("toggleAssetSidebar")
    static let toggleAssetInspector = Notification.Name("toggleAssetInspector")
    static let showAssetLibrary = Notification.Name("showAssetLibrary")
    static let showMaterialLibrary = Notification.Name("showMaterialLibrary")
    static let showExportLibrary = Notification.Name("showExportLibrary")
    static let showAssetTrash = Notification.Name("showAssetTrash")
    static let previewSelectedAsset = Notification.Name("previewSelectedAsset")
    static let rateSelectedAssets = Notification.Name("rateSelectedAssets")
    static let showFeatureStatus = Notification.Name("showFeatureStatus")
    static let showUpdateLog = Notification.Name("showUpdateLog")
}
