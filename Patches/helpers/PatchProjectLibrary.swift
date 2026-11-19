import Foundation

struct PatchLibraryItem: Identifiable {
    let summary: PatchPackageSummary
    var project: PatchProject?
    var contentKey: Data?
    var categories: [String] = []
    var packageURL: URL

    var id: UUID { summary.packageID }
    var isLocked: Bool { project == nil }
    var workspaceURL: URL? {
        PatchWorkspaceService.workspaceURL(projectID: id)
    }
}

struct PatchPasswordRequest: Identifiable {
    let summary: PatchPackageSummary
    var id: UUID { summary.packageID }
}

enum PatchProjectLibrary {
    private static let installNamespaceKey = "PatchProjectLibrary.installNamespace"

    static func legacyPackageRootURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PatchProjects", isDirectory: true)
    }

    static func packageRootURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base
            .appendingPathComponent("WQFiles", isDirectory: true)
            .appendingPathComponent("PatchProjects", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        migrateLegacyPackages(into: root, applicationSupport: base, fileManager: fileManager)
        return root
    }

    private static func migrateLegacyPackages(
        into destinationRoot: URL,
        applicationSupport: URL,
        fileManager: FileManager
    ) {
        var legacyRoots = [try? legacyPackageRootURL(fileManager: fileManager)].compactMap { $0 }
        if let namespace = UserDefaults.standard.string(forKey: installNamespaceKey),
           !namespace.isEmpty {
            legacyRoots.append(
                applicationSupport
                    .appendingPathComponent(namespace, isDirectory: true)
                    .appendingPathComponent("PatchProjects", isDirectory: true)
            )
        }

        for legacyRoot in Set(legacyRoots.map(\.standardizedFileURL)) where
            legacyRoot.path != destinationRoot.standardizedFileURL.path {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for source in entries where source.pathExtension.lowercased() == "3105" {
                guard let values = try? source.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                ), values.isRegularFile == true, values.isSymbolicLink != true,
                      !fileManager.fileExists(atPath: destinationRoot.appendingPathComponent(source.lastPathComponent).path),
                      let data = try? readPackage(at: source),
                      (try? PatchPackageCodec.inspect(data)) != nil else { continue }

                let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
                try? fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    static func backupRootURL(fileManager: FileManager = .default) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func preloadedRootURL(fileManager: FileManager = .default) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent("Preloaded", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func load(fileManager: FileManager = .default) -> [PatchLibraryItem] {
        ensurePreloadedPackagesInstalled(fileManager: fileManager)

        guard let root = try? packageRootURL(fileManager: fileManager) else { return [] }

        let rootURLs = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let preloadedURLs: [URL]
        if let recursive = try? fileManager.recursiveFiles(in: try preloadedRootURL(fileManager: fileManager), matchingExtension: "3105") {
            preloadedURLs = recursive
        } else {
            preloadedURLs = (try? fileManager.contentsOfDirectory(
                at: try preloadedRootURL(fileManager: fileManager),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )) ?? []
        }

        let preloadedNames = Set(preloadedURLs.map { $0.lastPathComponent })
        let filteredRootURLs = rootURLs.filter { url in
            guard url.pathExtension.lowercased() == "3105" else { return false }
            guard !url.path.contains("/Preloaded/") else { return false }
            return !preloadedNames.contains(url.lastPathComponent)
        }

        let urls = filteredRootURLs + preloadedURLs

        var items: [PatchLibraryItem] = []
        var seenPaths = Set<String>()

        for url in urls where url.pathExtension.lowercased() == "3105" {
            do {
                let data = try readPackage(at: url)
                let summary = try PatchPackageCodec.inspect(data)

                // Keep every bundled package file distinct. Some release bundles can contain
                // several .3105 files that legitimately share the same package metadata, but
                // they must still appear as separate entries in the UI and cache.
                let pathKey = url.standardizedFileURL.path
                if !seenPaths.insert(pathKey).inserted {
                    continue
                }

                // Require contentKey in secure keychain for non-password-protected packages.
                let decoded: DecodedPatchPackage?
                if let contentKey = try? PatchKeyStore.load(for: summary) {
                    decoded = try PatchPackageCodec.decode(data, contentKey: contentKey)
                } else if summary.isPasswordProtected {
                    // If password-protected and no key available, keep locked
                    decoded = nil
                } else {
                    // For public packages, still attempt decode without contentKey
                    decoded = try PatchPackageCodec.decode(data, password: nil)
                }
                var categories: [String] = []
                if let preloadIndex = url.pathComponents.firstIndex(of: "Preloaded") {
                    let comps = url.pathComponents
                    if preloadIndex + 1 < comps.count - 1 {
                        categories = Array(comps[(preloadIndex + 1)..<(comps.count - 1)])
                    }
                }

                let item = PatchLibraryItem(
                    summary: summary,
                    project: decoded?.project,
                    contentKey: decoded?.contentKey,
                    categories: categories,
                    packageURL: url
                )
                if summary.schemaVersion >= 2, let project = decoded?.project {
                    do {
                        _ = try PatchWorkspaceService.ensureWorkspace(for: project)
                    } catch {
                        print("patch: workspace unavailable for \(project.id.uuidString)")
                    }
                }
                items.append(item)
            } catch {
                print("patch: skipped invalid local package \(url.lastPathComponent)")
            }
        }
        return items.sorted {
            ($0.project?.updatedAt ?? .distantPast) > ($1.project?.updatedAt ?? .distantPast)
        }
    }

    static func readPackage(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw PatchPackageError.invalidProject
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func save(
        data: Data,
        projectName: String,
        existingURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination: URL
        if let existingURL {
            destination = existingURL
        } else {
            let root = try packageRootURL(fileManager: fileManager)
            let baseName = sanitizedFilename(projectName)
            var candidate = root.appendingPathComponent(baseName).appendingPathExtension("3105")
            var suffix = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = root.appendingPathComponent("\(baseName)-\(suffix)").appendingPathExtension("3105")
                suffix += 1
            }
            destination = candidate
        }
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    static func installImportedPackage(
        data: Data,
        decoded: DecodedPatchPackage,
        summary: PatchPackageSummary,
        existingURL: URL?,
        fileManager: FileManager = .default
    ) throws {
        let previousData = try existingURL.map { try readPackage(at: $0) }
        if let previousData, previousData != data {
            throw PatchPackageError.duplicateTarget
        }
        var savedURL: URL?
        do {
            savedURL = try save(
                data: data,
                projectName: decoded.project.name,
                existingURL: existingURL,
                fileManager: fileManager
            )
            if summary.schemaVersion >= 2 {
                _ = try PatchWorkspaceService.ensureWorkspace(
                    for: decoded.project,
                    fileManager: fileManager
                )
            }
        } catch {
            if let previousData, let existingURL {
                try? previousData.write(
                    to: existingURL,
                    options: [.atomic, .completeFileProtection]
                )
            } else if let savedURL, fileManager.fileExists(atPath: savedURL.path) {
                try? fileManager.removeItem(at: savedURL)
            }
            throw error
        }
    }

    static func delete(_ item: PatchLibraryItem, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: item.packageURL.path) {
            try fileManager.removeItem(at: item.packageURL)
        }
        try? PatchWorkspaceService.deleteWorkspace(projectID: item.id, fileManager: fileManager)
        try? PatchKeyStore.delete(for: item.summary)
    }

    static func synchronizeWorkspace(
        item: PatchLibraryItem,
        fileManager: FileManager = .default
    ) throws -> PatchProject {
        guard item.summary.schemaVersion >= 2,
              let baseProject = item.project,
              let contentKey = item.contentKey else {
            throw PatchPackageError.invalidProject
        }
        let workspace = try PatchWorkspaceService.ensureWorkspace(
            for: baseProject,
            fileManager: fileManager
        )
        let project = try PatchWorkspaceService.snapshot(
            baseProject: baseProject,
            workspaceURL: workspace,
            fileManager: fileManager
        )
        let original = try readPackage(at: item.packageURL)
        let updated = try PatchPackageCodec.update(
            original,
            project: project,
            contentKey: contentKey,
            schemaVersion: PatchPackageCodec.latestSchemaVersion
        )
        _ = try save(
            data: updated,
            projectName: project.name,
            existingURL: item.packageURL,
            fileManager: fileManager
        )
        return project
    }

    static func ensurePreloadedPackagesInstalled(fileManager: FileManager = .default) {
        guard let preloadedRoot = try? preloadedRootURL(fileManager: fileManager) else { return }
        let resourceRoot = Bundle.main.resourceURL
        let bundledRoot = resourceRoot?.appendingPathComponent("Preloaded", isDirectory: true)
        let bundleURLs = bundledRoot.flatMap {
            try? fileManager.recursiveFiles(in: $0, matchingExtension: "3105")
        } ?? []

        for sourceURL in bundleURLs {
            let relative = String(sourceURL.path.dropFirst((bundledRoot?.path.count ?? 0) + 1))
            guard let safeRelative = try? PatchPathValidator.canonicalRelativePath(relative),
                  let data = try? readPackage(at: sourceURL),
                  (try? PatchPackageCodec.inspect(data)) != nil else { continue }
            let destination = preloadedRoot.appendingPathComponent(safeRelative)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceURL, to: destination)
            } catch {
                print("patch: unable to install preloaded package \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private static func sanitizedFilename(_ rawName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = rawName.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
        return result.isEmpty ? "Patch" : String(result)
    }
}
