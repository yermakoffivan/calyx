// ClaudeTranscriptLocator.swift
// Calyx
//
// The gate between an UNTRUSTED transcript path (it arrives in an agent
// hook payload) and the usage ingestor. A path is accepted only when it
// names "<projects root>/<project dir>/<sessionID>.jsonl" and that file is
// itself a regular file; the session's subagent transcripts are then
// listed by name, never through a symbolic link at the session or
// subagents directory. These checks describe the file system when they
// run; the ingestor re-checks each file it opens. Nothing here reads file
// contents, and the projects root is passed in (AgentToolPaths decides
// it).

import Foundation

/// A validated session transcript. Every path is spelled the way the
/// kernel reports an open descriptor's path (`fcntl(F_GETPATH)`), which is
/// the spelling the ingestor's open-time check compares against.
struct ClaudeTranscriptLocation: Sendable, Equatable {
    /// "<canonical project dir>/<sessionID>.jsonl".
    let mainPath: String
    let sessionID: String
    /// "<canonical project dir>/<sessionID>/subagents"; need not exist.
    let subagentsDirectory: String
}

enum ClaudeTranscriptLocator {
    /// Validates `transcriptPath` against the projects `root`; nil for any
    /// path that is not exactly the session's main transcript.
    ///
    /// - `sessionID` must be ONE path component: not empty, not "." or
    ///   "..", with no "/" and no NUL. It is used to build the subagents
    ///   path, so anything else would let the payload aim that path at
    ///   another directory. A NUL in either input is rejected because a
    ///   system call would stop reading the path there and examine some
    ///   other item than the string names.
    /// - The path must be absolute: a hook payload has no working
    ///   directory worth trusting, and "~" is never expanded.
    /// - The final component must be "<sessionID>.jsonl" and a regular
    ///   file by `lstat`, so a symbolic link there is rejected even when
    ///   it points at a valid transcript: following it would let the
    ///   payload choose which file is read.
    /// - The directory holding it and the root are both canonicalised by
    ///   OPENING them and asking the descriptor for its path
    ///   (`fcntl(F_GETPATH)`), which follows links and reports the
    ///   on-disk spelling. The canonical directory must be a DIRECT child
    ///   of the canonical root, compared component by component: a string
    ///   prefix would accept a sibling such as "projects-evil", and "..",
    ///   a linked project directory or a subagent transcript all
    ///   canonicalise to some other depth or some other parent.
    /// - One canonicaliser on both sides. The ingestor accepts an opened
    ///   file only when F_GETPATH of its descriptor equals `mainPath`, so
    ///   `mainPath` must be produced by F_GETPATH too. `realpath(3)` can
    ///   spell the same file differently (it keeps a
    ///   "/System/Volumes/Data" prefix that F_GETPATH drops), which would
    ///   make a located transcript be refused as redirected on every
    ///   ingest, or make the root and the project directory fail to match
    ///   when only one was given through that prefix.
    /// - The transcript is opened relative to the project directory's
    ///   descriptor with O_NOFOLLOW (and O_NONBLOCK, so a FIFO cannot
    ///   block), must be a regular file by `fstat`, and its descriptor's
    ///   path must equal "<canonical project dir>/<sessionID>.jsonl" byte
    ///   for byte. That is the no-aliasing rule: on a case-insensitive
    ///   volume "<SESSIONID>.jsonl" names the same file, and accepting it
    ///   would store one transcript under two session ids and two
    ///   checkpoint paths. `mainPath` is the descriptor's path, i.e. the
    ///   on-disk spelling. Nothing is read from the file.
    ///
    /// This describes the file system at the moment of the call. It does
    /// not bind a later open: the ingestor re-checks the file it actually
    /// opened (see `UsageIngestor`).
    static func locate(transcriptPath: String, sessionID: String, root: String) -> ClaudeTranscriptLocation? {
        guard !sessionID.isEmpty, sessionID != ".", sessionID != "..",
              !sessionID.utf8.contains(where: { $0 == UInt8(ascii: "/") || $0 == 0 }),
              !transcriptPath.utf8.contains(0) else { return nil }
        guard transcriptPath.hasPrefix("/"),
              let lastSlash = transcriptPath.lastIndex(of: "/") else { return nil }
        let expectedName = sessionID + ".jsonl"
        let fileName = String(transcriptPath[transcriptPath.index(after: lastSlash)...])
        guard fileName.utf8.elementsEqual(expectedName.utf8) else { return nil }
        // The path is absolute, so the text before the last "/" is empty
        // only for a file directly in "/".
        let parent = lastSlash == transcriptPath.startIndex ? "/" : String(transcriptPath[..<lastSlash])

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        let rootDescriptor = open(root, directoryFlags)
        guard rootDescriptor >= 0 else { return nil }
        let canonicalRoot = descriptorPath(rootDescriptor)
        close(rootDescriptor)

        // Kept open so the transcript is examined inside the very
        // directory that was canonicalised.
        let projectDescriptor = open(parent, directoryFlags)
        guard projectDescriptor >= 0 else { return nil }
        defer { close(projectDescriptor) }
        guard let canonicalRoot, let projectDirectory = descriptorPath(projectDescriptor) else { return nil }

        let rootComponents = components(of: canonicalRoot)
        let projectComponents = components(of: projectDirectory)
        guard projectComponents.count == rootComponents.count + 1,
              projectComponents.starts(with: rootComponents) else { return nil }

        let fileDescriptor = openat(projectDescriptor, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fileDescriptor >= 0 else { return nil }
        defer { close(fileDescriptor) }
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              let mainPath = descriptorPath(fileDescriptor) else { return nil }
        let expectedPath = projectDirectory + "/" + expectedName
        guard mainPath.utf8.elementsEqual(expectedPath.utf8) else { return nil }
        return ClaudeTranscriptLocation(
            mainPath: mainPath,
            sessionID: sessionID,
            subagentsDirectory: projectDirectory + "/" + sessionID + "/subagents")
    }

    /// The session's subagent transcripts: the regular files named
    /// "agent-*.jsonl" directly inside `location.subagentsDirectory`, as
    /// "<subagentsDirectory>/<name>" paths sorted by name. Sidecars
    /// ("*.meta.json", "*.forked-skill.json"), other names, links and
    /// directories are ignored, and subdirectories are not entered.
    ///
    /// What is guaranteed here: the LAST TWO components,
    /// "<sessionID>" and "subagents", are real directories. Each is opened
    /// with O_NOFOLLOW (the second relative to the first's descriptor), so
    /// a symbolic link at either of those two levels yields an empty list,
    /// and the entries are examined relative to the opened directory
    /// (`fstatat`, not following links). What is NOT guaranteed: O_NOFOLLOW
    /// covers only the final component of the path it is given, so a
    /// project directory (or any ancestor) replaced by a link after
    /// `locate` is followed, and the returned paths would then name files
    /// outside the projects root. That case is rejected where each file is
    /// opened: the ingestor compares the opened descriptor's real path
    /// with the path returned here.
    ///
    /// A missing session or subagents directory, a non-directory or a link
    /// there (ENOENT, ENOTDIR, ELOOP) is "no subagents" and yields an
    /// empty list. Every other failure to open or read the directories is
    /// thrown as an `NSPOSIXErrorDomain` error: an unreadable directory is
    /// not an empty one, and reporting it as empty would silently lose
    /// that usage.
    static func subagentTranscripts(in location: ClaudeTranscriptLocation) throws -> [String] {
        let subagentsDirectory = location.subagentsDirectory
        guard let lastSlash = subagentsDirectory.lastIndex(of: "/") else { return [] }
        let sessionDirectory = String(subagentsDirectory[..<lastSlash])
        let directoryName = String(subagentsDirectory[subagentsDirectory.index(after: lastSlash)...])
        guard !sessionDirectory.isEmpty, !directoryName.isEmpty else { return [] }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let sessionDescriptor = open(sessionDirectory, directoryFlags)
        guard sessionDescriptor >= 0 else {
            return try emptyIfAbsent(errno)
        }
        defer { close(sessionDescriptor) }
        let descriptor = openat(sessionDescriptor, directoryName, directoryFlags)
        guard descriptor >= 0 else {
            return try emptyIfAbsent(errno)
        }
        guard let directory = fdopendir(descriptor) else {
            let openErrno = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(openErrno))
        }
        // closedir also closes `descriptor`.
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            // readdir returns nil both at the end and on failure; only
            // errno tells them apart, and only if it was cleared first.
            errno = 0
            guard let entry = readdir(directory) else {
                let readErrno = errno
                guard readErrno == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(readErrno)) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                let statErrno = errno
                // Removed between readdir and here: simply not listed.
                if statErrno == ENOENT { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(statErrno))
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else { continue }
            names.append(name)
        }
        return names.sorted().map { subagentsDirectory + "/" + $0 }
    }

    /// The outcome of a failed directory open: an empty list when the
    /// directory is simply not there as a real directory, else the error.
    private static func emptyIfAbsent(_ openErrno: Int32) throws -> [String] {
        switch openErrno {
        case ENOENT, ENOTDIR, ELOOP: return []
        default: throw NSError(domain: NSPOSIXErrorDomain, code: Int(openErrno))
        }
    }

    /// The path the kernel reports for an open descriptor
    /// (`fcntl(F_GETPATH)`); nil when it cannot be obtained. The one
    /// canonical spelling used by the locator and the ingestor alike.
    private static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func components(of path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }
}
