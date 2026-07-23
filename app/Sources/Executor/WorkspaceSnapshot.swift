import Darwin
import Foundation

public struct WorkspaceSnapshotQuota: Equatable, Sendable {
    public let maximumFiles: Int
    public let maximumBytes: UInt64

    public init(maximumFiles: Int, maximumBytes: UInt64) {
        self.maximumFiles = maximumFiles
        self.maximumBytes = maximumBytes
    }
}

enum WorkspaceSnapshotError: Error, Equatable {
    case invalidQuota
    case unsafeEntry(String)
    case quotaExceeded
    case sourceChanged(String)
    case ioFailure(String)
}

/// Copies a selected workspace through already-open directory/file descriptors.
/// The VM receives only the private snapshot path, never the mutable source path.
struct WorkspaceSnapshotter: Sendable {
    private let stagingRoot: URL

    init(stagingRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PerchExecutorSnapshots", isDirectory: true)) {
        self.stagingRoot = stagingRoot
    }

    func stage(
        source: URL,
        quota: WorkspaceSnapshotQuota,
        readOnly: Bool
    ) throws -> URL {
        guard quota.maximumFiles > 0, quota.maximumBytes > 0 else {
            throw WorkspaceSnapshotError.invalidQuota
        }
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(destination.path, 0o700) == 0 else {
            throw WorkspaceSnapshotError.ioFailure("create staging directory")
        }
        var keepDestination = false
        defer {
            if !keepDestination { try? FileManager.default.removeItem(at: destination) }
        }

        let sourceFD = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else {
            throw WorkspaceSnapshotError.ioFailure("open selected workspace")
        }
        defer { close(sourceFD) }
        var rootStat = stat()
        guard fstat(sourceFD, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkspaceSnapshotError.ioFailure("stat selected workspace")
        }
        var counters = Counters()
        try copyDirectory(
            sourceFD: sourceFD,
            destination: destination,
            rootDevice: rootStat.st_dev,
            relativePath: "",
            quota: quota,
            counters: &counters
        )
        try applySnapshotPermissions(destination, readOnly: readOnly)
        keepDestination = true
        return destination
    }

    private func copyDirectory(
        sourceFD: Int32,
        destination: URL,
        rootDevice: dev_t,
        relativePath: String,
        quota: WorkspaceSnapshotQuota,
        counters: inout Counters
    ) throws {
        guard let directory = fdopendir(dup(sourceFD)) else {
            throw WorkspaceSnapshotError.ioFailure("enumerate \(relativePath)")
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard !name.contains("/"), !name.contains("\0") else {
                throw WorkspaceSnapshotError.unsafeEntry(path(relativePath, name))
            }
            let childRelative = path(relativePath, name)
            var before = stat()
            guard fstatat(sourceFD, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw WorkspaceSnapshotError.sourceChanged(childRelative)
            }
            guard before.st_dev == rootDevice else {
                throw WorkspaceSnapshotError.unsafeEntry(childRelative + " (nested mount)")
            }
            counters.files += 1
            guard counters.files <= quota.maximumFiles else {
                throw WorkspaceSnapshotError.quotaExceeded
            }
            let destinationChild = destination.appendingPathComponent(name)
            switch before.st_mode & S_IFMT {
            case S_IFDIR:
                let childFD = openat(sourceFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { throw WorkspaceSnapshotError.sourceChanged(childRelative) }
                defer { close(childFD) }
                var opened = stat()
                guard fstat(childFD, &opened) == 0,
                      sameIdentity(before, opened),
                      mkdir(destinationChild.path, 0o700) == 0 else {
                    throw WorkspaceSnapshotError.sourceChanged(childRelative)
                }
                try copyDirectory(
                    sourceFD: childFD,
                    destination: destinationChild,
                    rootDevice: rootDevice,
                    relativePath: childRelative,
                    quota: quota,
                    counters: &counters
                )
            case S_IFREG:
                guard before.st_nlink == 1, before.st_size >= 0 else {
                    throw WorkspaceSnapshotError.unsafeEntry(childRelative + " (hard link)")
                }
                let size = UInt64(before.st_size)
                guard size <= quota.maximumBytes - min(counters.bytes, quota.maximumBytes) else {
                    throw WorkspaceSnapshotError.quotaExceeded
                }
                let input = openat(sourceFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard input >= 0 else { throw WorkspaceSnapshotError.sourceChanged(childRelative) }
                defer { close(input) }
                var opened = stat()
                guard fstat(input, &opened) == 0, sameIdentity(before, opened) else {
                    throw WorkspaceSnapshotError.sourceChanged(childRelative)
                }
                let output = open(destinationChild.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o400)
                guard output >= 0 else {
                    throw WorkspaceSnapshotError.ioFailure("create \(childRelative)")
                }
                do {
                    try copyFile(input: input, output: output, expectedBytes: size)
                } catch {
                    close(output)
                    throw error
                }
                guard close(output) == 0 else {
                    throw WorkspaceSnapshotError.ioFailure("close \(childRelative)")
                }
                var after = stat()
                guard fstat(input, &after) == 0,
                      sameIdentity(opened, after),
                      after.st_size == opened.st_size,
                      after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                      after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
                    throw WorkspaceSnapshotError.sourceChanged(childRelative)
                }
                counters.bytes += size
            case S_IFLNK:
                throw WorkspaceSnapshotError.unsafeEntry(childRelative + " (symbolic link)")
            case S_IFSOCK:
                throw WorkspaceSnapshotError.unsafeEntry(childRelative + " (socket)")
            case S_IFIFO:
                throw WorkspaceSnapshotError.unsafeEntry(childRelative + " (FIFO)")
            case S_IFCHR, S_IFBLK:
                throw WorkspaceSnapshotError.unsafeEntry(childRelative + " (device)")
            default:
                throw WorkspaceSnapshotError.unsafeEntry(childRelative)
            }
        }
    }

    private func copyFile(input: Int32, output: Int32, expectedBytes: UInt64) throws {
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw WorkspaceSnapshotError.ioFailure("read source")
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    write(output, $0.baseAddress!.advanced(by: written), count - written)
                }
                guard result > 0 else {
                    if result < 0, errno == EINTR { continue }
                    throw WorkspaceSnapshotError.ioFailure("write snapshot")
                }
                written += result
            }
            total += UInt64(count)
        }
        guard total == expectedBytes else {
            throw WorkspaceSnapshotError.sourceChanged("file size changed")
        }
    }

    private func applySnapshotPermissions(_ root: URL, readOnly: Bool) throws {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            try FileManager.default.setAttributes(
                [.posixPermissions: values.isDirectory == true
                    ? (readOnly ? 0o500 : 0o700)
                    : (readOnly ? 0o400 : 0o600)],
                ofItemAtPath: url.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: readOnly ? 0o500 : 0o700],
            ofItemAtPath: root.path
        )
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private func path(_ parent: String, _ child: String) -> String {
        parent.isEmpty ? child : parent + "/" + child
    }

    private struct Counters {
        var files = 0
        var bytes: UInt64 = 0
    }
}
