import CryptoKit
import Darwin
import Foundation

struct PatchTargetSnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let fileType: UInt32
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let digest: Data?
}

struct PatchFileAccessAdapter {
    private let folders: [String: PatchScopedFolder]

    init(bundleIdentifiers: [String], folders: [String: PatchScopedFolder]) throws {
        let required = Set(bundleIdentifiers)
        guard !required.isEmpty, required == Set(folders.keys) else {
            throw PatchPackageError.invalidProject
        }
        for folder in folders.values {
            try folder.validate()
        }
        self.folders = folders
    }

    func root(for bundleID: String) throws -> URL {
        let canonical = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
        guard canonical == bundleID, let folder = folders[bundleID] else {
            throw PatchPackageError.targetAppUnavailable(bundleID)
        }
        try folder.validate()
        return folder.url
    }

    func target(bundleID: String, relativePath: String) throws -> URL {
        try PatchPathValidator.resolveContainedTargetURL(
            relativePath: relativePath,
            containerRoot: try root(for: bundleID)
        )
    }

    func snapshot(
        bundleID: String,
        relativePath: String,
        expectsDirectory: Bool
    ) throws -> PatchTargetSnapshot? {
        let url = try target(bundleID: bundleID, relativePath: relativePath)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw PatchPackageError.applyFailed
        }

        let fileType = metadata.st_mode & S_IFMT
        let expectedType: mode_t = expectsDirectory ? S_IFDIR : S_IFREG
        guard fileType == expectedType else {
            throw PatchPackageError.symbolicLinkUnsupported
        }

        let digest: Data?
        if expectsDirectory {
            digest = nil
        } else {
            digest = try digestFile(at: url)
        }

        return PatchTargetSnapshot(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            fileType: UInt32(fileType),
            size: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            digest: digest
        )
    }

    func authorize(bundleID: String, relativePath: String) throws {
        guard let folder = folders[bundleID] else {
            throw PatchPackageError.targetAppUnavailable(bundleID)
        }
        let target = try target(bundleID: bundleID, relativePath: relativePath)
        try folder.authorize(target)
        try folder.authorize(target.deletingLastPathComponent())
    }

    private func digestFile(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
