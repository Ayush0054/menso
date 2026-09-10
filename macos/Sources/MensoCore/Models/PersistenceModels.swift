import Foundation

public struct FileIdentity: Codable, Hashable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }
}

public struct FileTailCursor: Codable, Hashable, Sendable {
    public let path: String
    public var identity: FileIdentity
    public var byteOffset: UInt64
    public var updatedAt: Date

    public init(
        path: String,
        identity: FileIdentity,
        byteOffset: UInt64 = 0,
        updatedAt: Date = .now
    ) {
        self.path = path
        self.identity = identity
        self.byteOffset = byteOffset
        self.updatedAt = updatedAt
    }
}
