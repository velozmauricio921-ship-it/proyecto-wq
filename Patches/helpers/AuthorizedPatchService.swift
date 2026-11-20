import Darwin
import Foundation

struct PatchOperationPreview: Identifiable, Equatable {
    enum Action: String {
        case createDirectory
        case keepDirectory
        case createFile
        case replaceFile
    }

    let id: String
    let bundleID: String
    let relativePath: String
    let action: Action
    let replacementBytes: Int
    let existingBytes: Int64?
    let targetSnapshot: PatchTargetSnapshot?
}

final class PatchScopedFolder {
    let url: URL
    private let scopedURL: URL
    private let accessGranted: Bool
    private let pathAuthorizer: ((String) -> Bool)?
    private let isResolvedWQContainer: Bool

    init(url: URL) throws {
        guard url.isFileURL,
              url.startAccessingSecurityScopedResource() else {
            throw PatchPackageError.unsafeTargetPath
        }
            scopedURL = url
        self.url = PatchPathValidator.canonicalFileURL(url)
        accessGranted = true
        pathAuthorizer = nil
        isResolvedWQContainer = false

            do {
                try validate()
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
    }

    init(testURL: URL, authorizePath: ((String) -> Bool)? = nil) throws {
        guard testURL.isFileURL else { throw PatchPackageError.unsafeTargetPath }
        scopedURL = testURL
        url = PatchPathValidator.canonicalFileURL(testURL)
        accessGranted = false
        pathAuthorizer = authorizePath
        isResolvedWQContainer = false
        try validate()
    }

    init(deviceURL: URL, authorizePath: @escaping (String) -> Bool) throws {
        guard deviceURL.isFileURL else { throw PatchPackageError.unsafeTargetPath }
        scopedURL = deviceURL
        url = PatchPathValidator.canonicalFileURL(deviceURL)
        accessGranted = false
        pathAuthorizer = authorizePath
        isResolvedWQContainer = true
        try validate()
        try authorize(url)
    }

    deinit {
        if accessGranted { scopedURL.stopAccessingSecurityScopedResource() }
    }

    private static func isProtectedApplicationLocation(_ path: String) -> Bool {
        let protectedRoots = [
            "/private/var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Data/Application",
            "/private/var/containers/Bundle/Application",
            "/var/containers/Bundle/Application",
            "/Applications",
            "/System/Applications"
        ]
        return protectedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func validate() throws {
        let allowed = isResolvedWQContainer
            ? Self.isApplicationDataContainer(url.path)
            : !Self.isProtectedApplicationLocation(url.path)
        guard allowed, Self.pathHasNoSymbolicLinks(url.path) else {
            throw PatchPackageError.unsafeTargetPath
        }
    }

    func authorize(_ path: URL) throws {
        try validate()
        guard let pathAuthorizer else { return }
        let canonical = PatchPathValidator.canonicalFileURL(path)
        guard canonical.path == url.path || canonical.path.hasPrefix(url.path + "/"),
              pathAuthorizer(canonical.path) else {
            throw PatchPackageError.targetAppUnavailable(url.lastPathComponent)
        }
    }

    private static func isApplicationDataContainer(_ path: String) -> Bool {
        let canonical = PatchPathValidator.canonicalFileURL(URL(fileURLWithPath: path)).path
        let root = "/private/var/mobile/Containers/Data/Application"
        let url = URL(fileURLWithPath: canonical)
        return url.deletingLastPathComponent().path == root
            && UUID(uuidString: url.lastPathComponent) != nil
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

enum AuthorizedPatchService {
    static func prepare(
        project: PatchProject,
        folders: [String: PatchScopedFolder],
        fileManager: FileManager = .default
    ) throws -> [PatchOperationPreview] {
        try PatchPackageCodec.validate(project)
        let bundleIDs = project.allBundleIdentifiers
        guard !bundleIDs.isEmpty,
              Set(bundleIDs) == Set(folders.keys) else {
            throw PatchPackageError.invalidProject
        }
                try folders.values.forEach { try $0.validate() }
        let access = try PatchFileAccessAdapter(bundleIdentifiers: bundleIDs, folders: folders)

        var targetKeys = Set<String>()
        var requestedDirectories = Set<String>()
        var previews: [PatchOperationPreview] = []

        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(directory.relativePath)
            guard bundleID == directory.bundleID,
                  relativePath == directory.relativePath,
                  let folder = folders[bundleID] else {
                throw PatchPackageError.invalidProject
            }
            requestedDirectories.insert(bundleID + "\0" + relativePath)
        }

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let components = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
                .split(separator: "/")
                .map(String.init)
            guard bundleID == rule.bundleID else { throw PatchPackageError.invalidProject }
            if components.count > 1 {
                for count in 1..<components.count {
                    requestedDirectories.insert(
                        bundleID + "\0" + components.prefix(count).joined(separator: "/")
                    )
                }
            }
        }

        for key in requestedDirectories.sorted() {
            let parts = key.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PatchPackageError.invalidProject }
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(String(parts[0]))
            let relativePath = try PatchPathValidator.canonicalRelativePath(String(parts[1]))
            guard let folder = folders[bundleID], targetKeys.insert(key).inserted else {
                throw PatchPackageError.invalidProject
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: relativePath,
                containerRoot: folder.url
            )
            try validateDirectory(target, relativePath: relativePath, root: folder.url, fileManager: fileManager)
            try access.authorize(bundleID: bundleID, relativePath: relativePath)
            let snapshot = try access.snapshot(bundleID: bundleID, relativePath: relativePath, expectsDirectory: true)
            previews.append(PatchOperationPreview(
                id: key,
                bundleID: bundleID,
                relativePath: relativePath,
                action: fileManager.fileExists(atPath: target.path) ? .keepDirectory : .createDirectory,
                replacementBytes: 0,
                existingBytes: nil,
                targetSnapshot: snapshot
            ))
        }

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            guard bundleID == rule.bundleID,
                  relativePath == rule.relativePath,
                  rule.hasReplacement,
                  let folder = folders[bundleID] else {
                throw PatchPackageError.invalidProject
            }
            let key = bundleID + "\0" + relativePath
            guard targetKeys.insert(key).inserted else { throw PatchPackageError.duplicateTarget }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: relativePath,
                containerRoot: folder.url
            )
            let existingBytes = try validateFile(target, relativePath: relativePath, root: folder.url, fileManager: fileManager)
            try access.authorize(bundleID: bundleID, relativePath: relativePath)
            let snapshot = try access.snapshot(bundleID: bundleID, relativePath: relativePath, expectsDirectory: false)
            previews.append(PatchOperationPreview(
                id: key,
                bundleID: bundleID,
                relativePath: relativePath,
                action: existingBytes == nil ? .createFile : .replaceFile,
                replacementBytes: rule.replacementData.count,
                existingBytes: existingBytes,
                targetSnapshot: snapshot
            ))
        }

        return previews.sorted {
            ($0.bundleID, $0.relativePath) < ($1.bundleID, $1.relativePath)
        }
    }

    static func apply(
        project: PatchProject,
        folders: [String: PatchScopedFolder],
        confirmedPreview: [PatchOperationPreview]
    ) throws -> PatchTransactionReceipt {
        let currentPreview = try prepare(project: project, folders: folders)
        guard currentPreview == confirmedPreview else {
            throw PatchPackageError.operationPlanChanged
        }

        let access = try PatchFileAccessAdapter(
            bundleIdentifiers: project.allBundleIdentifiers,
            folders: folders
        )
        let confirmedByTarget = Dictionary(uniqueKeysWithValues: confirmedPreview.map { ($0.id, $0) })

        func validateConfirmedTarget(bundleID: String, relativePath: String, isDirectory: Bool) throws {
            let key = bundleID + "\0" + relativePath
            guard let confirmed = confirmedByTarget[key] else {
                throw PatchPackageError.operationPlanChanged
            }
            let current = try access.snapshot(
                bundleID: bundleID,
                relativePath: relativePath,
                expectsDirectory: isDirectory
            )
            guard current == confirmed.targetSnapshot else {
                throw PatchPackageError.operationPlanChanged
            }
        }

        return try PatchTransaction.apply(
            project: project,
            backupRoot: PatchProjectLibrary.backupRootURL(),
            containerResolver: { bundleID in
                guard let folder = folders[bundleID] else {
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
                try folder.authorize(folder.url)
                return folder.url
            },
            beforeWrite: { index in
                guard project.rules.indices.contains(index) else {
                    throw PatchPackageError.invalidProject
                }
                let rule = project.rules[index]
                try access.authorize(bundleID: rule.bundleID, relativePath: rule.relativePath)
                try validateConfirmedTarget(
                    bundleID: rule.bundleID,
                    relativePath: rule.relativePath,
                    isDirectory: false
                )
            },
            beforeDirectoryWrite: { bundleID, relativePath in
                try access.authorize(bundleID: bundleID, relativePath: relativePath)
            },
            beforeRestore: { bundleID, relativePath, isDirectory in
                try access.authorize(bundleID: bundleID, relativePath: relativePath)
                _ = isDirectory
            }
        )
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        folders: [String: PatchScopedFolder]
    ) throws {
        let required = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        guard !required.isEmpty, Set(required) == Set(folders.keys) else {
            throw PatchPackageError.invalidProject
        }
        try folders.values.forEach { try $0.validate() }
        let access = try PatchFileAccessAdapter(bundleIdentifiers: required, folders: folders)
        try PatchTransaction.restore(
            receipt: receipt,
            containerResolver: { bundleID in
                guard let folder = folders[bundleID] else {
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
                try folder.authorize(folder.url)
                return folder.url
            },
            beforeRestore: { bundleID, relativePath, isDirectory in
                try access.authorize(bundleID: bundleID, relativePath: relativePath)
                _ = isDirectory
            }
        )
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    private static func validateDirectory(
        _ target: URL,
        relativePath: String,
        root: URL,
        fileManager: FileManager
    ) throws {
        try validateParents(relativePath: relativePath, root: root, fileManager: fileManager)
        guard fileManager.fileExists(atPath: target.path) else { return }
        var metadata = stat()
        guard lstat(target.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PatchPackageError.symbolicLinkUnsupported
        }
    }

    private static func validateFile(
        _ target: URL,
        relativePath: String,
        root: URL,
        fileManager: FileManager
    ) throws -> Int64? {
        try validateParents(relativePath: relativePath, root: root, fileManager: fileManager)
        guard fileManager.fileExists(atPath: target.path) else { return nil }
        var metadata = stat()
        guard lstat(target.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw PatchPackageError.symbolicLinkUnsupported
        }
        return Int64(metadata.st_size)
    }

    private static func validateParents(
        relativePath: String,
        root: URL,
        fileManager: FileManager
    ) throws {
        var parent = root
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/")
            .dropLast()
        for component in components {
            parent.appendPathComponent(String(component), isDirectory: true)
            guard fileManager.fileExists(atPath: parent.path) else { break }
            var metadata = stat()
            guard lstat(parent.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
        }
    }
}