// UsageWindowController.swift
// Calyx
//
// Independent window (same shape as `SessionBrowserWindowController`)
// that shows the usage ledger as a model x effort table. No dedicated
// test file: the logic worth testing lives in `UsageWindowModel`, not
// this AppKit shell. A plain `NSWindow`, so Cmd+W
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

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 480),
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

        // Keeps the status line current while the window exists (this
        // controller, and so its window, lives as long as the app).
        statusFeed = UsageTelemetryStatusFeed(inputs: .production) { [weak self] in
            self?.model.refreshStatus()
        }
    }

    /// Never built from a nib; answers nil instead of trapping.
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows the window, makes it key and reads the ledger again.
    func showUsage() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }
}
