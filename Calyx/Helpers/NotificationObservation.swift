// NotificationObservation.swift
// Calyx
//
// A block observer of NotificationCenter that is removed when its owner
// lets go of it.

import Foundation

/// Observes `name` on `center` for as long as this object lives; each
/// notification starts one main-actor task that runs `handler`.
final class NotificationObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    @MainActor
    init(
        name: Notification.Name, center: NotificationCenter = .default,
        handler: @escaping @MainActor () async -> Void
    ) {
        self.center = center
        self.token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in await handler() }
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
