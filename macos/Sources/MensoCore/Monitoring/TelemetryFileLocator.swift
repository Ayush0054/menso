import Foundation

public struct TelemetrySourceFile: Hashable, Sendable {
    public let path: String
    public let provider: AgentProvider

    public init(path: String, provider: AgentProvider) {
        self.path = path
        self.provider = provider
    }
}

public struct TelemetryFileLocator: Sendable {
    public let homeDirectory: URL
    public let maximumFilesPerProvider: Int

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumFilesPerProvider: Int = 256
    ) {
        self.homeDirectory = homeDirectory
        self.maximumFilesPerProvider = maximumFilesPerProvider
    }

    public func discover() -> [TelemetrySourceFile] {
        var files: [TelemetrySourceFile] = []
        files.append(contentsOf: jsonlFiles(
            below: homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory),
            provider: .claudeCode,
            requiredPrefix: nil
        ))
        files.append(contentsOf: jsonlFiles(
            below: homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory),
            provider: .codex,
            requiredPrefix: "rollout-"
        ))
        return files
    }

    public func watchRoots(fileManager: FileManager = .default) -> [URL] {
        [
            homeDirectory.appending(path: ".claude", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".codex", directoryHint: .isDirectory),
        ].filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func jsonlFiles(
        below root: URL,
        provider: AgentProvider,
        requiredPrefix: String?
    ) -> [TelemetrySourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            if let requiredPrefix, !url.lastPathComponent.hasPrefix(requiredPrefix) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumFilesPerProvider)
            .map { TelemetrySourceFile(path: $0.url.path, provider: provider) }
    }
}
