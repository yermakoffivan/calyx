//
//  ClaudeTranscriptLocatorTests.swift
//  CalyxTests
//
//  Pins ClaudeTranscriptLocator, the gate between an UNTRUSTED transcript
//  path (it arrives in a hook payload) and the usage ingestor:
//  locate(transcriptPath:sessionID:root:) accepts only an absolute path
//  whose realpath is "<realpath of root>/<project dir>/<sessionID>.jsonl"
//  and whose final component is itself an existing regular file, and
//  subagentTranscripts(in:) lists only the regular "agent-*.jsonl" files
//  directly inside "<project dir>/<sessionID>/subagents", by name.
//
//  "Resolved" means realpath(3) throughout (so "/var/..." is reported as
//  "/private/var/..."), which is what the expected values are built from.
//
//  Every file lives in a per-test temporary directory removed in
//  tearDown. All fixtures are synthetic; ~/.claude is never read.
//

import XCTest
@testable import Calyx

final class ClaudeTranscriptLocatorTests: XCTestCase {

    private let sessionID = "11111111-2222-3333-4444-555555555555"

    /// The temporary directory exactly as FileManager names it (on macOS a
    /// path through the "/var" symlink).
    private var tempPath: String!
    /// realpath(3) of `tempPath`.
    private var realTempPath: String!
    private var savedWorkingDirectory: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempPath = url.path
        realTempPath = try realPath(url.path)
        try makeDirectory(root)
        try makeDirectory(projectDirectory)
    }

    override func tearDownWithError() throws {
        if let savedWorkingDirectory {
            FileManager.default.changeCurrentDirectoryPath(savedWorkingDirectory)
        }
        savedWorkingDirectory = nil
        if let tempPath {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        tempPath = nil
        realTempPath = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private struct FixtureError: Error {}

    /// realpath(3), computed outside the code under test.
    private func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw FixtureError() }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The projects root as the caller would pass it (not resolved).
    private var root: String { tempPath + "/projects" }
    private var realRoot: String { realTempPath + "/projects" }
    private var projectDirectory: String { root + "/-Users-someone-repo" }
    private var realProjectDirectory: String { realRoot + "/-Users-someone-repo" }
    private var mainPath: String { projectDirectory + "/" + sessionID + ".jsonl" }
    private var realSubagentsDirectory: String { realProjectDirectory + "/" + sessionID + "/subagents" }

    private func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func makeFile(_ path: String, _ text: String = "{}\n") throws {
        try makeDirectory((path as NSString).deletingLastPathComponent)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func makeSymlink(at path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    private func locate(_ transcriptPath: String, sessionID: String? = nil, root: String? = nil)
        -> ClaudeTranscriptLocation? {
        ClaudeTranscriptLocator.locate(
            transcriptPath: transcriptPath, sessionID: sessionID ?? self.sessionID, root: root ?? self.root)
    }

    /// A location built by hand (resolved paths), for subagentTranscripts.
    private var location: ClaudeTranscriptLocation {
        ClaudeTranscriptLocation(
            mainPath: realProjectDirectory + "/" + sessionID + ".jsonl",
            sessionID: sessionID,
            subagentsDirectory: realSubagentsDirectory)
    }

    // MARK: - locate: accepted

    func test_locate_regularFileAtDepthTwo_returnsResolvedLocation() throws {
        try makeFile(mainPath)

        let found = locate(mainPath)

        XCTAssertEqual(found, ClaudeTranscriptLocation(
            mainPath: realProjectDirectory + "/" + sessionID + ".jsonl",
            sessionID: sessionID,
            subagentsDirectory: realProjectDirectory + "/" + sessionID + "/subagents"))
    }

    func test_locate_subagentsDirectoryDoesNotNeedToExist() throws {
        try makeFile(mainPath)

        let found = locate(mainPath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: realSubagentsDirectory), "Fixture error")
        XCTAssertEqual(found?.subagentsDirectory, realSubagentsDirectory)
    }

    func test_locate_rootGivenResolvedAndPathGivenUnresolved_returnsResolvedLocation() throws {
        try makeFile(mainPath)

        let found = locate(mainPath, root: realRoot)

        XCTAssertEqual(found?.mainPath, realProjectDirectory + "/" + sessionID + ".jsonl")
    }

    func test_locate_rootReachedThroughSymlink_returnsResolvedPaths() throws {
        try makeFile(mainPath)
        let linkedRoot = tempPath + "/linked-projects"
        try makeSymlink(at: linkedRoot, to: realRoot)

        let found = locate(
            linkedRoot + "/-Users-someone-repo/" + sessionID + ".jsonl", root: linkedRoot)

        XCTAssertEqual(found, ClaudeTranscriptLocation(
            mainPath: realProjectDirectory + "/" + sessionID + ".jsonl",
            sessionID: sessionID,
            subagentsDirectory: realProjectDirectory + "/" + sessionID + "/subagents"))
    }

    func test_locate_rootIsSymlinkButPathGivenThroughRealDirectory_isAccepted() throws {
        try makeFile(mainPath)
        let linkedRoot = tempPath + "/linked-projects"
        try makeSymlink(at: linkedRoot, to: realRoot)

        let found = locate(realProjectDirectory + "/" + sessionID + ".jsonl", root: linkedRoot)

        XCTAssertEqual(found?.mainPath, realProjectDirectory + "/" + sessionID + ".jsonl")
    }

    // MARK: - locate: rejected

    func test_locate_relativePath_returnsNil() throws {
        try makeFile(mainPath)
        // The relative path names the valid transcript from the current
        // directory, so only its being relative can reject it.
        savedWorkingDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root), "Fixture error")
        let relative = "-Users-someone-repo/" + sessionID + ".jsonl"
        XCTAssertTrue(FileManager.default.fileExists(atPath: relative), "Fixture error")

        XCTAssertNil(locate(relative))
        XCTAssertNil(locate("./" + relative))
    }

    func test_locate_tildePrefixedPath_returnsNil() throws {
        try makeFile(mainPath)

        XCTAssertNil(locate("~/.claude/projects/-Users-someone-repo/" + sessionID + ".jsonl"))
        XCTAssertNil(locate("~" + mainPath))
    }

    func test_locate_emptyPath_returnsNil() {
        XCTAssertNil(locate(""))
    }

    func test_locate_fileOutsideRoot_returnsNil() throws {
        let outside = tempPath + "/elsewhere/-Users-someone-repo/" + sessionID + ".jsonl"
        try makeFile(outside)

        XCTAssertNil(locate(outside))
    }

    func test_locate_siblingDirectorySharingTheRootPrefix_returnsNil() throws {
        // "<tmp>/projects-evil" starts with the string "<tmp>/projects".
        let outside = tempPath + "/projects-evil/-Users-someone-repo/" + sessionID + ".jsonl"
        try makeFile(outside)

        XCTAssertNil(locate(outside))
    }

    func test_locate_dotDotEscapingRoot_returnsNil() throws {
        let outside = tempPath + "/elsewhere/-Users-someone-repo/" + sessionID + ".jsonl"
        try makeFile(outside)
        let escaping = projectDirectory + "/../../elsewhere/-Users-someone-repo/" + sessionID + ".jsonl"
        XCTAssertTrue(FileManager.default.fileExists(atPath: escaping), "Fixture error")

        XCTAssertNil(locate(escaping))
    }

    func test_locate_symlinkedProjectDirectoryLeadingOutsideRoot_returnsNil() throws {
        let outsideDirectory = tempPath + "/elsewhere/-Users-someone-repo"
        try makeFile(outsideDirectory + "/" + sessionID + ".jsonl")
        try makeSymlink(at: root + "/linked-project", to: outsideDirectory)
        let throughLink = root + "/linked-project/" + sessionID + ".jsonl"
        XCTAssertTrue(FileManager.default.fileExists(atPath: throughLink), "Fixture error")

        XCTAssertNil(locate(throughLink))
    }

    func test_locate_fileDirectlyInRoot_depthOne_returnsNil() throws {
        let shallow = root + "/" + sessionID + ".jsonl"
        try makeFile(shallow)

        XCTAssertNil(locate(shallow))
    }

    func test_locate_fileAtDepthThree_returnsNil() throws {
        let deep = projectDirectory + "/nested/" + sessionID + ".jsonl"
        try makeFile(deep)

        XCTAssertNil(locate(deep))
    }

    func test_locate_subagentTranscriptPath_returnsNil() throws {
        // The measured subagent layout. The session id handed in matches
        // the file name, so only the depth can reject it.
        let subagent = projectDirectory + "/" + sessionID + "/subagents/agent-a1b2c3.jsonl"
        try makeFile(subagent)

        XCTAssertNil(locate(subagent, sessionID: "agent-a1b2c3"))
        XCTAssertNil(locate(subagent))
    }

    func test_locate_finalComponentIsSymlinkToAValidTranscript_returnsNil() throws {
        // The target is itself a regular file at depth two inside the root
        // with the right name, so only the link at the final component can
        // reject the path.
        let target = root + "/-Users-someone-other/" + sessionID + ".jsonl"
        try makeFile(target)
        try makeSymlink(at: mainPath, to: target)

        XCTAssertNil(locate(mainPath))
    }

    func test_locate_finalComponentIsSymlinkToFileOutsideRoot_returnsNil() throws {
        let target = tempPath + "/elsewhere/secret.jsonl"
        try makeFile(target)
        try makeSymlink(at: mainPath, to: target)

        XCTAssertNil(locate(mainPath))
    }

    func test_locate_finalComponentIsDirectory_returnsNil() throws {
        try makeDirectory(mainPath)

        XCTAssertNil(locate(mainPath))
    }

    func test_locate_nonexistentFile_returnsNil() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainPath), "Fixture error")

        XCTAssertNil(locate(mainPath))
    }

    func test_locate_nonexistentRoot_returnsNil() throws {
        try makeFile(mainPath)

        XCTAssertNil(locate(mainPath, root: tempPath + "/no-such-root"))
    }

    func test_locate_wrongExtension_returnsNil() throws {
        for name in [sessionID + ".json", sessionID + ".txt", sessionID + ".jsonl.bak", sessionID] {
            let path = projectDirectory + "/" + name
            try makeFile(path)

            XCTAssertNil(locate(path), "\(name) must be rejected")
        }
    }

    func test_locate_fileNameNotMatchingSessionID_returnsNil() throws {
        let other = projectDirectory + "/99999999-2222-3333-4444-555555555555.jsonl"
        try makeFile(other)
        try makeFile(mainPath)

        XCTAssertNil(locate(other), "The file exists but is not <sessionID>.jsonl")
        XCTAssertNil(locate(mainPath, sessionID: "99999999-2222-3333-4444-555555555555"))
    }

    func test_locate_sessionIDIsOnlyAPrefixOfTheFileName_returnsNil() throws {
        let path = projectDirectory + "/" + sessionID + "-extra.jsonl"
        try makeFile(path)

        XCTAssertNil(locate(path))
    }

    func test_locate_emptySessionID_returnsNil() throws {
        // A file literally named ".jsonl" exists, so only the empty id can
        // reject it.
        let path = projectDirectory + "/.jsonl"
        try makeFile(path)
        try makeFile(mainPath)

        XCTAssertNil(locate(path, sessionID: ""))
        XCTAssertNil(locate(mainPath, sessionID: ""))
    }

    // MARK: - subagentTranscripts

    func test_subagentTranscripts_returnsAgentJsonlFilesSortedByNameAsFullPaths() throws {
        // Created out of name order.
        try makeFile(realSubagentsDirectory + "/agent-c3.jsonl")
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        try makeFile(realSubagentsDirectory + "/agent-b2.jsonl")

        let paths = try ClaudeTranscriptLocator.subagentTranscripts(in: location)

        XCTAssertEqual(paths, [
            realSubagentsDirectory + "/agent-a1.jsonl",
            realSubagentsDirectory + "/agent-b2.jsonl",
            realSubagentsDirectory + "/agent-c3.jsonl",
        ])
    }

    func test_subagentTranscripts_ignoresMetaAndForkedSkillSidecars() throws {
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        try makeFile(realSubagentsDirectory + "/agent-a1.meta.json")
        try makeFile(realSubagentsDirectory + "/agent-a1.forked-skill.json")

        let paths = try ClaudeTranscriptLocator.subagentTranscripts(in: location)

        XCTAssertEqual(paths, [realSubagentsDirectory + "/agent-a1.jsonl"])
    }

    func test_subagentTranscripts_ignoresNamesNotMatchingAgentStarJsonl() throws {
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        try makeFile(realSubagentsDirectory + "/notes.jsonl")
        try makeFile(realSubagentsDirectory + "/subagent-a1.jsonl")
        try makeFile(realSubagentsDirectory + "/agent-a1.json")
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl.bak")
        try makeFile(realSubagentsDirectory + "/agent-a1.txt")
        try makeFile(realSubagentsDirectory + "/" + sessionID + ".jsonl")

        let paths = try ClaudeTranscriptLocator.subagentTranscripts(in: location)

        XCTAssertEqual(paths, [realSubagentsDirectory + "/agent-a1.jsonl"])
    }

    func test_subagentTranscripts_ignoresSymlinks() throws {
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        let target = realTempPath + "/elsewhere/agent-real.jsonl"
        try makeFile(target)
        try makeSymlink(at: realSubagentsDirectory + "/agent-b2.jsonl", to: target)
        // A link to a sibling that is itself listed is ignored as well.
        try makeSymlink(
            at: realSubagentsDirectory + "/agent-c3.jsonl", to: realSubagentsDirectory + "/agent-a1.jsonl")

        let paths = try ClaudeTranscriptLocator.subagentTranscripts(in: location)

        XCTAssertEqual(paths, [realSubagentsDirectory + "/agent-a1.jsonl"])
    }

    func test_subagentTranscripts_ignoresDirectories() throws {
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        try makeDirectory(realSubagentsDirectory + "/agent-b2.jsonl")

        let paths = try ClaudeTranscriptLocator.subagentTranscripts(in: location)

        XCTAssertEqual(paths, [realSubagentsDirectory + "/agent-a1.jsonl"])
    }

    func test_subagentTranscripts_doesNotDescendIntoSubdirectories() throws {
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        try makeFile(realSubagentsDirectory + "/nested/agent-z9.jsonl")

        let paths = try ClaudeTranscriptLocator.subagentTranscripts(in: location)

        XCTAssertEqual(paths, [realSubagentsDirectory + "/agent-a1.jsonl"])
    }

    func test_subagentTranscripts_missingDirectory_returnsEmpty() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: realSubagentsDirectory), "Fixture error")

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    func test_subagentTranscripts_emptyDirectory_returnsEmpty() throws {
        try makeDirectory(realSubagentsDirectory)

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    func test_subagentTranscripts_subagentsPathIsARegularFile_returnsEmpty() throws {
        try makeFile(realSubagentsDirectory)

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    func test_subagentTranscripts_ofALocatedTranscript_listsItsSubagentFiles() throws {
        try makeFile(mainPath)
        try makeFile(projectDirectory + "/" + sessionID + "/subagents/agent-a1.jsonl")
        let found = try XCTUnwrap(locate(mainPath))

        let paths = try ClaudeTranscriptLocator.subagentTranscripts(in: found)

        XCTAssertEqual(paths, [realSubagentsDirectory + "/agent-a1.jsonl"])
    }

    // MARK: - subagentTranscripts: never through a symlink

    func test_subagentTranscripts_subagentsDirectoryIsSymlinkToDirectoryOutsideRoot_returnsEmpty() throws {
        let outside = realTempPath + "/elsewhere/subagents"
        try makeFile(outside + "/agent-a1.jsonl")
        try makeDirectory(realProjectDirectory + "/" + sessionID)
        try makeSymlink(at: realSubagentsDirectory, to: outside)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: realSubagentsDirectory + "/agent-a1.jsonl"), "Fixture error")

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    func test_subagentTranscripts_subagentsDirectoryIsSymlinkToDirectoryInsideRoot_returnsEmpty() throws {
        let inside = realRoot + "/-Users-someone-other/some-session/subagents"
        try makeFile(inside + "/agent-a1.jsonl")
        try makeDirectory(realProjectDirectory + "/" + sessionID)
        try makeSymlink(at: realSubagentsDirectory, to: inside)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: realSubagentsDirectory + "/agent-a1.jsonl"), "Fixture error")

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    func test_subagentTranscripts_sessionDirectoryIsSymlinkToDirectoryOutsideRoot_returnsEmpty() throws {
        let outside = realTempPath + "/elsewhere/session"
        try makeFile(outside + "/subagents/agent-a1.jsonl")
        try makeSymlink(at: realProjectDirectory + "/" + sessionID, to: outside)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: realSubagentsDirectory + "/agent-a1.jsonl"), "Fixture error")

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    func test_subagentTranscripts_sessionDirectoryIsSymlinkToDirectoryInsideRoot_returnsEmpty() throws {
        let inside = realRoot + "/-Users-someone-other/some-session"
        try makeFile(inside + "/subagents/agent-a1.jsonl")
        try makeSymlink(at: realProjectDirectory + "/" + sessionID, to: inside)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: realSubagentsDirectory + "/agent-a1.jsonl"), "Fixture error")

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    // MARK: - subagentTranscripts: enumeration failures throw

    private func assertThrowsPOSIX(
        _ code: Int32, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> [String]
    ) {
        do {
            let paths = try body()
            XCTFail("Expected a POSIX error \(code), got \(paths)", file: file, line: line)
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain, file: file, line: line)
            XCTAssertEqual(nsError.code, Int(code), file: file, line: line)
        }
    }

    func test_subagentTranscripts_unreadableSubagentsDirectory_throwsEACCES() throws {
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        let directory = realSubagentsDirectory
        XCTAssertEqual(chmod(directory, 0o000), 0, "Fixture error")
        addTeardownBlock { _ = chmod(directory, 0o700) }

        assertThrowsPOSIX(EACCES) { try ClaudeTranscriptLocator.subagentTranscripts(in: location) }
    }

    func test_subagentTranscripts_unreadableSessionDirectory_throwsEACCES() throws {
        try makeFile(realSubagentsDirectory + "/agent-a1.jsonl")
        let directory = realProjectDirectory + "/" + sessionID
        XCTAssertEqual(chmod(directory, 0o000), 0, "Fixture error")
        addTeardownBlock { _ = chmod(directory, 0o700) }

        assertThrowsPOSIX(EACCES) { try ClaudeTranscriptLocator.subagentTranscripts(in: location) }
    }

    func test_subagentTranscripts_sessionPathIsARegularFile_returnsEmpty() throws {
        try makeFile(realProjectDirectory + "/" + sessionID)

        XCTAssertEqual(try ClaudeTranscriptLocator.subagentTranscripts(in: location), [])
    }

    // MARK: - locate: the session id is one path component

    func test_locate_sessionIDIsDot_returnsNil() throws {
        // "." + ".jsonl": the file exists, so only the id can reject it.
        let path = projectDirectory + "/..jsonl"
        try makeFile(path)

        XCTAssertNil(locate(path, sessionID: "."))
    }

    func test_locate_sessionIDIsDotDot_returnsNil() throws {
        // ".." + ".jsonl".
        let path = projectDirectory + "/...jsonl"
        try makeFile(path)

        XCTAssertNil(locate(path, sessionID: ".."))
    }

    func test_locate_sessionIDContainsSlash_returnsNil() throws {
        try makeFile(projectDirectory + "/nested/id.jsonl")
        try makeFile(root + "/-Users-someone-repo/id.jsonl")

        XCTAssertNil(locate(projectDirectory + "/nested/id.jsonl", sessionID: "nested/id"))
        XCTAssertNil(locate(root + "/-Users-someone-repo/id.jsonl", sessionID: "-Users-someone-repo/id"))
    }

    func test_locate_sessionIDContainsNUL_returnsNil() throws {
        // A C string stops at the NUL, so ".../plain\0x.jsonl" names the
        // regular file "plain" to every system call.
        try makeFile(projectDirectory + "/plain")
        let sessionID = "plain\u{0}x"

        XCTAssertNil(locate(projectDirectory + "/" + sessionID + ".jsonl", sessionID: sessionID))
    }

    func test_locate_transcriptPathContainsNUL_returnsNil() throws {
        try makeFile(mainPath)
        // To a system call the directory part ends at the NUL, i.e. it is
        // the valid project directory.
        let path = projectDirectory + "\u{0}/elsewhere/" + sessionID + ".jsonl"

        XCTAssertNil(locate(path))
        XCTAssertNil(locate(mainPath + "\u{0}"))
    }

    // MARK: - locate: no case aliasing

    func test_locate_fileNameDifferingOnlyInLetterCase_returnsNil() throws {
        try makeFile(projectDirectory + "/sid-lower.jsonl")

        XCTAssertNil(locate(projectDirectory + "/SID-LOWER.jsonl", sessionID: "SID-LOWER"))
    }

    func test_locate_exactCaseName_isAcceptedWithTheOnDiskSpelling() throws {
        try makeFile(projectDirectory + "/sid-lower.jsonl")

        let found = locate(projectDirectory + "/sid-lower.jsonl", sessionID: "sid-lower")

        XCTAssertEqual(found?.mainPath, realProjectDirectory + "/sid-lower.jsonl")
    }

    // MARK: - One canonical spelling: F_GETPATH

    private let dataVolumePrefix = "/System/Volumes/Data"

    /// The path the kernel reports for the opened item (`F_GETPATH`),
    /// computed outside the code under test.
    private func descriptorPath(_ path: String) throws -> String {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Skips unless "/System/Volumes/Data" + `path` names the same item
    /// as `path` (the data-volume firmlink layout).
    private func skipUnlessReachableThroughDataVolume(_ path: String) throws {
        var plain = stat()
        var prefixed = stat()
        guard stat(path, &plain) == 0, stat(dataVolumePrefix + path, &prefixed) == 0,
              plain.st_ino == prefixed.st_ino, plain.st_dev == prefixed.st_dev else {
            throw XCTSkip("\(dataVolumePrefix) does not alias \(path) on this volume layout")
        }
    }

    private func assertLocatedWithDescriptorSpelling(
        rootPrefix: String, pathPrefix: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let realMainPath = realProjectDirectory + "/" + sessionID + ".jsonl"
        try makeFile(realMainPath)
        try skipUnlessReachableThroughDataVolume(realMainPath)

        let found = locate(pathPrefix + realMainPath, root: rootPrefix + realRoot)

        XCTAssertEqual(found, ClaudeTranscriptLocation(
            mainPath: try descriptorPath(realMainPath),
            sessionID: sessionID,
            subagentsDirectory: try descriptorPath(realProjectDirectory) + "/" + sessionID + "/subagents"),
            file: file, line: line)
    }

    func test_locate_rootAndPathThroughDataVolumePrefix_spellsTheLocationAsTheDescriptorDoes() throws {
        try assertLocatedWithDescriptorSpelling(rootPrefix: dataVolumePrefix, pathPrefix: dataVolumePrefix)
    }

    func test_locate_onlyRootThroughDataVolumePrefix_spellsTheLocationAsTheDescriptorDoes() throws {
        try assertLocatedWithDescriptorSpelling(rootPrefix: dataVolumePrefix, pathPrefix: "")
    }

    func test_locate_onlyPathThroughDataVolumePrefix_spellsTheLocationAsTheDescriptorDoes() throws {
        try assertLocatedWithDescriptorSpelling(rootPrefix: "", pathPrefix: dataVolumePrefix)
    }
}
