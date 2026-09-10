import Foundation

public struct FileTailBatch: Sendable {
    public let lines: [Data]
    public let nextCursor: FileTailCursor
    public let didRotate: Bool
    public let skippedOversizedFragment: Bool

    public init(
        lines: [Data],
        nextCursor: FileTailCursor,
        didRotate: Bool,
        skippedOversizedFragment: Bool
    ) {
        self.lines = lines
        self.nextCursor = nextCursor
        self.didRotate = didRotate
        self.skippedOversizedFragment = skippedOversizedFragment
    }
}

public struct IncrementalJSONLTailer: Sendable {
    public let maximumReadBytes: Int
    public let maximumLineBytes: Int

    public init(
        maximumReadBytes: Int = 2 * 1_024 * 1_024,
        maximumLineBytes: Int = 1_024 * 1_024
    ) {
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumReadBytes = max(
            maximumReadBytes,
            self.maximumLineBytes + 64 * 1_024
        )
    }

    public func read(
        path: String,
        cursor existingCursor: FileTailCursor?
    ) throws -> FileTailBatch {
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let identity = FileIdentity(
            deviceID: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let didRotate = existingCursor.map { $0.identity != identity || $0.byteOffset > fileSize } ?? false
        let startOffset = didRotate ? 0 : min(existingCursor?.byteOffset ?? 0, fileSize)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)
        let data = try handle.read(upToCount: maximumReadBytes) ?? Data()

        var consumedBytes = 0
        var lines: [Data] = []
        var skippedOversizedFragment = false
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let raw = data[start..<newline]
            let line = raw.last == 0x0D ? raw.dropLast() : raw
            if !line.isEmpty, line.count <= maximumLineBytes {
                lines.append(Data(line))
            } else if line.count > maximumLineBytes {
                skippedOversizedFragment = true
            }
            consumedBytes = data.distance(from: data.startIndex, to: data.index(after: newline))
            start = data.index(after: newline)
        }

        let trailingFragmentBytes = data.count - consumedBytes
        if trailingFragmentBytes > maximumLineBytes {
            // A corrupt or unexpectedly huge unterminated record must not pin
            // the cursor forever. Advance the bounded bytes already read,
            // including when valid records preceded this trailing fragment.
            consumedBytes = data.count
            skippedOversizedFragment = true
        }

        return FileTailBatch(
            lines: lines,
            nextCursor: FileTailCursor(
                path: path,
                identity: identity,
                byteOffset: startOffset + UInt64(consumedBytes),
                updatedAt: .now
            ),
            didRotate: didRotate,
            skippedOversizedFragment: skippedOversizedFragment
        )
    }
}
