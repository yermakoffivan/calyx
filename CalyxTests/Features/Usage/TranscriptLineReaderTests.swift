//
//  TranscriptLineReaderTests.swift
//  CalyxTests
//
//  Pins TranscriptLineReader, the incremental "\n"-framed reader used to
//  ingest Claude Code transcripts: positional reads from a byte offset,
//  only complete lines are consumed (an unterminated tail waits for the
//  next read), an over-long line is skipped and counted without poisoning
//  later lines, the byte budget stops on a line boundary, and
//  resumeOffset restarts from 0 when the inode changed or the file shrank.
//
//  Every file lives in a per-test temporary directory removed in tearDown.
//

import XCTest
@testable import Calyx

final class TranscriptLineReaderTests: XCTestCase {

    private var tempDirectory: URL!
    private var openDescriptors: [Int32] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptLineReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for descriptor in openDescriptors {
            close(descriptor)
        }
        openDescriptors = []
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes `contents` to a fresh file and returns (url, read-only fd).
    /// The descriptor is closed in tearDown.
    private func makeFile(_ contents: Data, name: String = "transcript.jsonl") throws -> (url: URL, fd: Int32) {
        let url = tempDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "Fixture error: open failed, errno \(errno)")
        openDescriptors.append(fd)
        return (url, fd)
    }

    private func makeFile(_ text: String) throws -> (url: URL, fd: Int32) {
        try makeFile(Data(text.utf8))
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Runs one read and returns the result plus the delivered lines as text.
    private func read(
        fd: Int32, from offset: UInt64 = 0, maxLineBytes: Int = 1_024, byteBudget: Int = 1_000_000
    ) throws -> (result: TranscriptReadResult, lines: [String]) {
        var lines: [String] = []
        let result = try TranscriptLineReader.read(
            fd: fd, from: offset, maxLineBytes: maxLineBytes, byteBudget: byteBudget
        ) { data in
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return (result, lines)
    }

    // MARK: - Complete lines

    func test_read_threeTerminatedLines_deliversEachWithoutNewline() throws {
        // "alpha\n" 6 + "beta\n" 5 + "gamma\n" 6 = 17 bytes.
        let file = try makeFile("alpha\nbeta\ngamma\n")

        let (result, lines) = try read(fd: file.fd)

        XCTAssertEqual(lines, ["alpha", "beta", "gamma"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 17, linesRead: 3, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_fromNonZeroOffset_startsAtThatByte() throws {
        let file = try makeFile("alpha\nbeta\ngamma\n")

        let (result, lines) = try read(fd: file.fd, from: 6)

        XCTAssertEqual(lines, ["beta", "gamma"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 17, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_fromOffsetInsideALine_deliversTheRestOfThatLine() throws {
        let file = try makeFile("alpha\nbeta\n")

        let (result, lines) = try read(fd: file.fd, from: 2)

        XCTAssertEqual(lines, ["pha", "beta"])
        XCTAssertEqual(result.nextOffset, 11)
        XCTAssertEqual(result.linesRead, 2)
    }

    func test_read_emptyLines_areConsumedButNotDelivered() throws {
        // "\n" 1 + "alpha\n" 6 + "\n\n" 2 + "beta\n" 5 + "\n" 1 = 15 bytes.
        let file = try makeFile("\nalpha\n\n\nbeta\n\n")

        let (result, lines) = try read(fd: file.fd)

        XCTAssertEqual(lines, ["alpha", "beta"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 15, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_fileOfOnlyNewlines_consumesAllAndDeliversNothing() throws {
        let file = try makeFile("\n\n\n")

        let (result, lines) = try read(fd: file.fd)

        XCTAssertEqual(lines, [])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 3, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    // MARK: - Unterminated tail

    func test_read_unterminatedTail_isNotConsumedUntilTheRestIsAppended() throws {
        // "alpha\n" 6 bytes, then the tail "bet" without a newline.
        let file = try makeFile("alpha\nbet")

        let (first, firstLines) = try read(fd: file.fd)

        XCTAssertEqual(firstLines, ["alpha"])
        XCTAssertEqual(first, TranscriptReadResult(
            nextOffset: 6, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: true))

        try append("a\ngamma\n", to: file.url)   // file is now "alpha\nbeta\ngamma\n"

        let (second, secondLines) = try read(fd: file.fd, from: first.nextOffset)

        XCTAssertEqual(secondLines, ["beta", "gamma"])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 17, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_noCompleteLine_nextOffsetEqualsStartOffset() throws {
        let file = try makeFile("alpha\npartial")

        let (result, lines) = try read(fd: file.fd, from: 6)

        XCTAssertEqual(lines, [])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 6, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_emptyFile_readsNothingAndReachesEnd() throws {
        let file = try makeFile("")

        let (result, lines) = try read(fd: file.fd)

        XCTAssertEqual(lines, [])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 0, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_fromOffsetAtEndOfFile_readsNothingAndKeepsOffset() throws {
        let file = try makeFile("alpha\nbeta\n")

        let (result, lines) = try read(fd: file.fd, from: 11)

        XCTAssertEqual(lines, [])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 11, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    // MARK: - Oversize lines

    func test_read_oversizeCompleteLine_isSkippedCountedAndLaterLinesStillDelivered() throws {
        // "ok1\n" 4 + 21 bytes of "x" + "\n" 22 + "ok2\n" 4 + "ok3\n" 4 = 34 bytes.
        let oversize = String(repeating: "x", count: 21)
        let file = try makeFile("ok1\n\(oversize)\nok2\nok3\n")

        let (result, lines) = try read(fd: file.fd, maxLineBytes: 20)

        XCTAssertEqual(lines, ["ok1", "ok2", "ok3"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 34, linesRead: 3, oversizeLinesSkipped: 1, reachedEnd: true))
    }

    func test_read_lineOfExactlyMaxLineBytes_isDelivered() throws {
        let exact = String(repeating: "y", count: 20)
        let file = try makeFile("\(exact)\nok\n")

        let (result, lines) = try read(fd: file.fd, maxLineBytes: 20)

        XCTAssertEqual(lines, [exact, "ok"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 24, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_twoOversizeLines_areEachCounted() throws {
        // 31 + 3 + 41 + 3 = 78 bytes.
        let first = String(repeating: "x", count: 30)
        let second = String(repeating: "z", count: 40)
        let file = try makeFile("\(first)\nok\n\(second)\nok\n")

        let (result, lines) = try read(fd: file.fd, maxLineBytes: 8)

        XCTAssertEqual(lines, ["ok", "ok"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 78, linesRead: 2, oversizeLinesSkipped: 2, reachedEnd: true))
    }

    func test_read_overLongUnterminatedTail_isNotConsumed() throws {
        // "ok\n" 3 bytes, then 50 bytes with no newline.
        let tail = String(repeating: "t", count: 50)
        let file = try makeFile("ok\n\(tail)")

        let (first, firstLines) = try read(fd: file.fd, maxLineBytes: 10)

        XCTAssertEqual(firstLines, ["ok"])
        XCTAssertEqual(first.nextOffset, 3, "The unterminated tail must stay unconsumed")
        XCTAssertEqual(first.linesRead, 1)
        XCTAssertTrue(first.reachedEnd)

        // Once the newline arrives the line is complete, hence consumed and counted.
        try append("\nafter\n", to: file.url)   // 3 + 50 + 1 + 6 = 60 bytes

        let (second, secondLines) = try read(fd: file.fd, from: first.nextOffset, maxLineBytes: 10)

        XCTAssertEqual(secondLines, ["after"])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 60, linesRead: 1, oversizeLinesSkipped: 1, reachedEnd: true))
    }

    // MARK: - Byte budget

    func test_read_byteBudget_stopsOnALineBoundaryAndTheNextReadRecoversTheRest() throws {
        // Five 5-byte lines: offsets 0, 5, 10, 15, 20; total 25 bytes.
        let file = try makeFile("aaaa\nbbbb\ncccc\ndddd\neeee\n")

        // After line 1: 5 < 7, continue. After line 2: 10 >= 7, stop.
        let (first, firstLines) = try read(fd: file.fd, byteBudget: 7)

        XCTAssertEqual(firstLines, ["aaaa", "bbbb"])
        XCTAssertEqual(first, TranscriptReadResult(
            nextOffset: 10, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: false))

        let (second, secondLines) = try read(fd: file.fd, from: first.nextOffset, byteBudget: 1_000_000)

        XCTAssertEqual(secondLines, ["cccc", "dddd", "eeee"])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 25, linesRead: 3, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_byteBudgetEqualToConsumedBytes_stopsThere() throws {
        let file = try makeFile("aaaa\nbbbb\ncccc\ndddd\neeee\n")

        // After line 2 the consumed bytes are exactly 10, and 10 >= 10.
        let (result, lines) = try read(fd: file.fd, byteBudget: 10)

        XCTAssertEqual(lines, ["aaaa", "bbbb"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 10, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: false))
    }

    func test_read_byteBudgetSmallerThanFirstLine_stillConsumesExactlyOneLine() throws {
        // 50 bytes + "\n" = 51, then "next\n" 5, "last\n" 5.
        let long = String(repeating: "L", count: 50)
        let file = try makeFile("\(long)\nnext\nlast\n")

        let (first, firstLines) = try read(fd: file.fd, byteBudget: 1)

        XCTAssertEqual(firstLines, [long])
        XCTAssertEqual(first, TranscriptReadResult(
            nextOffset: 51, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: false))

        let (second, secondLines) = try read(fd: file.fd, from: first.nextOffset, byteBudget: 1)

        XCTAssertEqual(secondLines, ["next"])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 56, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: false))
    }

    func test_read_byteBudgetCountsBytesOfThisCallOnly_notTheAbsoluteOffset() throws {
        let file = try makeFile("aaaa\nbbbb\ncccc\ndddd\neeee\n")

        // Starting at 10 with budget 7: after "cccc" 5 < 7, after "dddd" 10 >= 7.
        let (result, lines) = try read(fd: file.fd, from: 10, byteBudget: 7)

        XCTAssertEqual(lines, ["cccc", "dddd"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 20, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: false))
    }

    func test_read_budgetNeverReached_reachedEndIsTrue() throws {
        let file = try makeFile("aaaa\nbbbb\ntail")

        let (result, lines) = try read(fd: file.fd, byteBudget: 11)

        XCTAssertEqual(lines, ["aaaa", "bbbb"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 10, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    // MARK: - Chunk boundaries

    func test_read_lineOfSeveralHundredKilobytes_arrivesIntact() throws {
        // 300_000 patterned bytes (never "\n"), so a dropped, duplicated or
        // reordered chunk changes the content, not only the length.
        var big = Data(capacity: 300_000)
        for index in 0..<300_000 {
            big.append(UInt8(ascii: "A") + UInt8(index % 23))
        }
        var contents = Data("head\n".utf8)   // 5 bytes
        contents.append(big)                 // 300_000 bytes
        contents.append(Data("\ntail\n".utf8)) // 1 + 5 bytes
        let file = try makeFile(contents)

        var delivered: [Data] = []
        let result = try TranscriptLineReader.read(
            fd: file.fd, from: 0, maxLineBytes: 1_000_000, byteBudget: 10_000_000
        ) { delivered.append($0) }

        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered.first, Data("head".utf8))
        XCTAssertEqual(delivered.last, Data("tail".utf8))
        XCTAssertEqual(delivered.count == 3 ? Data(delivered[1]) : nil, big)
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 300_011, linesRead: 3, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_oversizeLineOfSeveralHundredKilobytes_isSkippedAndNextLineDelivered() throws {
        var contents = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        contents.append(Data("\nafter\n".utf8))   // 300_000 + 1 + 6 = 300_007
        let file = try makeFile(contents)

        let (result, lines) = try read(fd: file.fd, maxLineBytes: 1_024, byteBudget: 10_000_000)

        XCTAssertEqual(lines, ["after"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 300_007, linesRead: 1, oversizeLinesSkipped: 1, reachedEnd: true))
    }

    // MARK: - Descriptor handling

    func test_read_isPositional_ignoresAndPreservesTheDescriptorFilePosition() throws {
        let file = try makeFile("alpha\nbeta\ngamma\n")
        XCTAssertEqual(lseek(file.fd, 8, SEEK_SET), 8)

        let (result, lines) = try read(fd: file.fd, from: 0)

        XCTAssertEqual(lines, ["alpha", "beta", "gamma"], "The read must start at `offset`, not at the fd position")
        XCTAssertEqual(result.nextOffset, 17)
        XCTAssertEqual(lseek(file.fd, 0, SEEK_CUR), 8, "A positional read must not move the fd position")
    }

    func test_read_doesNotCloseTheDescriptor() throws {
        let file = try makeFile("alpha\nbeta\n")

        _ = try read(fd: file.fd)

        XCTAssertNotEqual(fcntl(file.fd, F_GETFD), -1, "The descriptor must still be open")
        let (again, lines) = try read(fd: file.fd)
        XCTAssertEqual(lines, ["alpha", "beta"])
        XCTAssertEqual(again.nextOffset, 11)
    }

    func test_read_invalidDescriptor_throws() {
        var delivered = 0

        XCTAssertThrowsError(
            try TranscriptLineReader.read(
                fd: -1, from: 0, maxLineBytes: 1_024, byteBudget: 1_000_000
            ) { _ in delivered += 1 }
        )
        XCTAssertEqual(delivered, 0)
    }

    // MARK: - resumeOffset

    func test_resumeOffset_nilCheckpoint_returnsZero() {
        XCTAssertEqual(TranscriptLineReader.resumeOffset(checkpoint: nil, inode: 42, size: 500), 0)
    }

    func test_resumeOffset_sameInodeAndSizeBeyondOffset_returnsCheckpointOffset() {
        let checkpoint = TranscriptCheckpoint(inode: 42, offset: 300)

        XCTAssertEqual(TranscriptLineReader.resumeOffset(checkpoint: checkpoint, inode: 42, size: 500), 300)
    }

    func test_resumeOffset_sameInodeAndSizeEqualToOffset_returnsCheckpointOffset() {
        let checkpoint = TranscriptCheckpoint(inode: 42, offset: 300)

        XCTAssertEqual(TranscriptLineReader.resumeOffset(checkpoint: checkpoint, inode: 42, size: 300), 300)
    }

    func test_resumeOffset_differentInode_returnsZero() {
        let checkpoint = TranscriptCheckpoint(inode: 42, offset: 300)

        XCTAssertEqual(TranscriptLineReader.resumeOffset(checkpoint: checkpoint, inode: 43, size: 500), 0)
    }

    func test_resumeOffset_sizeSmallerThanOffset_returnsZero() {
        let checkpoint = TranscriptCheckpoint(inode: 42, offset: 300)

        XCTAssertEqual(TranscriptLineReader.resumeOffset(checkpoint: checkpoint, inode: 42, size: 299), 0)
    }

    // MARK: - Pinned decisions

    func test_read_overLongUnterminatedTail_isCountedOnlyOnTheReadThatConsumesIt() throws {
        let tail = String(repeating: "t", count: 50)
        let file = try makeFile("ok\n\(tail)")   // 3 + 50 bytes

        let (first, firstLines) = try read(fd: file.fd, maxLineBytes: 10)

        XCTAssertEqual(firstLines, ["ok"])
        XCTAssertEqual(first, TranscriptReadResult(
            nextOffset: 3, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: true))

        let (again, againLines) = try read(fd: file.fd, from: first.nextOffset, maxLineBytes: 10)

        XCTAssertEqual(againLines, [])
        XCTAssertEqual(again, TranscriptReadResult(
            nextOffset: 3, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))

        try append("\n", to: file.url)   // 54 bytes

        let (second, secondLines) = try read(fd: file.fd, from: again.nextOffset, maxLineBytes: 10)

        XCTAssertEqual(secondLines, [])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 54, linesRead: 0, oversizeLinesSkipped: 1, reachedEnd: true))
    }

    func test_read_budgetMetExactlyOnLastCompleteLine_reachedEndIsFalseThenNextReadReachesEnd() throws {
        let file = try makeFile("aaaa\nbbbb\n")   // 10 bytes

        let (first, firstLines) = try read(fd: file.fd, byteBudget: 10)

        XCTAssertEqual(firstLines, ["aaaa", "bbbb"])
        XCTAssertEqual(first, TranscriptReadResult(
            nextOffset: 10, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: false))

        let (second, secondLines) = try read(fd: file.fd, from: first.nextOffset, byteBudget: 10)

        XCTAssertEqual(secondLines, [])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 10, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_crlfLineEndings_deliverTheTrailingCarriageReturnVerbatim() throws {
        let file = try makeFile("alpha\r\nbeta\r\n")   // 7 + 6 bytes

        let (result, lines) = try read(fd: file.fd)

        XCTAssertEqual(lines, ["alpha\r", "beta\r"])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 13, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    // MARK: - Review group B: 64 KiB chunk boundaries

    /// `count` patterned bytes that never contain "\n".
    private func patterned(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8(ascii: "A") + UInt8(index % 23))
        }
        return data
    }

    private func readData(
        fd: Int32, from offset: UInt64 = 0, maxLineBytes: Int, byteBudget: Int = 100_000_000
    ) throws -> (result: TranscriptReadResult, lines: [Data]) {
        var lines: [Data] = []
        let result = try TranscriptLineReader.read(
            fd: fd, from: offset, maxLineBytes: maxLineBytes, byteBudget: byteBudget
        ) { lines.append(Data($0)) }
        return (result, lines)
    }

    func test_read_newlineAsLastByteOfFirst64KiBChunk_deliversLineAndLaterLinesIntact() throws {
        // 65_535 bytes + "\n" fills bytes 0...65_535 exactly; "after\n" follows.
        let big = patterned(65_535)
        var contents = big
        contents.append(Data("\nafter\n".utf8))
        let file = try makeFile(contents)

        let (result, lines) = try readData(fd: file.fd, maxLineBytes: 1_000_000)

        XCTAssertEqual(lines, [big, Data("after".utf8)])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 65_542, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_newlineAsFirstByteOfSecond64KiBChunk_deliversLineAndLaterLinesIntact() throws {
        // 65_536 bytes fill the first chunk; "\n" is byte 65_536.
        let big = patterned(65_536)
        var contents = big
        contents.append(Data("\nafter\n".utf8))
        let file = try makeFile(contents)

        let (result, lines) = try readData(fd: file.fd, maxLineBytes: 1_000_000)

        XCTAssertEqual(lines, [big, Data("after".utf8)])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 65_543, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_chunkSpanningLineOfExactlyMaxLineBytes_isDelivered() throws {
        let big = patterned(70_000)
        var contents = big
        contents.append(Data("\nok\n".utf8))   // 70_000 + 1 + 3
        let file = try makeFile(contents)

        let (result, lines) = try readData(fd: file.fd, maxLineBytes: 70_000)

        XCTAssertEqual(lines, [big, Data("ok".utf8)])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 70_004, linesRead: 2, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_chunkSpanningLineOneByteOverMaxLineBytes_isSkippedAndCounted() throws {
        var contents = patterned(70_001)
        contents.append(Data("\nok\n".utf8))   // 70_001 + 1 + 3
        let file = try makeFile(contents)

        let (result, lines) = try readData(fd: file.fd, maxLineBytes: 70_000)

        XCTAssertEqual(lines, [Data("ok".utf8)])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 70_005, linesRead: 1, oversizeLinesSkipped: 1, reachedEnd: true))
    }

    // MARK: - Review group B: offsets and budgets

    func test_read_fromOffsetPastEndOfFile_keepsOffsetAndReachesEnd() throws {
        let file = try makeFile("alpha\nbeta\n")   // 11 bytes

        let (result, lines) = try read(fd: file.fd, from: 100)

        XCTAssertEqual(lines, [])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 100, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_fileWithNoNewlineAtAll_deliversNothingAndKeepsOffsetZero() throws {
        let file = try makeFile("no newline anywhere")

        let (result, lines) = try read(fd: file.fd)

        XCTAssertEqual(lines, [])
        XCTAssertEqual(result, TranscriptReadResult(
            nextOffset: 0, linesRead: 0, oversizeLinesSkipped: 0, reachedEnd: true))
    }

    func test_read_byteBudgetZero_consumesExactlyOneLinePerCall() throws {
        let file = try makeFile("aaaa\nbbbb\ncccc\n")

        let (first, firstLines) = try read(fd: file.fd, byteBudget: 0)
        let (second, secondLines) = try read(fd: file.fd, from: first.nextOffset, byteBudget: 0)

        XCTAssertEqual(firstLines, ["aaaa"])
        XCTAssertEqual(first, TranscriptReadResult(
            nextOffset: 5, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: false))
        XCTAssertEqual(secondLines, ["bbbb"])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 10, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: false))
    }

    func test_read_negativeByteBudget_consumesExactlyOneLinePerCall() throws {
        let file = try makeFile("aaaa\nbbbb\ncccc\n")

        let (first, firstLines) = try read(fd: file.fd, byteBudget: -1)
        let (second, secondLines) = try read(fd: file.fd, from: first.nextOffset, byteBudget: -1)

        XCTAssertEqual(firstLines, ["aaaa"])
        XCTAssertEqual(first, TranscriptReadResult(
            nextOffset: 5, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: false))
        XCTAssertEqual(secondLines, ["bbbb"])
        XCTAssertEqual(second, TranscriptReadResult(
            nextOffset: 10, linesRead: 1, oversizeLinesSkipped: 0, reachedEnd: false))
    }
}
