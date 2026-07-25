#if canImport(Containerization)
import Containerization
import ContainerizationArchive
#if canImport(ExecutorCore)
import ExecutorCore
#endif
import Foundation

@available(macOS 26.0, *)
actor AppleContainerRuntime: ContainerRuntime {
    nonisolated let capabilityState: ExecutorCapabilityState = .available

    private let manifest: ExecutorArtifactManifestPayload
    private let cache: ExecutorArtifactCache
    private let cacheRoot: URL
    private var running: [UUID: LinuxContainer] = [:]

    init(
        manifest: ExecutorArtifactManifestPayload,
        cache: ExecutorArtifactCache,
        cacheRoot: URL
    ) {
        self.manifest = manifest
        self.cache = cache
        self.cacheRoot = cacheRoot
    }

    func execute(_ request: ValidatedExecution) async throws -> ExecutionResult {
        guard request.grant.capabilities.egressDestinations.isEmpty else {
            // Containerization 0.33.3 can omit an interface, but does not expose
            // a destination firewall. Deny rather than silently grant broad egress.
            throw LocalActionError.invalidBinding("destination-bounded egress is unavailable")
        }
        let kernelURL = try await bootstrapKernel()
        let initArtifact = try artifact(.initImage)
        let imageArtifact = try artifact(.workloadImage)
        guard imageArtifact.sha256 == request.grant.imageDigest.dropSHA256Prefix else {
            throw LocalActionError.invalidBinding("workload image artifact")
        }

        let actionID = request.grant.actionID
        let identifier = "perch-\(actionID.uuidString.lowercased())"
        let stateRoot = cacheRoot.appendingPathComponent("runs/\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var manager = try await ContainerManager(
            kernel: Kernel(path: kernelURL, platform: .linuxArm),
            initfsReference: initArtifact.reference,
            root: stateRoot,
            network: nil,
            rosetta: false,
            nestedVirtualization: false
        )
        let stdout = RuntimeOutputWriter(limit: request.grant.capabilities.limits.outputBytes)
        let stderr = RuntimeOutputWriter(limit: request.grant.capabilities.limits.outputBytes)
        let workspaceOptions = request.workspace.readOnly
            ? ["ro", "nosuid", "nodev"]
            : ["rw", "nosuid", "nodev"]
        let limits = request.grant.capabilities.limits
        let container = try await manager.create(
            identifier,
            reference: imageArtifact.reference,
            rootfsSizeInBytes: limits.diskBytes,
            writableLayerSizeInBytes: nil,
            readOnly: true,
            networking: false
        ) { config in
            config.cpus = limits.cpuCount
            config.memoryInBytes = limits.memoryBytes
            config.virtualization = false
            config.sockets = []
            config.interfaces = []
            config.dns = nil
            config.process.arguments = [request.action.executable] + request.action.arguments
            config.process.workingDirectory = request.action.workingDirectory
            config.process.environmentVariables = [
                "PATH=/usr/local/bin:/usr/bin:/bin",
                "HOME=/nonexistent",
                "LANG=C.UTF-8",
            ]
            config.process.capabilities = LinuxCapabilities()
            config.process.noNewPrivileges = true
            config.process.rlimits = [
                LinuxRLimit(kind: .cpuTime, limit: UInt64(limits.timeoutSeconds)),
                LinuxRLimit(kind: .fileSize, limit: limits.diskBytes),
                LinuxRLimit(kind: .numberOfProcesses, limit: UInt64(limits.processCount)),
                LinuxRLimit(kind: .openFiles, limit: 256),
                LinuxRLimit(kind: .coreFileSize, limit: 0),
            ]
            config.process.stdout = stdout
            config.process.stderr = stderr
            config.mounts.append(.share(
                source: request.workspace.root.path,
                destination: "/workspace",
                options: workspaceOptions
            ))
            config.mounts.append(.any(
                type: "tmpfs",
                source: "tmpfs",
                destination: "/tmp",
                options: ["nosuid", "nodev", "noexec", "size=67108864"]
            ))
        }
        running[actionID] = container
        let started = ContinuousClock.now
        defer {
            running.removeValue(forKey: actionID)
            try? manager.delete(identifier)
            try? FileManager.default.removeItem(at: stateRoot)
        }

        do {
            try await container.create()
            try Task.checkCancellation()
            try await container.start()
            let status = try await withTaskCancellationHandler {
                try await container.wait(timeoutInSeconds: Int64(limits.timeoutSeconds))
            } onCancel: {
                Task { try? await container.stop() }
            }
            try await container.stop()
            let elapsed = started.duration(to: .now)
            let output = stdout.snapshot()
            let errorOutput = stderr.snapshot()
            let sanitizer = HostileOutputSanitizer()
            let safeOut = sanitizer.sanitize(
                output.data,
                allowSensitiveDisclosure: request.grant.capabilities.sensitiveOutputDisclosure
            )
            let safeError = sanitizer.sanitize(
                errorOutput.data,
                allowSensitiveDisclosure: request.grant.capabilities.sensitiveOutputDisclosure
            )
            return ExecutionResult(
                status: status.exitCode == 0 ? .completed : .failed,
                exitCode: status.exitCode,
                stdout: safeOut.text,
                stderr: safeError.text,
                truncated: output.truncated || errorOutput.truncated,
                durationMilliseconds: Int(elapsed.components.seconds * 1_000)
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
                redactions: safeOut.redactions + safeError.redactions
            )
        } catch is CancellationError {
            try? await container.stop()
            return ExecutionResult(
                status: .cancelled,
                exitCode: nil,
                stdout: "",
                stderr: "Execution cancelled.",
                truncated: false,
                durationMilliseconds: 0,
                redactions: 0
            )
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func cancel(actionID: UUID) async {
        try? await running[actionID]?.stop()
    }

    func cleanup(actionID: UUID) async {
        try? await running[actionID]?.stop()
        running.removeValue(forKey: actionID)
    }

    private func artifact(_ kind: ExecutorArtifact.Kind) throws -> ExecutorArtifact {
        guard let artifact = manifest.artifacts.first(where: { $0.kind == kind }) else {
            throw ArtifactVerificationError.invalidManifest
        }
        return artifact
    }

    private func bootstrapKernel() async throws -> URL {
        let kernel = try artifact(.kernel)
        let kernelURL = cacheRoot.appendingPathComponent(kernel.sha256)
        if FileManager.default.fileExists(atPath: kernelURL.path) {
            try await cache.verifyExtracted(kernelURL, artifact: kernel)
            return kernelURL
        }
        let archive = try artifact(.kernelArchive)
        let archiveURL = try await cache.verifiedFile(for: archive, allowBootstrap: true)
        let extractionRoot = cacheRoot.appendingPathComponent(".extract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extractionRoot) }
        try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: false)
        let rejected = try ArchiveReader(file: archiveURL).extractContents(to: extractionRoot)
        guard rejected.isEmpty else {
            throw ArtifactVerificationError.invalidArtifact("kernel archive contains unsafe paths")
        }
        let extracted = extractionRoot.appendingPathComponent(
            "opt/kata/share/kata-containers/vmlinux-6.12.28-153"
        )
        try await cache.verifyExtracted(extracted, artifact: kernel)
        try FileManager.default.moveItem(at: extracted, to: kernelURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: kernelURL.path)
        return kernelURL
    }
}

private final class RuntimeOutputWriter: Writer, @unchecked Sendable {
    private let writer: BoundedOutputWriter
    init(limit: Int) { writer = BoundedOutputWriter(limit: limit) }
    func write(_ data: Data) throws { writer.append(data) }
    func close() throws {}
    func snapshot() -> (data: Data, truncated: Bool) { writer.snapshot() }
}

private extension String {
    var dropSHA256Prefix: String {
        hasPrefix("sha256:") ? String(dropFirst("sha256:".count)) : self
    }
}
#endif
