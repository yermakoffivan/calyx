// UsageWindowRefreshScheduler.swift
// Calyx
//
// Decides when the Usage window reads its table again on its own: once
// when it is shown, and while it is visible after every change the
// reception feed reports, coalesced into a fixed window of `interval`
// (a change while a refresh is pending joins it; the window's end always
// refreshes, so the last change is never lost). While the window is
// hidden (closed) nothing is scheduled and a pending refresh does not
// run. The refresh on show starts no window, so a change right after
// showing refreshes again after `interval` (intended). The one-shot timer is injected, so the rules are tested without
// waiting on real time.

import Foundation

@MainActor
final class UsageWindowRefreshScheduler {

    static let defaultInterval: TimeInterval = 2

    private let interval: TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let refresh: @MainActor () -> Void

    private var isVisible = false
    private var isPending = false
    /// Incremented by every hide, so a timer scheduled before it does
    /// nothing when it fires.
    private var generation = 0

    /// - Parameters:
    ///   - schedule: runs its action once after the delay, on the main actor.
    ///   - refresh: reads the table again.
    init(
        interval: TimeInterval = UsageWindowRefreshScheduler.defaultInterval,
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void,
        refresh: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.schedule = schedule
        self.refresh = refresh
    }

    /// The window was shown: refreshes once at once.
    func windowDidShow() {
        isVisible = true
        refresh()
    }

    /// The window was closed: nothing is scheduled until it is shown
    /// again, and a pending refresh is dropped.
    func windowDidHide() {
        isVisible = false
        isPending = false
        generation += 1
    }

    /// The feed reported a change.
    func feedDidChange() {
        guard isVisible, !isPending else { return }
        isPending = true
        let scheduledGeneration = generation
        schedule(interval) { [weak self] in
            guard let self, scheduledGeneration == self.generation else { return }
            self.isPending = false
            self.refresh()
        }
    }
}
