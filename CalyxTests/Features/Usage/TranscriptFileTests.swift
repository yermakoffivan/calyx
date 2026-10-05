//
//  TranscriptFileTests.swift
//  CalyxTests
//
//  Pins TranscriptFile.open(atPath:): a
//  regular file opens with its inode and size; a missing path, a symbolic
//  link at the final component, a directory, and a path that reaches the
//  file through a linked directory (`redirected`) do not. Paths are built
//  from realpath(3) of a per-test temporary directory, which is the
//  spelling F_GETPATH reports there.
//

import XCTest
@testable import Calyx

final class TranscriptFileTests: XCTestCase {

    private var tempPath: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        tempPath = String(cString: resolved)
        free(resolved)
    }

    override func tearDownWithError() throws {
        if let tempPath {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        tempPath = nil
        try super.tearDownWithError()
    }

    private func base() throws -> String {
        try XCTUnwrap(tempPath)
    }

    private func makeFile(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Closes an opened descriptor; returns what was opened.
    private func openAndClose(_ path: String) -> TranscriptFile.Outcome {
        let outcome = TranscriptFile.open(atPath: path)
        if case .opened(let opened) = outcome {
            close(opened.descriptor)
        }
        return outcome
    }

    func test_regularFile_opensWithItsInodeAndSize() throws {
        let path = try base() + "/dir/a.jsonl"
        try makeFile(path, "{}\n{}\n")
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0, "Fixture error")

        let outcome = TranscriptFile.open(atPath: path)
        guard case .opened(let opened) = outcome else { return XCTFail("Got \(outcome)") }
        defer { close(opened.descriptor) }

        XCTAssertGreaterThanOrEqual(opened.descriptor, 0)
        XCTAssertEqual(opened.inode, UInt64(status.st_ino))
        XCTAssertEqual(opened.size, 6)
    }

    func test_missingPath_isMissing() throws {
        XCTAssertEqual(openAndClose(try base() + "/dir/none.jsonl"), .missing)
    }

    func test_symbolicLinkAtTheFinalComponent_isNotARegularFile() throws {
        let target = try base() + "/dir/target.jsonl"
        try makeFile(target, "{}\n")
        let link = try base() + "/dir/link.jsonl"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        XCTAssertEqual(openAndClose(link), .notARegularFile)
    }

    func test_directory_isNotARegularFile() throws {
        let path = try base() + "/dir/a.jsonl"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        XCTAssertEqual(openAndClose(path), .notARegularFile)
    }

    func test_pathThroughALinkedDirectory_isRedirected() throws {
        try makeFile(try base() + "/real/a.jsonl", "{}\n")
        try FileManager.default.createSymbolicLink(atPath: try base() + "/linked", withDestinationPath: try base() + "/real")

        XCTAssertEqual(openAndClose(try base() + "/linked/a.jsonl"), .redirected)
    }

    func test_lineReaderDefaults_arePinned() {
        XCTAssertEqual(TranscriptLineReader.defaultMaxLineBytes, 16_777_216)
        XCTAssertEqual(TranscriptLineReader.defaultByteBudget, 4_194_304)
    }
}
