import Darwin
import Foundation

struct PatchOperationPreview: Identifiable {
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
}

final class PatchScopedFolder {
    let url: URL
    private let scopedURL: URL
    private let accessGranted: Bool

    init(url: URL) throws {
        guard url.isFileURL,
              url.startAccessingSecurityScopedResource() else {
            throw PatchPackageError.unsafeTargetPath
        }
            scopedURL = url
        self.url = PatchPathValidator.canonicalFileURL(url)
        accessGranted = true

            do {
                try validate()
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
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
        guard !Self.isProtectedApplicationLocation(url.path),
              Self.pathHasNoSymbolicLinks(url.path) else {
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
            previews.append(PatchOperationPreview(
                id: key,
                bundleID: bundleID,
                relativePath: relativePath,
                action: fileManager.fileExists(atPath: target.path) ? .keepDirectory : .createDirectory,
                replacementBytes: 0,
                existingBytes: nil
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
            previews.append(PatchOperationPreview(
                id: key,
                bundleID: bundleID,
                relativePath: relativePath,
                action: existingBytes == nil ? .createFile : .replaceFile,
                replacementBytes: rule.replacementData.count,
                existingBytes: existingBytes
            ))
        }

        return previews.sorted {
            ($0.bundleID, $0.relativePath) < ($1.bundleID, $1.relativePath)
        }
    }

    static func apply(
        project: PatchProject,
        folders: [String: PatchScopedFolder]
    ) throws -> PatchTransactionReceipt {
        _ = try prepare(project: project, folders: folders)
        return try PatchTransaction.apply(
            project: project,
            backupRoot: PatchProjectLibrary.backupRootURL(),
            containerResolver: { bundleID in
                guard let folder = folders[bundleID] else {
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
                return folder.url
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
        try PatchTransaction.restore(
            receipt: receipt,
            containerResolver: { bundleID in
                guard let folder = folders[bundleID] else {
                    throw PatchPackageError.targetAppUnavailable(bundleID)
                }
                return folder.url
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