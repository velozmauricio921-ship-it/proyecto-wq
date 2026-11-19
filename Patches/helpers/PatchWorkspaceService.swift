import Foundation

enum PatchWorkspaceService {
    private struct Manifest: Codable {
        let schemaVersion: Int
        let projectID: UUID
        var displayName: String
    }

    private static let manifestFilename = ".3105-project.plist"
    private static let manifestSchemaVersion = 1

    static func documentsRootURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func patchesRootURL(fileManager: FileManager = .default) throws -> URL {
        let supportRoot = try documentsRootURL(fileManager: fileManager)
        let wqRoot = supportRoot.appendingPathComponent("WQFiles", isDirectory: true)
        let root = wqRoot.appendingPathComponent("Patches", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let documentsLegacyRoot = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Patches", isDirectory: true)
        let hiddenLegacyRoot = supportRoot
            .appendingPathComponent(".3105", isDirectory: true)
            .appendingPathComponent("Patches", isDirectory: true)

        for legacyRoot in [documentsLegacyRoot, hiddenLegacyRoot]
        where fileManager.fileExists(atPath: legacyRoot.path) && legacyRoot.path != root.path {
            let existing = (try? fileManager.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in existing {
                let destination = root.appendingPathComponent(item.lastPathComponent)
                guard !fileManager.fileExists(atPath: destination.path),
                      let values = try? item.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                      ), values.isDirectory == true, values.isSymbolicLink != true,
                      let manifest = try? readManifest(workspaceURL: item),
                                            manifest.schemaVersion == manifestSchemaVersion,
                                            isSafeWorkspaceTree(item, fileManager: fileManager) else { continue }
                try? fileManager.copyItem(at: item, to: destination)
            }
        }

        return root
    }

    private static func isSafeWorkspaceTree(
        _ workspaceURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let root = workspaceURL.standardizedFileURL
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { return false }

        while let item = enumerator.nextObject() as? URL {
            guard let values = try? item.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            ), values.isSymbolicLink != true else { return false }
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { return false }
            let relative = String(path.dropFirst(root.path.count + 1))
            if relative == manifestFilename {
                guard values.isRegularFile == true else { return false }
                continue
            }

            let components = relative.split(separator: "/")
                        guard let bundleComponent = components.first else { return false }
                        let bundleID = String(bundleComponent)
                        guard (try? PatchPathValidator.canonicalBundleIdentifier(bundleID)) == bundleID else {
                return false
            }
            if components.count == 1 {
                guard values.isDirectory == true else { return false }
            } else {
                let relativePath = components.dropFirst().joined(separator: "/")
                guard (try? PatchPathValidator.canonicalRelativePath(relativePath)) != nil,
                      values.isDirectory == true || values.isRegularFile == true else { return false }
            }
        }
        return !enumerationFailed
    }

    static func createWorkspace(
        for project: PatchProject,
        patchesRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        try PatchPackageCodec.validate(project)
        let root = try patchesRoot ?? patchesRootURL(fileManager: fileManager)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = workspaceURL(
            projectID: project.id,
            patchesRoot: root,
            fileManager: fileManager
        ) {
            return existing
        }

        let destination = uniqueWorkspaceURL(
            named: project.name,
            in: root,
            fileManager: fileManager
        )
        let staging = root.appendingPathComponent(
            ".3105-workspace-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            for bundleID in project.allBundleIdentifiers {
                let canonical = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
                guard canonical == bundleID else { throw PatchPackageError.invalidProject }
                try fileManager.createDirectory(
                    at: staging.appendingPathComponent(bundleID, isDirectory: true),
                    withIntermediateDirectories: false
                )
            }
            for directory in project.directories {
                let target = try workspaceTarget(
                    bundleID: directory.bundleID,
                    relativePath: directory.relativePath,
                    workspaceRoot: staging,
                    isDirectory: true
                )
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            }
            for rule in project.rules {
                let target = try workspaceTarget(
                    bundleID: rule.bundleID,
                    relativePath: rule.relativePath,
                    workspaceRoot: staging,
                    isDirectory: false
                )
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard !fileManager.fileExists(atPath: target.path) else {
                    throw PatchPackageError.duplicateTarget
                }
                try rule.replacementData.write(to: target, options: [.atomic, .completeFileProtection])
            }
            try writeManifest(
                Manifest(
                    schemaVersion: manifestSchemaVersion,
                    projectID: project.id,
                    displayName: project.name
                ),
                workspaceURL: staging
            )
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch let error as PatchPackageError {
            throw error
        } catch {
            throw PatchPackageError.invalidProject
        }
    }

    static func ensureWorkspace(
        for project: PatchProject,
        patchesRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try patchesRoot ?? patchesRootURL(fileManager: fileManager)
        if let existing = workspaceURL(
            projectID: project.id,
            patchesRoot: root,
            fileManager: fileManager
        ) {
            return existing
        }
        return try createWorkspace(for: project, patchesRoot: root, fileManager: fileManager)
    }

    static func replaceWorkspace(
        with project: PatchProject,
        patchesRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try patchesRoot ?? patchesRootURL(fileManager: fileManager)
        if workspaceURL(
            projectID: project.id,
            patchesRoot: root,
            fileManager: fileManager
        ) != nil {
            throw PatchPackageError.duplicateTarget
        }
        return try createWorkspace(for: project, patchesRoot: root, fileManager: fileManager)
    }

    static func workspaceURL(
        projectID: UUID,
        patchesRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let root = try? patchesRoot ?? patchesRootURL(fileManager: fileManager),
              let candidates = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }

        for candidate in candidates {
            guard let values = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true,
                  let manifest = try? readManifest(workspaceURL: candidate),
                  manifest.schemaVersion == manifestSchemaVersion,
                  manifest.projectID == projectID else { continue }
            return candidate
        }
        return nil
    }

    static func snapshot(
        baseProject: PatchProject,
        workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws -> PatchProject {
        let root = workspaceURL.standardizedFileURL
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw PatchPackageError.invalidProject
        }
        let manifest = try readManifest(workspaceURL: root)
        guard manifest.schemaVersion == manifestSchemaVersion,
              manifest.projectID == baseProject.id else {
            throw PatchPackageError.invalidProject
        }

        let oldRuleIDs = Dictionary(uniqueKeysWithValues: baseProject.rules.map {
            (targetKey(bundleID: $0.bundleID, relativePath: $0.relativePath), $0.id)
        })
        let oldDirectoryIDs = Dictionary(uniqueKeysWithValues: baseProject.directories.map {
            (targetKey(bundleID: $0.bundleID, relativePath: $0.relativePath), $0.id)
        })

        let topLevel = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ).filter { $0.lastPathComponent != manifestFilename }

        var discoveredBundles: [String] = []
        var directories: [PatchDirectory] = []
        var rules: [PatchRule] = []
        for bundleURL in topLevel.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try bundleURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  values.isRegularFile != true else {
                throw PatchPackageError.invalidProject
            }
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(bundleURL.lastPathComponent)
            guard bundleID == bundleURL.lastPathComponent else {
                throw PatchPackageError.invalidBundleIdentifier
            }
            discoveredBundles.append(bundleID)

            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: bundleURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else {
                throw PatchPackageError.invalidProject
            }
            while let item = enumerator.nextObject() as? URL {
                let itemValues = try item.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                if itemValues.isSymbolicLink == true {
                    if itemValues.isDirectory == true { enumerator.skipDescendants() }
                    throw PatchPackageError.symbolicLinkUnsupported
                }
                let relativePath = try relativePath(for: item, bundleRoot: bundleURL)
                let key = targetKey(bundleID: bundleID, relativePath: relativePath)
                if itemValues.isDirectory == true {
                    directories.append(PatchDirectory(
                        id: oldDirectoryIDs[key] ?? UUID(),
                        bundleID: bundleID,
                        relativePath: relativePath
                    ))
                } else if itemValues.isRegularFile == true {
                    rules.append(PatchRule(
                        id: oldRuleIDs[key] ?? UUID(),
                        bundleID: bundleID,
                        relativePath: relativePath,
                        replacementFilename: item.lastPathComponent,
                        replacementData: try Data(contentsOf: item, options: .mappedIfSafe)
                    ))
                } else {
                    throw PatchPackageError.invalidProject
                }
            }
            guard !enumerationFailed else { throw PatchPackageError.invalidProject }
        }

        var orderedBundles: [String] = []
        let discoveredSet = Set(discoveredBundles)
        for bundleID in baseProject.bundleIdentifiers where discoveredSet.contains(bundleID) {
            if !orderedBundles.contains(bundleID) { orderedBundles.append(bundleID) }
        }
        for bundleID in discoveredBundles where !orderedBundles.contains(bundleID) {
            orderedBundles.append(bundleID)
        }

        let project = PatchProject(
            id: baseProject.id,
            name: manifest.displayName,
            createdAt: baseProject.createdAt,
            updatedAt: Date(),
            bundleIdentifiers: orderedBundles,
            directories: directories.sorted {
                targetKey(bundleID: $0.bundleID, relativePath: $0.relativePath)
                    < targetKey(bundleID: $1.bundleID, relativePath: $1.relativePath)
            },
            rules: rules.sorted {
                targetKey(bundleID: $0.bundleID, relativePath: $0.relativePath)
                    < targetKey(bundleID: $1.bundleID, relativePath: $1.relativePath)
            }
        )
        try PatchPackageCodec.validate(project)
        return project
    }

    static func deleteWorkspace(
        projectID: UUID,
        fileManager: FileManager = .default
    ) throws {
        guard let workspace = workspaceURL(projectID: projectID, fileManager: fileManager) else {
            return
        }
        try fileManager.removeItem(at: workspace)
    }

    private static func workspaceTarget(
        bundleID: String,
        relativePath: String,
        workspaceRoot: URL,
        isDirectory: Bool
    ) throws -> URL {
        let bundle = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
        let path = try PatchPathValidator.canonicalRelativePath(relativePath)
        let bundleRoot = workspaceRoot.appendingPathComponent(bundle, isDirectory: true)
        let target = bundleRoot.appendingPathComponent(path, isDirectory: isDirectory).standardizedFileURL
        guard target.path.hasPrefix(bundleRoot.path + "/") else {
            throw PatchPackageError.unsafeTargetPath
        }
        return target
    }

    private static func relativePath(for item: URL, bundleRoot: URL) throws -> String {
        let rootPath = bundleRoot.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath + "/") else {
            throw PatchPackageError.unsafeTargetPath
        }
        return try PatchPathValidator.canonicalRelativePath(
            String(itemPath.dropFirst(rootPath.count + 1))
        )
    }

    private static func targetKey(bundleID: String, relativePath: String) -> String {
        bundleID + "\0" + relativePath
    }

    private static func uniqueWorkspaceURL(
        named rawName: String,
        in root: URL,
        fileManager: FileManager
    ) -> URL {
        let base = sanitizedName(rawName)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func sanitizedName(_ rawName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\0").union(.controlCharacters)
        let scalars = rawName.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }
        let result = scalars.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
        return result.isEmpty ? "Patch" : String(result)
    }

    private static func writeManifest(_ manifest: Manifest, workspaceURL: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(manifest)
        try data.write(
            to: workspaceURL.appendingPathComponent(manifestFilename),
            options: [.atomic, .completeFileProtection]
        )
    }

    private static func readManifest(workspaceURL: URL) throws -> Manifest {
        let data = try Data(
            contentsOf: workspaceURL.appendingPathComponent(manifestFilename),
            options: .mappedIfSafe
        )
        return try PropertyListDecoder().decode(Manifest.self, from: data)
    }
}
