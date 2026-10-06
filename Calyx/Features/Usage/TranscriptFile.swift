// TranscriptFile.swift
// Calyx
//
// Opens a transcript the locator validated, for reading, and re-checks at
// open time that the file opened is the one the path names. Shared by
// every transcript reader.

import Foundation

enum TranscriptFile {
    /// An open transcript. The caller owns `descriptor` and closes it.
    struct Opened: Sendable, Equatable {
        let descriptor: Int32
        let inode: UInt64
        let size: UInt64
    }

    enum Outcome: Sendable, Equatable {
        case opened(Opened)
        /// Nothing exists at the path (yet).
        case missing
        /// The item at the path is not a regular file: a symbolic link at
        /// the final component, a directory, a FIFO or a device.
        case notARegularFile
        /// The file opened IS regular, but the descriptor's real path is
        /// not `path`: a directory above it was replaced by a link, or the
        /// file was reached under another spelling. Nothing is read.
        case redirected
        /// Any other errno of the open or of examining the descriptor.
        case failed(errno: Int32)
    }

    /// Opens a transcript for reading, or says why it is not one. `path`
    /// is the path the locator produced, which it spelled with the same
    /// `fcntl(F_GETPATH)` used below; a path spelled any other way
    /// (`realpath(3)` included) can differ for the very same file.
    ///
    /// - O_NOFOLLOW rejects a symbolic link at the LAST component only
    ///   (ELOOP). A directory above it that was replaced by a link since
    ///   the path was validated is still followed by the open.
    /// - O_NONBLOCK: a FIFO put at the path would otherwise block the
    ///   open until a writer appears, i.e. possibly forever. It has no
    ///   effect on reading a regular file.
    /// - The type is taken from the DESCRIPTOR (`fstat`); a directory or
    ///   FIFO opens fine and is rejected here.
    /// - The descriptor's real path (`fcntl(F_GETPATH)`) must equal `path`
    ///   byte for byte. This is the check that covers the directories
    ///   above the file: an open redirected through a link anywhere in
    ///   the path, or reaching the file under another spelling, reports a
    ///   different real path and is `.redirected`. Together with
    ///   `fstat` it makes the file that is read a regular file whose real
    ///   path, at open time, was the validated one.
    ///
    /// The caller owns (and closes) the returned descriptor. The size is
    /// clamped into UInt64 rather than converted with a trap: the kernel
    /// never reports a negative size for a regular file.
    static func open(atPath path: String) -> Outcome {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let openErrno = errno
            switch openErrno {
            case ENOENT: return .missing
            case ELOOP: return .notARegularFile
            default: return .failed(errno: openErrno)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let statErrno = errno
            close(descriptor)
            return .failed(errno: statErrno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return .notARegularFile
        }
        var realPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &realPath) == 0 else {
            let pathErrno = errno
            close(descriptor)
            return .failed(errno: pathErrno)
        }
        guard strcmp(realPath, path) == 0 else {
            close(descriptor)
            return .redirected
        }
        return .opened(Opened(descriptor: descriptor, inode: UInt64(status.st_ino), size: UInt64(clamping: status.st_size)))
    }
}
