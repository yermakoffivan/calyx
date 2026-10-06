// UsageWindowController.swift
// Calyx
//
// Independent window (same shape as `SessionBrowserWindowController`)
// that shows the usage ledger as a table grouped by the window's Columns.
// No dedicated test file: the logic worth testing lives in
// `UsageWindowModel` and `UsageWindowRefreshScheduler`, not this AppKit
// shell. A plain `NSWindow`, so Cmd+W
// (`calyxPerformClose(_:)`) closes it like Settings and the Session
// Browser.

import AppKit
import SwiftUI

@MainActor
final class UsageWindowController: NSWindowController {

    static let shared = UsageWindowController()

    let model: UsageWindowModel
    /// Held only to keep the feed (and its observers) alive; set once in
    /// `init`, after `self` exists for its `onChange`.
    private var statusFeed: UsageTelemetryStatusFeed?
    /// Reads the table on show and, debounced, on feed changes while the
    /// window is open; set once in `init`, after `self` exists.
    private var refreshScheduler: UsageWindowRefreshScheduler?
    /// Never removed: the controller lives as long as the app.
    private var willCloseObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: UsageWindowView.initialSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Usage"
        window.center()
        window.isReleasedWhenClosed = false

        // The app's ledger, read fresh at every refresh: the tracking
        // flag, the clock and the calendar are closures, not values
        // captured when the window was first opened.
        self.model = UsageWindowModel(
            isEnabled: { UsageLedger.shared.isTracking },
            reports: { try await UsageLedger.shared.tokenReports($0, calendar: $1) },
            deleteAll: { try await UsageLedger.shared.deleteAll() },
            statusText: { UsageTelemetryStatusFeed.text(inputs: .production) },
            now: Date.init,
            calendar: { Calendar.current }
        )

        super.init(window: window)

        window.contentView = NSHostingView(rootView: UsageWindowView(model: model))

        refreshScheduler = UsageWindowRefreshScheduler(
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
            },
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.model.refresh() }
            })

        // Keeps the status line current while the window exists (this
        // controller, and so its window, lives as long as the app), and
        // the table too while the window is open.
        statusFeed = UsageTelemetryStatusFeed(inputs: .production) { [weak self] in
            self?.model.refreshStatus()
            self?.refreshScheduler?.feedDidChange()
        }

        // Closing (not miniaturizing) hides the window for the scheduler.
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshScheduler?.windowDidHide()
            }
        }
    }

    /// Never built from a nib; answers nil instead of trapping.
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows the window, makes it key and reads the ledger again.
    func showUsage() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refreshScheduler?.windowDidShow()
    }
}
