import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PackageRepositoryFeature {
    static let isEnabled = false
}

enum AppTheme {
    static let accent = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.32, green: 0.78, blue: 0.99, alpha: 1.00)
                : UIColor(red: 0.08, green: 0.62, blue: 0.98, alpha: 1.00)
        }
    )
    static let emptyIconSize: CGFloat = 30
    static let pageInset: CGFloat = 16
}

struct AppLanguage {
    func text(_ key: String) -> String {
        let englishBundle = Bundle.main.path(forResource: "en", ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        let englishValue = NSLocalizedString(
            key,
            tableName: "PatchLocalizable",
            bundle: englishBundle,
            value: key,
            comment: ""
        )
        return NSLocalizedString(
            key,
            tableName: "PatchLocalizable",
            bundle: .main,
            value: englishValue,
            comment: ""
        )
    }

    func text(_ key: String, _ argument: Int64) -> String {
        String(format: text(key), locale: Locale.current, argument)
    }

    func text(_ key: String, _ argument: String) -> String {
        String(format: text(key), locale: Locale.current, argument)
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage()
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

private struct PatchWorkspaceOpenerKey: EnvironmentKey {
    static let defaultValue: (String, String) -> Void = { _, _ in }
}

private struct PatchModuleCloserKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct PatchContainerResolverKey: EnvironmentKey {
    static let defaultValue: (String) -> URL? = { _ in nil }
}

private struct PatchPathAuthorizerKey: EnvironmentKey {
    static let defaultValue: (String) -> Bool = { _ in false }
}

extension EnvironmentValues {
    var openPatchWorkspace: (String, String) -> Void {
        get { self[PatchWorkspaceOpenerKey.self] }
        set { self[PatchWorkspaceOpenerKey.self] = newValue }
    }

    var closePatchModule: () -> Void {
        get { self[PatchModuleCloserKey.self] }
        set { self[PatchModuleCloserKey.self] = newValue }
    }

    var resolvePatchContainer: (String) -> URL? {
        get { self[PatchContainerResolverKey.self] }
        set { self[PatchContainerResolverKey.self] = newValue }
    }

    var authorizePatchPath: (String) -> Bool {
        get { self[PatchPathAuthorizerKey.self] }
        set { self[PatchPathAuthorizerKey.self] = newValue }
    }
}

enum AudioFeedback {
    static func play(isEnabled: Bool) {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct FileDocumentPicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let copiesSelectedDocument: Bool
    let allowsMultipleSelection: Bool
    let onSelection: (Result<[URL], Error>) -> Void
    let onCancel: () -> Void

    init(
        allowedContentTypes: [UTType] = [.item],
        copiesSelectedDocument: Bool = false,
        allowsMultipleSelection: Bool = true,
        onSelection: @escaping (Result<[URL], Error>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.allowedContentTypes = allowedContentTypes
        self.copiesSelectedDocument = copiesSelectedDocument
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: copiesSelectedDocument
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (Result<[URL], Error>) -> Void
        private let onCancel: () -> Void

        init(
            onSelection: @escaping (Result<[URL], Error>) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onSelection(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

struct WQPatchOperationFlowView: View {
    enum Mode {
        case apply
        case restore(PatchTransactionReceipt)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @Environment(\.resolvePatchContainer) private var resolvePatchContainer
    @Environment(\.authorizePatchPath) private var authorizePatchPath
    let project: PatchProject
    let mode: Mode
    let onComplete: () -> Void

    @State private var folders: [String: PatchScopedFolder] = [:]
    @State private var selectingBundleID: String?
    @State private var showFolderPicker = false
    @State private var previews: [PatchOperationPreview] = []
    @State private var showConfirmation = false
    @State private var isWorking = false
    @State private var alertMessage: String?

    private var requiredBundleIDs: [String] {
        switch mode {
        case .apply:
            return project.allBundleIdentifiers
        case .restore(let receipt):
            return (try? PatchTransaction.requiredBundleIdentifiers(for: receipt)) ?? []
        }
    }

    private var allFoldersSelected: Bool {
        !requiredBundleIDs.isEmpty && Set(requiredBundleIDs) == Set(folders.keys)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(requiredBundleIDs, id: \.self) { bundleID in
                        Button {
                            selectingBundleID = bundleID
                            showFolderPicker = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: folders[bundleID] == nil ? "folder.badge.plus" : "folder.fill")
                                    .foregroundStyle(AppTheme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bundleID).font(.subheadline.monospaced())
                                    Text(folders[bundleID]?.url.path ?? language.text("patch.choose_folder"))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                    }
                } header: {
                    Text(language.text("patch.authorized_locations"))
                } footer: {
                    Text(language.text("patch.authorized_locations_footer"))
                }

                if case .apply = mode, !previews.isEmpty {
                    Section {
                        ForEach(previews) { operation in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(operation.action.localizedTitle(using: language))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(operation.action.isDestructive ? .orange : AppTheme.accent)
                                    Spacer()
                                    if operation.action == .replaceFile {
                                        Text(ByteCountFormatter.string(
                                            fromByteCount: operation.existingBytes ?? 0,
                                            countStyle: .file
                                        ))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                Text(operation.bundleID).font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(operation.relativePath).font(.caption.monospaced())
                                    .textSelection(.enabled)
                                if operation.action == .createFile || operation.action == .replaceFile {
                                    Text(language.text("patch.replacement_size", Int64(operation.replacementBytes)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        Text(language.text("patch.operation_preview", Int64(previews.count)))
                    }
                }

                if isWorking {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(language.text("patch.applying"))
                        }
                    }
                }
            }
            .navigationTitle(language.text(mode.isRestore ? "patch.restore" : "patch.apply"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text(mode.isRestore ? "patch.restore" : "patch.review")) {
                        if mode.isRestore {
                            showConfirmation = true
                        } else {
                            prepareOperations()
                        }
                    }
                    .disabled(!allFoldersSelected || isWorking || (mode.isRestore == false && !previews.isEmpty))
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleFolderSelection
            )
            .confirmationDialog(
                language.text(mode.isRestore ? "patch.restore_confirm_title" : "patch.apply_confirm_title"),
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button(language.text(mode.isRestore ? "patch.restore" : "patch.apply"), role: mode.isRestore ? .destructive : nil) {
                    executeOperation()
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            } message: {
                Text(language.text(mode.isRestore ? "patch.restore_confirm_message" : "patch.apply_confirm_message"))
            }
            .alert(language.text("common.failed"), isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button(language.text("common.ok"), role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .onDisappear { folders.removeAll() }
            .onAppear { resolveAvailableContainers() }
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first,
              let bundleID = selectingBundleID else { return }
        do {
            folders[bundleID] = try PatchScopedFolder(url: url)
            previews = []
        } catch let error as PatchPackageError {
            alertMessage = error.errorDescription ?? language.text(error.localizationKey)
        } catch {
            alertMessage = language.text("patch.error.unsafe_path")
        }
        selectingBundleID = nil
    }

    private func prepareOperations() {
        do {
            previews = try AuthorizedPatchService.prepare(project: project, folders: folders)
            guard !previews.isEmpty else {
                alertMessage = language.text("patch.error.invalid_project")
                return
            }
            showConfirmation = true
        } catch let error as PatchPackageError {
            alertMessage = error.errorDescription ?? language.text(error.localizationKey)
        } catch {
            alertMessage = language.text("patch.error.invalid_project")
        }
    }

    private func executeOperation() {
        isWorking = true
        let currentFolders = folders
        let selectedMode = mode
        Task.detached(priority: .userInitiated) {
            do {
                switch selectedMode {
                case .apply:
                    _ = try AuthorizedPatchService.apply(project: project, folders: currentFolders, confirmedPreview: previews)
                case .restore(let receipt):
                    try AuthorizedPatchService.restore(receipt: receipt, folders: currentFolders)
                }
                await MainActor.run {
                    isWorking = false
                    onComplete()
                    dismiss()
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    alertMessage = error.errorDescription ?? language.text(error.localizationKey)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    alertMessage = language.text("patch.error.apply")
                }
            }
        }
    }

    private func resolveAvailableContainers() {
        let bundleIDs = requiredBundleIDs.filter { folders[$0] == nil }
        guard !bundleIDs.isEmpty else { return }
        let resolver = resolvePatchContainer
        let authorizer = authorizePatchPath
        Task.detached(priority: .userInitiated) {
            var resolved: [String: PatchScopedFolder] = [:]
            for bundleID in bundleIDs {
                guard let url = resolver(bundleID) else { continue }
                if let folder = try? PatchScopedFolder(deviceURL: url, authorizePath: authorizer) {
                    resolved[bundleID] = folder
                }
            }
            await MainActor.run {
                for (bundleID, folder) in resolved where folders[bundleID] == nil {
                    folders[bundleID] = folder
                    previews = []
                }
            }
        }
    }
}

struct WQPatchFolderCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    let onCreate: (PatchProject, String?) -> Void

    @State private var showFolderPicker = false
    @State private var showFileSelection = false
    @State private var showEditor = false
    @State private var selectedFolder: PatchScopedFolder?
    @State private var draft: PatchProjectDraft?
    @State private var errorMessage: String?
    @State private var bundleID = "com.wqfiles.userselected"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("com.example.app", text: $bundleID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label(
                            selectedFolder?.url.lastPathComponent ?? language.text("patch.choose_folder"),
                            systemImage: selectedFolder == nil ? "folder.badge.plus" : "folder.fill"
                        )
                    }
                    .disabled(selectedFolder != nil)
                    if let selectedFolder {
                        Text(selectedFolder.url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text(language.text("patch.source_folder"))
                } footer: {
                    Text(language.text("patch.folder_selection_footer"))
                }

                if selectedFolder != nil {
                    Section {
                        Button(language.text("patch.select_files")) {
                            showFileSelection = true
                        }
                    }
                }
            }
            .navigationTitle(language.text("patch.create_from_folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleFolderSelection
            )
            .sheet(isPresented: $showFileSelection) {
                if let selectedFolder {
                    FolderPatchSelectionView(
                        containerRoot: selectedFolder.url,
                        folder: selectedFolder.url
                    ) { candidates in
                        do {
                            draft = try PatchDraftService.makeDraft(
                                bundleID: bundleID,
                                containerRoot: selectedFolder.url,
                                candidates: candidates,
                                suggestedName: selectedFolder.url.lastPathComponent
                            )
                            showFileSelection = false
                            showEditor = true
                        } catch let error as PatchPackageError {
                            errorMessage = error.errorDescription ?? language.text(error.localizationKey)
                            showFileSelection = false
                        } catch {
                            errorMessage = language.text("patch.error.invalid_project")
                            showFileSelection = false
                        }
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                if let draft {
                    PatchProjectEditorView(
                        existingProject: nil,
                        passwordIsProtected: false,
                        initialDraft: draft,
                        onSave: { project, password in
                            onCreate(project, password)
                            dismiss()
                        }
                    )
                }
            }
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            selectedFolder = try PatchScopedFolder(url: url)
            errorMessage = nil
        } catch let error as PatchPackageError {
            errorMessage = error.errorDescription ?? language.text(error.localizationKey)
        } catch {
            errorMessage = language.text("patch.error.unsafe_path")
        }
    }
}

private extension WQPatchOperationFlowView.Mode {
    var isRestore: Bool {
        if case .restore = self { return true }
        return false
    }
}

private extension PatchOperationPreview.Action {
    var isDestructive: Bool { self == .replaceFile }

    func localizedTitle(using language: AppLanguage) -> String {
        switch self {
        case .createDirectory: return language.text("patch.create_directory")
        case .keepDirectory: return language.text("patch.keep_directory")
        case .createFile: return language.text("patch.create_file")
        case .replaceFile: return language.text("patch.replace_file")
        }
    }
}

@objc(WQPatchHostViewController)
public final class WQPatchHostViewController: UIViewController {
    @objc public var openWorkspaceHandler: ((String, String) -> Void)?
    @objc public var resolveApplicationContainerHandler: ((String) -> String?)? = { bundleID in
        wqPatchResolveApplicationContainer(bundleID as NSString) as String?
    }
    @objc public var authorizePatchPathHandler: ((String) -> Bool)? = { path in
        wqPatchAuthorizePath(path as NSString)
    }

    private let draftCoordinator = PatchDraftCoordinator()
    private var hostingController: UIHostingController<AnyView>?
    private var restoresNavigationBar = false

    @objc public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @objc public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationController, !navigationController.isNavigationBarHidden {
            restoresNavigationBar = true
            navigationController.setNavigationBarHidden(true, animated: animated)
        }
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if restoresNavigationBar {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            restoresNavigationBar = false
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let rootView = AnyView(
            PatchProjectsView()
                .environmentObject(draftCoordinator)
                .environment(\.appLanguage, AppLanguage())
                .environment(\.openPatchWorkspace) { [weak self] path, title in
                    self?.openWorkspaceHandler?(path, title)
                }
                .environment(\.closePatchModule) { [weak self] in
                    self?.navigationController?.popViewController(animated: true)
                }
                .environment(\.resolvePatchContainer) { [weak self] bundleID in
                    guard let path = self?.resolveApplicationContainerHandler?(bundleID) else { return nil }
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
                .environment(\.authorizePatchPath) { [weak self] path in
                    self?.authorizePatchPathHandler?(path) ?? false
                }
        )
        let host = UIHostingController(rootView: rootView)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
        hostingController = host
    }
}

@_silgen_name("WQPatchResolveApplicationContainer")
private func wqPatchResolveApplicationContainer(_ bundleID: NSString) -> NSString?

@_silgen_name("WQPatchAuthorizePath")
private func wqPatchAuthorizePath(_ path: NSString) -> Bool