import CryptoKit
import Darwin
import Foundation

public struct WorkspaceBookmark: Hashable, Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
    public var hash: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct WorkspaceScope: Sendable {
    public let selectedRoot: URL
    public let root: URL
    public let bookmark: WorkspaceBookmark
    public let readOnly: Bool
    public let containsSensitiveFiles: Bool
    fileprivate let stopAccessing: @Sendable () -> Void

    public func close() { stopAccessing() }
}

enum WorkspaceAccessError: Error, Equatable, LocalizedError {
    case staleBookmark
    case securityScopeDenied
    case notDirectory
    case unsafeEntry(String)
    case changedDuringValidation

    var errorDescription: String? {
        switch self {
        case .staleBookmark: return "Workspace permission is stale. Select the workspace again."
        case .securityScopeDenied: return "macOS denied access to the selected workspace."
        case .notDirectory: return "The selected workspace is not a directory."
        case .unsafeEntry(let path): return "Workspace contains an unsafe entry: \(path)"
        case .changedDuringValidation: return "Workspace changed while it was being validated."
        }
    }
}

protocol WorkspaceBookmarkResolving: Sendable {
    func create(for url: URL) throws -> WorkspaceBookmark
    func resolve(_ bookmark: WorkspaceBookmark) throws -> (url: URL, stale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SecurityScopedBookmarkResolver: WorkspaceBookmarkResolving {
    func create(for url: URL) throws -> WorkspaceBookmark {
        WorkspaceBookmark(data: try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ))
    }

    func resolve(_ bookmark: WorkspaceBookmark) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark.data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

struct WorkspaceAccess: @unchecked Sendable {
    private let bookmarks: WorkspaceBookmarkResolving
    private let fileManager: FileManager
    private let snapshotter: WorkspaceSnapshotter

    init(
        bookmarks: WorkspaceBookmarkResolving = SecurityScopedBookmarkResolver(),
        fileManager: FileManager = .default,
        snapshotter: WorkspaceSnapshotter = WorkspaceSnapshotter()
    ) {
        self.bookmarks = bookmarks
        self.fileManager = fileManager
        self.snapshotter = snapshotter
    }

    func open(
        bookmark: WorkspaceBookmark,
        mode: ExecutionCapabilities.WorkspaceMode,
        quota: WorkspaceSnapshotQuota = .init(
            maximumFiles: 100_000,
            maximumBytes: 1_073_741_824
        )
    ) throws -> WorkspaceScope {
        let resolved = try bookmarks.resolve(bookmark)
        guard !resolved.stale else { throw WorkspaceAccessError.staleBookmark }
        guard bookmarks.startAccessing(resolved.url) else {
            throw WorkspaceAccessError.securityScopeDenied
        }
        do {
            let selectedRoot = resolved.url.standardizedFileURL
            let stagedRoot: URL
            do {
                stagedRoot = try snapshotter.stage(
                    source: selectedRoot,
                    quota: quota,
                    readOnly: mode == .readOnly
                )
            } catch let error as WorkspaceSnapshotError {
                throw WorkspaceAccessError.unsafeEntry(String(describing: error))
            }
            let sensitive = try validateTree(stagedRoot)
            return WorkspaceScope(
                selectedRoot: selectedRoot,
                root: stagedRoot,
                bookmark: bookmark,
                readOnly: mode == .readOnly,
                containsSensitiveFiles: sensitive,
                stopAccessing: {
                    try? FileManager.default.removeItem(at: stagedRoot)
                    bookmarks.stopAccessing(resolved.url)
                }
            )
        } catch {
            bookmarks.stopAccessing(resolved.url)
            throw error
        }
    }

    func validateRelativePath(_ path: String, in scope: WorkspaceScope) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw WorkspaceAccessError.unsafeEntry(path)
        }
        let candidate = scope.root.appendingPathComponent(path).standardizedFileURL
        let rootPath = scope.root.path.hasSuffix("/") ? scope.root.path : scope.root.path + "/"
        guard candidate.path == scope.root.path || candidate.path.hasPrefix(rootPath) else {
            throw WorkspaceAccessError.unsafeEntry(path)
        }
        return candidate
    }

    private func validateTree(_ root: URL) throws -> Bool {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkspaceAccessError.notDirectory
        }
        let originalRoot = (device: rootInfo.st_dev, inode: rootInfo.st_ino)
        var containsSensitive = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else {
            throw WorkspaceAccessError.notDirectory
        }

        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw WorkspaceAccessError.changedDuringValidation
            }
            let type = info.st_mode & S_IFMT
            guard info.st_dev == rootInfo.st_dev else {
                throw WorkspaceAccessError.unsafeEntry(relative(url, root: root) + " (nested mount)")
            }
            switch type {
            case S_IFDIR:
                break
            case S_IFREG:
                guard info.st_nlink == 1 else {
                    throw WorkspaceAccessError.unsafeEntry(relative(url, root: root) + " (hard link)")
                }
            case S_IFLNK:
                throw WorkspaceAccessError.unsafeEntry(relative(url, root: root) + " (symbolic link)")
            case S_IFSOCK:
                throw WorkspaceAccessError.unsafeEntry(relative(url, root: root) + " (socket)")
            case S_IFIFO:
                throw WorkspaceAccessError.unsafeEntry(relative(url, root: root) + " (FIFO)")
            case S_IFCHR, S_IFBLK:
                throw WorkspaceAccessError.unsafeEntry(relative(url, root: root) + " (device)")
            default:
                throw WorkspaceAccessError.unsafeEntry(relative(url, root: root))
            }
            if isSensitive(url: url, root: root) { containsSensitive = true }
        }

        guard lstat(root.path, &rootInfo) == 0,
              rootInfo.st_dev == originalRoot.device,
              rootInfo.st_ino == originalRoot.inode else {
            throw WorkspaceAccessError.changedDuringValidation
        }
        return containsSensitive
    }

    private func relative(_ url: URL, root: URL) -> String {
        String(url.path.dropFirst(min(root.path.count + 1, url.path.count)))
    }

    private func isSensitive(url: URL, root: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let relativePath = relative(url, root: root).lowercased()
        let exact = Set([
            ".env", ".env.local", ".npmrc", ".pypirc", "credentials.json",
            "id_rsa", "id_ed25519", ".netrc",
        ])
        return exact.contains(name)
            || name.hasSuffix(".pem")
            || name.hasSuffix(".key")
            || relativePath.hasPrefix(".ssh/")
            || relativePath.hasPrefix(".aws/")
            || relativePath.hasPrefix(".config/gcloud/")
    }
}
