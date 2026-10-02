//
//  GitProjectRootResolverTests.swift
//  CalyxTests
//
//  Pins GitProjectRootResolver, the production ProjectRootResolving: the
//  repository's work tree root for a cwd inside a repository (asked from
//  the root and from a subdirectory), nil for a directory that is not in
//  a repository, and a thrown error for every other git failure (here: a
//  directory that does not exist). Repositories are throwaway ones built
//  with the real git binary and removed in tearDown.
//

import XCTest
@testable import Calyx

final class GitProjectRootResolverTests: XCTestCase {

    private struct FixtureError: Error {}

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try GitScratch.makeDirectory("usage-project-root")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        try super.tearDownWithError()
    }

    /// realpath(3), computed outside the code under test.
    private func realPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw FixtureError() }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func makeRepository(_ name: String) throws -> URL {
        let repository = scratch.appendingPathComponent(name, isDirectory: true)
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        return repository
    }

    func test_resolver_isAProjectRootResolving() {
        let resolver: any ProjectRootResolving = GitProjectRootResolver()
        XCTAssertTrue(resolver is GitProjectRootResolver)
    }

    func test_projectRoot_directoryThatIsNotARepository_returnsNil() async throws {
        let plain = scratch.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        // Fixture check with git itself: the scratch area must not sit
        // inside some enclosing repository, or nil could never be right.
        XCTAssertThrowsError(try GitScratch.run(["rev-parse", "--show-toplevel"], in: plain),
                             "Fixture error: \(plain.path) is inside a git repository")

        let root = try await GitProjectRootResolver().projectRoot(forCWD: plain.path)

        XCTAssertNil(root)
    }

    func test_projectRoot_askedFromTheRepositoryRoot_returnsThatRoot() async throws {
        let repository = try makeRepository("repo")

        let root = try await GitProjectRootResolver().projectRoot(forCWD: repository.path)

        XCTAssertEqual(root, try realPath(repository))
    }

    func test_projectRoot_askedFromASubdirectory_returnsTheRepositoryRoot() async throws {
        let repository = try makeRepository("repo")
        let nested = repository.appendingPathComponent("Sources/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let root = try await GitProjectRootResolver().projectRoot(forCWD: nested.path)

        XCTAssertEqual(root, try realPath(repository))
    }

    func test_projectRoot_askedThroughASymlinkedSpelling_returnsTheOnDiskRoot() async throws {
        // The reason the ingestor validates the answer: git resolves
        // links, so the root can differ from the cwd it was asked about.
        let repository = try makeRepository("repo")
        let link = scratch.appendingPathComponent("link-to-repo")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: repository.path)

        let root = try await GitProjectRootResolver().projectRoot(forCWD: link.path)

        XCTAssertEqual(root, try realPath(repository))
    }

    func test_projectRoot_directoryThatDoesNotExist_throws() async throws {
        let missing = scratch.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "Fixture error")

        do {
            let root = try await GitProjectRootResolver().projectRoot(forCWD: missing.path)
            XCTFail("Expected a thrown error, got \(String(describing: root))")
        } catch let error as GitService.GitError {
            if case .notARepository = error {
                XCTFail("notARepository must become nil, never be thrown")
            }
        } catch {
            // Any other error (e.g. the process could not be launched in
            // a missing directory) is the specified outcome.
        }
    }
}
