import Foundation

private enum PatchTestError: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        if case .assertion(let message) = self { return message }
        return "Patch test failed"
    }
}

@main
private enum PatchModuleTests {
    private static let fm = FileManager.default
    private static let bundleID = "com.example.applyfixture"

    static func main() {
        do {
            try testPackageImportAndDecode()
            try testPreviewAndApplyReplaceRestore()
            try testCreateDirectoryAndFile()
            try testStalePreviewRejected()
            try testInterruptedApplyRollsBack()
            try testRestorePartialCanRetry()
            try testContainerIdentityValidAndSubstituted()
            try testAuthorizationLossAndDeniedFile()
            try testExternalConflictRejectsRestore()
            try testRealPackageImportApplyRestoreIntegration()
            print("Patch codec and transaction tests: PASS")
        } catch {
            fputs("Patch codec and transaction tests: FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func testPackageImportAndDecode() throws {
        let project = makeProject(rules: [
            PatchRule(bundleID: bundleID, relativePath: "Library/test.dat", replacementFilename: "test.dat", replacementData: Data("replacement".utf8))
        ])
        let encoded = try PatchPackageCodec.encodeNew(project: project, password: nil)
        try expect(try PatchPackageCodec.inspect(encoded.data).schemaVersion == 2, "v2 package inspected")
        let decoded = try PatchPackageCodec.decode(encoded.data, password: nil)
        try expect(decoded.project == project, "package project decoded")

        var corrupted = encoded.data
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0x01
        try expectPatchError(.invalidPasswordOrCorruptedPackage) {
            _ = try PatchPackageCodec.decode(corrupted, password: nil)
        }
    }

    private static func testPreviewAndApplyReplaceRestore() throws {
        let fixture = try makeFixture("apply-replace")
        defer { try? fm.removeItem(at: fixture.base) }
        let target = fixture.root.appendingPathComponent("prefs.dat")
        try Data("before".utf8).write(to: target)
        let project = makeProject(rules: [
            PatchRule(bundleID: bundleID, relativePath: "prefs.dat", replacementFilename: "prefs.dat", replacementData: Data("after".utf8))
        ])
        let folders = [bundleID: try PatchScopedFolder(testURL: fixture.root)]
        let preview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        let receipt = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: preview)
        try expect(try Data(contentsOf: target) == Data("after".utf8), "replacement applied")
        try AuthorizedPatchService.restore(receipt: receipt, folders: folders)
        try expect(try Data(contentsOf: target) == Data("before".utf8), "replacement restored")
    }

    private static func testCreateDirectoryAndFile() throws {
        let fixture = try makeFixture("create")
        defer { try? fm.removeItem(at: fixture.base) }
        let project = makeProject(
            directories: [PatchDirectory(bundleID: bundleID, relativePath: "new/empty")],
            rules: [PatchRule(bundleID: bundleID, relativePath: "new/file.txt", replacementFilename: "file.txt", replacementData: Data("created".utf8))]
        )
        let folders = [bundleID: try PatchScopedFolder(testURL: fixture.root)]
        let preview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        let receipt = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: preview)
        try expect(fm.fileExists(atPath: fixture.root.appendingPathComponent("new/empty").path), "directory created")
        try expect(try Data(contentsOf: fixture.root.appendingPathComponent("new/file.txt")) == Data("created".utf8), "file created")
        try AuthorizedPatchService.restore(receipt: receipt, folders: folders)
        try expect(!fm.fileExists(atPath: fixture.root.appendingPathComponent("new").path), "created tree restored")
    }

    private static func testStalePreviewRejected() throws {
        let fixture = try makeFixture("stale-preview")
        defer { try? fm.removeItem(at: fixture.base) }
        let target = fixture.root.appendingPathComponent("prefs.dat")
        try Data("before".utf8).write(to: target)
        let project = makeProject(rules: [
            PatchRule(bundleID: bundleID, relativePath: "prefs.dat", replacementFilename: "prefs.dat", replacementData: Data("after".utf8))
        ])
        let folders = [bundleID: try PatchScopedFolder(testURL: fixture.root)]
        let preview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        try Data("changed".utf8).write(to: target)
        try expectPatchError(.operationPlanChanged) {
            _ = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: preview)
        }
        try expect(try Data(contentsOf: target) == Data("changed".utf8), "stale preview leaves target unchanged")
    }

    private static func testInterruptedApplyRollsBack() throws {
        let fixture = try makeFixture("rollback")
        defer { try? fm.removeItem(at: fixture.base) }
        let first = fixture.root.appendingPathComponent("first.txt")
        let second = fixture.root.appendingPathComponent("second.txt")
        try Data("first-original".utf8).write(to: first)
        try Data("second-original".utf8).write(to: second)
        let project = makeProject(rules: [
            PatchRule(bundleID: bundleID, relativePath: "first.txt", replacementFilename: "first.txt", replacementData: Data("first-new".utf8)),
            PatchRule(bundleID: bundleID, relativePath: "second.txt", replacementFilename: "second.txt", replacementData: Data("second-new".utf8))
        ])
        try expectOperationFailure {
            _ = try PatchTransaction.apply(
                project: project,
                backupRoot: fixture.backups,
                containerResolver: { _ in fixture.root },
                beforeWrite: { index in
                    if index == 1 { throw PatchTestError.assertion("injected interruption") }
                }
            )
        }
        try expect(try Data(contentsOf: first) == Data("first-original".utf8), "first write rolled back")
        try expect(try Data(contentsOf: second) == Data("second-original".utf8), "second write not started")
    }

    private static func testRestorePartialCanRetry() throws {
        let fixture = try makeFixture("restore-retry")
        defer { try? fm.removeItem(at: fixture.base) }
        let first = fixture.root.appendingPathComponent("first.dat")
        let second = fixture.root.appendingPathComponent("second.dat")
        try Data("first-before".utf8).write(to: first)
        try Data("second-before".utf8).write(to: second)
        let project = makeProject(rules: [
            PatchRule(bundleID: bundleID, relativePath: "first.dat", replacementFilename: "first.dat", replacementData: Data("first-after".utf8)),
            PatchRule(bundleID: bundleID, relativePath: "second.dat", replacementFilename: "second.dat", replacementData: Data("second-after".utf8))
        ])
        let folders = [bundleID: try PatchScopedFolder(testURL: fixture.root)]
        let preview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        let receipt = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: preview)
        try Data("first-before".utf8).write(to: first)
        try AuthorizedPatchService.restore(receipt: receipt, folders: folders)
        try expect(try Data(contentsOf: first) == Data("first-before".utf8), "first target already restored")
        try expect(try Data(contentsOf: second) == Data("second-before".utf8), "second target restored")
    }

    private static func testContainerIdentityValidAndSubstituted() throws {
        let fixture = try makeFixture("identity")
        defer { try? fm.removeItem(at: fixture.base) }
        let target = fixture.root.appendingPathComponent("prefs.dat")
        try Data("before".utf8).write(to: target)
        let project = makeProject(rules: [PatchRule(bundleID: bundleID, relativePath: "prefs.dat", replacementFilename: "prefs.dat", replacementData: Data("after".utf8))])
        let folders = [bundleID: try PatchScopedFolder(testURL: fixture.root)]
        let preview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        let receipt = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: preview)
        try fm.removeItem(at: fixture.root)
        try fm.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("other-container".utf8).write(to: fixture.root.appendingPathComponent("prefs.dat"))
        try expectPatchError(.restoreFailed) {
            try AuthorizedPatchService.restore(receipt: receipt, folders: folders)
        }
    }

    private static func testAuthorizationLossAndDeniedFile() throws {
        let fixture = try makeFixture("authorization")
        defer { try? fm.removeItem(at: fixture.base) }
        let target = fixture.root.appendingPathComponent("prefs.dat")
        try Data("before".utf8).write(to: target)
        let project = makeProject(rules: [PatchRule(bundleID: bundleID, relativePath: "prefs.dat", replacementFilename: "prefs.dat", replacementData: Data("after".utf8))])
        var allowed = true
        let folder = try PatchScopedFolder(testURL: fixture.root) { path in
            allowed && (path == fixture.root.path || path == target.path)
        }
        let folders = [bundleID: folder]
        let preview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        allowed = false
        try expectPatchError(.targetAppUnavailable(bundleID)) {
            _ = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: preview)
        }
        allowed = true
        let retryPreview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        let receipt = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: retryPreview)
        allowed = false
        try expectPatchError(.targetAppUnavailable(bundleID)) {
            try AuthorizedPatchService.restore(receipt: receipt, folders: folders)
        }
    }

    private static func testExternalConflictRejectsRestore() throws {
        let fixture = try makeFixture("external-conflict")
        defer { try? fm.removeItem(at: fixture.base) }
        let target = fixture.root.appendingPathComponent("prefs.dat")
        try Data("before".utf8).write(to: target)
        let project = makeProject(rules: [PatchRule(bundleID: bundleID, relativePath: "prefs.dat", replacementFilename: "prefs.dat", replacementData: Data("after".utf8))])
        let folders = [bundleID: try PatchScopedFolder(testURL: fixture.root)]
        let preview = try AuthorizedPatchService.prepare(project: project, folders: folders)
        let receipt = try AuthorizedPatchService.apply(project: project, folders: folders, confirmedPreview: preview)
        try Data("external-edit".utf8).write(to: target)
        try expectPatchError(.restoreFailed) {
            try AuthorizedPatchService.restore(receipt: receipt, folders: folders)
        }
    }

    private static func testRealPackageImportApplyRestoreIntegration() throws {
        let fixture = try makeFixture("package-import")
        defer { try? fm.removeItem(at: fixture.base) }
        let target = fixture.root.appendingPathComponent("Library/import.dat")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("package-before".utf8).write(to: target)
        let decodedProject = makeProject(rules: [PatchRule(bundleID: bundleID, relativePath: "Library/import.dat", replacementFilename: "import.dat", replacementData: Data("package-after".utf8))])
        let encoded = try PatchPackageCodec.encodeNew(project: decodedProject, password: nil)
        let packageURL = fixture.base.appendingPathComponent("integration.3105")
        try encoded.data.write(to: packageURL)
        let importedData = try PatchProjectLibrary.readPackage(at: packageURL)
        let imported = try PatchPackageCodec.decode(importedData, password: nil)
        let folders = [bundleID: try PatchScopedFolder(testURL: fixture.root)]
        let preview = try AuthorizedPatchService.prepare(project: imported.project, folders: folders)
        let receipt = try AuthorizedPatchService.apply(project: imported.project, folders: folders, confirmedPreview: preview)
        try expect(try Data(contentsOf: target) == Data("package-after".utf8), "decoded package applied")
        try AuthorizedPatchService.restore(receipt: receipt, folders: folders)
        try expect(try Data(contentsOf: target) == Data("package-before".utf8), "decoded package restored")
    }

    private static func makeProject(directories: [PatchDirectory] = [], rules: [PatchRule]) -> PatchProject {
        PatchProject(name: "Apply fixture", bundleIdentifiers: [bundleID], directories: directories, rules: rules)
    }

    private static func makeFixture(_ name: String) throws -> (base: URL, root: URL, backups: URL) {
        let base = fm.temporaryDirectory.appendingPathComponent("WQApply-\(name)-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let backups = base.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        return (base, root, backups)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PatchTestError.assertion(message) }
    }

    private static func expectPatchError(_ expected: PatchPackageError, operation: () throws -> Void) throws {
        do {
            try operation()
            throw PatchTestError.assertion("expected \(expected)")
        } catch let error as PatchPackageError {
            guard error == expected else { throw PatchTestError.assertion("unexpected patch error: \(error)") }
        } catch let error as PatchTestError {
            throw error
        }
    }

    private static func expectOperationFailure(operation: () throws -> Void) throws {
        do {
            try operation()
            throw PatchTestError.assertion("expected operation failure")
        } catch is PatchPackageError {}
    }
}
