import Darwin
import Foundation
import XCTest
@testable import MensoCore

final class CuaSocketPathTests: XCTestCase {
    func testPerUserTemporaryDirectoriesFitIncludingPrivatePrefix() throws {
        for prefix in ["/var", "/private/var"] {
            let directory = URL(
                fileURLWithPath: "\(prefix)/folders/0p/ytd6xzr16kvb41t4rjh8656h0000gn/T/",
                isDirectory: true
            )
            let path = try PinnedEmbeddedCuaDriverHost.makePrivateSocketPath(in: directory)
            let address = sockaddr_un()
            XCTAssertLessThanOrEqual(path.utf8CString.count, MemoryLayout.size(ofValue: address.sun_path))
            XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent(), directory)
            let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            XCTAssertTrue(filename.hasPrefix("m-"))
            XCTAssertNotNil(UUID(uuidString: String(filename.dropFirst(2))))
            XCTAssertNotEqual(path, try PinnedEmbeddedCuaDriverHost.makePrivateSocketPath(in: directory))
        }
    }

    func testOversizedDirectoryFailsClosed() {
        let directory = URL(fileURLWithPath: "/" + String(repeating: "x", count: 104), isDirectory: true)
        XCTAssertThrowsError(try PinnedEmbeddedCuaDriverHost.makePrivateSocketPath(in: directory)) {
            XCTAssertEqual($0 as? PinnedEmbeddedCuaDriverHostError, .endpointConflict)
        }
    }

    func testSocketLimitCountsUTF8Bytes() {
        let directory = URL(fileURLWithPath: "/" + String(repeating: "é", count: 40), isDirectory: true)
        XCTAssertThrowsError(try PinnedEmbeddedCuaDriverHost.makePrivateSocketPath(in: directory)) {
            XCTAssertEqual($0 as? PinnedEmbeddedCuaDriverHostError, .endpointConflict)
        }
    }
}
