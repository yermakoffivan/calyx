// TranscriptLineReader.swift
// Calyx
//
// Incremental "\n"-framed reader for Claude Code transcripts: reads from a
// byte offset in fixed-size chunks, consumes only complete lines so a
// half-written tail waits for the next read, and skips an over-long line
// without failing the lines after it. NDJSONFramer is not reused: it fails
// permanently once it meets an over-long line and reports no per-line end
// position to checkpoint.

import Foundation

/// Where a previous read of one transcript file stopped. The inode is
/// kept so a replaced file is not resumed at an offset of the old one.
struct TranscriptCheckpoint: Sendable, Equatable {
    let inode: UInt64
    let offset: UInt64
}

struct TranscriptReadResult: Sendable, Equatable {
    /// Just past the last consumed "\n"; the offset to checkpoint.
    let nextOffset: UInt64
    /// Lines delivered to `onLine`.
    let linesRead: Int
    /// Complete lines longer than `maxLineBytes`: consumed, not delivered.
    let oversizeLinesSkipped: Int
    /// `false` only when the byte budget stopped the read; the caller
    /// should then read again from `nextOffset`.
    let reachedEnd: Bool
}

enum TranscriptLineReader {
    /// Bytes requested per `pread`. Independent of `maxLineBytes`: a line
    /// spanning chunks is reassembled through the carry buffer.
    private static let chunkSize = 64 * 1_024

    /// Delivers each complete, non-empty line starting at `offset` to
    /// `onLine`, verbatim and without its "\n" (a trailing "\r" stays).
    ///
    /// - Reads are positional (`pread`): the descriptor's own file
    ///   position is neither used nor moved, and `fd` is never closed.
    /// - Nothing past the last "\n" is consumed, because Claude Code may
    ///   still be writing that line; it is read again once terminated.
    /// - A complete line longer than `maxLineBytes` is consumed and
    ///   counted, not delivered. Its bytes are not kept while the newline
    ///   is searched for, so memory stays bounded by `maxLineBytes` plus
    ///   one chunk whatever the line's length. An over-long tail with no
    ///   newline yet is neither consumed nor counted.
    /// - The budget is checked after each finished line, without looking
    ///   ahead, so a call always makes progress when a complete line
    ///   exists and `reachedEnd` is `false` whenever the budget stopped
    ///   the read, even if that line happened to be the file's last.
    ///
    /// Throws an `NSPOSIXErrorDomain` error for any read failure other
    /// than EINTR, which is retried.
    static func read(
        fd: Int32, from offset: UInt64, maxLineBytes: Int, byteBudget: Int,
        onLine: (Data) -> Void
    ) throws -> TranscriptReadResult {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var readOffset = offset
        /// Bytes consumed by this call: everything through the last "\n".
        var consumed = 0
        /// Bytes of the current unterminated line held so far; empty once
        /// that line is known to be over-long.
        var carry = Data()
        /// Length of the current unterminated line, including bytes that
        /// were dropped from `carry`.
        var pendingLength = 0
        var linesRead = 0
        var oversizeLinesSkipped = 0

        func result(reachedEnd: Bool) -> TranscriptReadResult {
            TranscriptReadResult(
                nextOffset: offset + UInt64(consumed), linesRead: linesRead,
                oversizeLinesSkipped: oversizeLinesSkipped, reachedEnd: reachedEnd)
        }

        while true {
            let count = try readChunk(fd: fd, into: &buffer, at: readOffset)
            guard count > 0 else { return result(reachedEnd: true) }
            readOffset += UInt64(count)

            var segmentStart = 0
            while let newline = buffer[segmentStart..<count].firstIndex(of: UInt8(ascii: "\n")) {
                let lineLength = pendingLength + (newline - segmentStart)
                if lineLength > maxLineBytes {
                    oversizeLinesSkipped += 1
                } else if lineLength > 0 {
                    carry.append(contentsOf: buffer[segmentStart..<newline])
                    onLine(carry)
                    linesRead += 1
                }
                consumed += lineLength + 1
                // A fresh buffer, not removeAll: `onLine` may have kept
                // the delivered Data.
                carry = Data()
                pendingLength = 0
                segmentStart = newline + 1
                if consumed >= byteBudget { return result(reachedEnd: false) }
            }

            pendingLength += count - segmentStart
            if pendingLength > maxLineBytes {
                carry = Data()
            } else {
                carry.append(contentsOf: buffer[segmentStart..<count])
            }
        }
    }

    /// The offset to resume a file from: the checkpoint's offset when it
    /// still describes this file, otherwise 0. A different inode means the
    /// path now names another file, and a size below the offset means the
    /// file was truncated or rewritten; in both cases the old offset would
    /// point into unrelated bytes, so the file is read again from the
    /// start (records are keyed, so re-reading is idempotent).
    static func resumeOffset(checkpoint: TranscriptCheckpoint?, inode: UInt64, size: UInt64) -> UInt64 {
        guard let checkpoint, checkpoint.inode == inode, size >= checkpoint.offset else { return 0 }
        return checkpoint.offset
    }

    /// One `pread` of up to `buffer.count` bytes; 0 means end of file.
    private static func readChunk(fd: Int32, into buffer: inout [UInt8], at offset: UInt64) throws -> Int {
        guard let position = off_t(exactly: offset) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW))
        }
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, position) }
            if count >= 0 { return count }
            let readErrno = errno
            if readErrno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(readErrno))
        }
    }
}
