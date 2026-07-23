#if canImport(ExecutorCore)
import ExecutorCore
#endif
import Foundation

@main
struct PerchExecutorMain {
    static func main() async {
        guard #available(macOS 26.0, *) else {
            fail("unsupported: Perch Executor requires macOS 26")
        }
        #if !arch(arm64)
        fail("unsupported: Perch Executor requires Apple silicon")
        #else
        do {
            #if SWIFT_PACKAGE
            let resourceBundle = Bundle.module
            #else
            let resourceBundle = Bundle.main
            #endif
            let adjacentManifestURL = URL(fileURLWithPath: CommandLine.arguments[0])
                .standardizedFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("ExecutorArtifacts.json", isDirectory: false)
            guard let manifestURL = resourceBundle.url(
                forResource: "ExecutorArtifacts",
                withExtension: "json"
            ) ?? (FileManager.default.fileExists(atPath: adjacentManifestURL.path)
                ? adjacentManifestURL
                : nil) else {
                throw ArtifactVerificationError.invalidManifest
            }
            let manifest = try ExecutorArtifactManifestVerifier().verify(
                data: Data(contentsOf: manifestURL)
            )
            if CommandLine.arguments == [CommandLine.arguments[0], "--ipc"] {
                try await runIPC(manifest: manifest)
                return
            }
            if CommandLine.arguments.contains("--capability") {
                print("available containerization=\(manifest.containerizationVersion) architecture=arm64")
                return
            }
            if CommandLine.arguments.contains("--verify-artifacts") {
                print("verified signed manifest with \(manifest.artifacts.count) pinned artifacts")
                return
            }
            fail("No execution request was supplied. This service accepts only authenticated app requests.")
        } catch {
            fail("executor unavailable: \(error.localizedDescription)")
        }
        #endif
    }

    @available(macOS 26.0, *)
    private static func runIPC(
        manifest: ExecutorArtifactManifestPayload
    ) async throws {
        let input = try readBoundedStandardInput()
        let request = try ExecutorIPCRequest.decode(input)
        let grant = try ExecutorIPCAuthenticator().verify(request)
        guard let grantIDValue = grant["grant_id"] as? String,
              let grantID = UUID(uuidString: grantIDValue) else {
            throw ExecutorIPCError.malformed
        }
        let cacheRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Perch/Executor", isDirectory: true)
        try ExecutorIPCReplayGuard(
            root: cacheRoot.appendingPathComponent("ConsumedIPC", isDirectory: true)
        ).claim(requestID: request.requestID, grantID: grantID)

        let execution = try ExecutorRequestDecoder().validatedExecution(
            request: request,
            grant: grant,
            manifest: manifest
        )
        defer { execution.workspace.close() }
        let artifactCacheRoot = cacheRoot.appendingPathComponent("Artifacts", isDirectory: true)
        let runtime = AppleContainerRuntime(
            manifest: manifest,
            cache: ExecutorArtifactCache(root: artifactCacheRoot),
            cacheRoot: artifactCacheRoot
        )
        let result = try await runtime.execute(execution)
        var object = result.protocolObject
        object["status"] = result.status.rawValue
        let resultJSON = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let response = try ExecutorIPCResponse(
            requestID: request.requestID,
            resultJSON: resultJSON,
            ipcSecret: request.ipcSecret
        )
        let encoded = try JSONEncoder().encode(response)
        guard encoded.count <= ExecutorIPCResponse.maximumBytes else {
            throw ExecutorIPCError.oversized
        }
        FileHandle.standardOutput.write(encoded)
    }

    private static func readBoundedStandardInput() throws -> Data {
        var result = Data()
        while true {
            guard let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty else { break }
            result.append(chunk)
            guard result.count <= ExecutorIPCRequest.maximumBytes else {
                throw ExecutorIPCError.oversized
            }
        }
        return result
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(78)
    }
}
