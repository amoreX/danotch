import Darwin
import Foundation
import XCTest
#if canImport(ExecutorCore)
@testable import ExecutorCore
#else
@testable import Perch
#endif

private final class FakeBookmarkResolver: WorkspaceBookmarkResolving, @unchecked Sendable {
    let url: URL
    var stale = false
    var allowed = true
    init(url: URL) { self.url = url }
    func create(for url: URL) throws -> WorkspaceBookmark { WorkspaceBookmark(data: Data(url.path.utf8)) }
    func resolve(_ bookmark: WorkspaceBookmark) throws -> (url: URL, stale: Bool) { (url, stale) }
    func startAccessing(_ url: URL) -> Bool { allowed }
    func stopAccessing(_ url: URL) {}
}

final class WorkspaceAccessTests: XCTestCase {
    func testAcceptsSelectedPlainTreeAndDetectsSensitiveFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent(".env"))
        let resolver = FakeBookmarkResolver(url: root)
        let scope = try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data("bookmark".utf8)),
            mode: .readOnly
        )
        defer { scope.close() }
        XCTAssertTrue(scope.readOnly)
        XCTAssertTrue(scope.containsSensitiveFiles)
        XCTAssertEqual(
            try WorkspaceAccess(bookmarks: resolver)
                .validateRelativePath("Sources/File.swift", in: scope).path,
            scope.root.appendingPathComponent("Sources/File.swift").path
        )
        XCTAssertNotEqual(scope.root.path, root.path)
        XCTAssertThrowsError(try WorkspaceAccess(bookmarks: resolver)
            .validateRelativePath("../credentials", in: scope))
    }

    func testRejectsStaleBookmarkAndSymlinkEscape() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = FakeBookmarkResolver(url: root)
        resolver.stale = true
        XCTAssertThrowsError(try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data()),
            mode: .readOnly
        ))
        resolver.stale = false
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
        )
        XCTAssertThrowsError(try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data()),
            mode: .readOnly
        ))
    }

    func testRejectsHardLinksAndFIFOs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try Data("data".utf8).write(to: first)
        XCTAssertEqual(link(first.path, second.path), 0)
        let resolver = FakeBookmarkResolver(url: root)
        XCTAssertThrowsError(try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data()),
            mode: .readOnly
        ))

        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data()),
            mode: .readOnly
        ))
    }

    func testSnapshotIsIndependentFromLaterSourcePathSwap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("value.txt")
        try Data("approved".utf8).write(to: source)
        let resolver = FakeBookmarkResolver(url: root)
        let scope = try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data()),
            mode: .readOnly
        )
        defer { scope.close() }

        try FileManager.default.removeItem(at: source)
        try Data("changed-after-validation".utf8).write(to: source)
        let staged = try String(
            contentsOf: scope.root.appendingPathComponent("value.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(staged, "approved")
        XCTAssertNotEqual(scope.root.path, root.path)
    }

    func testSnapshotAppliesFileAndByteQuotas() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 32).write(to: root.appendingPathComponent("large"))
        let resolver = FakeBookmarkResolver(url: root)
        XCTAssertThrowsError(try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data()),
            mode: .readOnly,
            quota: .init(maximumFiles: 10, maximumBytes: 16)
        ))
        try FileManager.default.removeItem(at: root.appendingPathComponent("large"))
        try Data().write(to: root.appendingPathComponent("one"))
        try Data().write(to: root.appendingPathComponent("two"))
        XCTAssertThrowsError(try WorkspaceAccess(bookmarks: resolver).open(
            bookmark: WorkspaceBookmark(data: Data()),
            mode: .readOnly,
            quota: .init(maximumFiles: 1, maximumBytes: 16)
        ))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
