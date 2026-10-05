// UsageIngestMonitor.swift
// Calyx
//
// What the app knows about the usage route at run time: the credential the
// route accepts right now, and what the last requests were answered with.

import Foundation
import Observation

// MARK: - UsageIngestMonitor

/// What the Settings pane and the Usage window show about reception.
@MainActor @Observable
final class UsageIngestMonitor {
    struct Rejection: Equatable {
        let reason: UsageIngestRejection
        let at: Date
    }

    static let shared = UsageIngestMonitor()

    /// When the route last accepted an export (stored or dropped).
    private(set) var lastAcceptedAt: Date?
    /// The last refusal an exporter can cause.
    private(set) var lastRejection: Rejection?

    init() {}

    /// Records one verdict of the route: nil for an accepted request.
    /// Only refusals an exporter can cause are kept (`unauthorized`,
    /// `tooLarge`, `undecodable`, `unavailable`); a request with an
    /// `Origin` header or without a body is not from Claude Code and
    /// changes nothing here.
    func note(_ rejection: UsageIngestRejection?, at date: Date) {
        guard let rejection else {
            lastAcceptedAt = date
            return
        }
        switch rejection {
        case .unauthorized, .tooLarge, .undecodable, .unavailable:
            lastRejection = Rejection(reason: rejection, at: date)
        case .foreignOrigin, .noBody:
            break
        }
    }
}

// MARK: - UsageIngestCredentialHolder

/// The credential the route accepts right now.
@MainActor
final class UsageIngestCredentialHolder {
    static let shared = UsageIngestCredentialHolder()

    private(set) var credential: UsageIngestCredential?

    init() {}

    func set(_ credential: UsageIngestCredential?) {
        self.credential = credential
    }

    /// Loads the credential file of `directory` and holds what it found.
    ///
    /// - `create: true` reads the file, or writes a new token when it is
    ///   missing or unusable (`UsageIngestCredentialStore.loadOrCreate`).
    /// - `create: false` creates nothing: no usable file holds nil.
    ///
    /// The file work runs off the main actor (`loadOrCreate` may wait for
    /// a file lock). A load that throws leaves the held credential as it
    /// was and the error reaches the caller.
    @discardableResult
    func load(create: Bool, directory: String) async throws -> UsageIngestCredential? {
        let loaded = try await Self.readCredential(create: create, directory: directory)
        credential = loaded
        return loaded
    }

    @concurrent
    private nonisolated static func readCredential(
        create: Bool, directory: String
    ) async throws -> UsageIngestCredential? {
        guard create else { return UsageIngestCredentialStore.read(directory: directory) }
        return try UsageIngestCredentialStore.loadOrCreate(
            directory: directory, makeToken: { try SecureRandomTokenGenerator().makeToken() })
    }
}
