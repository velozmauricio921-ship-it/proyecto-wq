import Darwin
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

extension EnvironmentValues {
    var openPatchWorkspace: (String, String) -> Void {
        get { self[PatchWorkspaceOpenerKey.self] }
        set { self[PatchWorkspaceOpenerKey.self] = newValue }
    }

    var closePatchModule: () -> Void {
        get { self[PatchModuleCloserKey.self] }
        set { self[PatchModuleCloserKey.self] = newValue }
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

final class PatchSourceFolder {
    let url: URL
    private let scopedURL: URL

    init(url: URL) throws {
        guard url.isFileURL, url.startAccessingSecurityScopedResource() else {
            throw PatchPackageError.unsafeTargetPath
        }
        scopedURL = url
        self.url = PatchPathValidator.canonicalFileURL(url)
        do {
            try validate()
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    deinit {
        scopedURL.stopAccessingSecurityScopedResource()
    }

    private func validate() throws {
        let protectedRoots = [
            "/private/var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Data/Application",
            "/private/var/containers/Bundle/Application",
            "/var/containers/Bundle/Application",
            "/Applications",
            "/System/Applications"
        ]
        let path = url.path
        guard !protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              Self.pathHasNoSymbolicLinks(path) else {
            throw PatchPackageError.unsafeTargetPath
        }
    }

    private static func pathHasNoSymbolicLinks(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.first == "/" else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return true
    }
}

struct WQPatchFolderCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    let onCreate: (PatchProject, String?) -> Void

    @State private var showFolderPicker = false
    @State private var showFileSelection = false
    @State private var showEditor = false
    @State private var selectedFolder: PatchSourceFolder?
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
            selectedFolder = try PatchSourceFolder(url: url)
            errorMessage = nil
        } catch let error as PatchPackageError {
            errorMessage = error.errorDescription ?? language.text(error.localizationKey)
        } catch {
            errorMessage = language.text("patch.error.unsafe_path")
        }
    }
}

@objc(WQPatchHostViewController)
public final class WQPatchHostViewController: UIViewController {
    @objc public var openWorkspaceHandler: ((String, String) -> Void)?

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

