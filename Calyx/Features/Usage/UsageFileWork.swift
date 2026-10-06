// UsageFileWork.swift
// Calyx
//
// Where the usage feature's blocking file work runs: Claude Code's
// settings install / remove (`ConfigFileUtils.withExclusiveConfig`, whose
// lock wait sleeps for up to 10 s) and the usage credential's read /
// load-or-create (which waits on a lock the same way). A thread of the
// Swift concurrency pool must never sleep, so this work runs on one
// dedicated serial queue and the caller suspends until it is done.

import Foundation

enum UsageFileWork {
    private static let queue = DispatchQueue(label: "com.calyx.usage.fileWork", qos: .utility)

    /// Runs `body` on the usage file queue and returns its result.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// Runs `body` on the usage file queue and returns its result or rethrows its error.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
