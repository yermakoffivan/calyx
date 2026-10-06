// UsageTelemetryStatusFeed.swift
// Calyx
//
// The one source of the reception status line (R5c, section C), shared
// by the Settings row and the Usage window: one instance per consumer.
// It reads its inputs live through closures, and tells its consumer
// whenever the text may have changed.

import Foundation
import Observation

@MainActor
final class UsageTelemetryStatusFeed {

    /// Read every time the text is computed, so a consumer's seams (the
    /// Settings test overrides) take effect without rebuilding the feed.
    struct Inputs {
        var trackingOn: () -> Bool
        var ipcEnabled: () -> Bool
        var serverRunning: () -> Bool
        var activation: () -> UsageTelemetryActivation
        var monitor: () -> UsageIngestMonitor

        /// The app's own switches, server, activation and monitor.
        @MainActor static var production: Inputs {
            Inputs(
                trackingOn: { UsageTrackingSettings.enabled },
                ipcEnabled: { IPCSettings.enabled },
                serverRunning: { CalyxMCPServer.shared.isRunning },
                activation: { UsageTelemetryActivation.shared },
                monitor: { UsageIngestMonitor.shared })
        }
    }

    private let inputs: Inputs
    private let time: (Date) -> String
    private let notificationCenter: NotificationCenter
    private let onChange: () -> Void
    private var observers: [NSObjectProtocol] = []
    /// Bumped whenever the monitor observation is armed anew, so a change
    /// reported by an earlier arming neither calls `onChange` nor re-arms:
    /// at most one arming is ever live.
    private var monitorObservationGeneration = 0

    /// - `onChange` is called synchronously for
    ///   `.calyxUsageTelemetryStatusDidChange` and `.calyxIPCStateDidChange`
    ///   posted on the main thread, and on the main actor after each
    ///   change of the monitor's values. Creating the feed calls nothing.
    init(
        inputs: Inputs,
        time: @escaping (Date) -> String = UsageTelemetryStatusResolver.defaultTime,
        notificationCenter: NotificationCenter = .default,
        onChange: @escaping () -> Void
    ) {
        self.inputs = inputs
        self.time = time
        self.notificationCenter = notificationCenter
        self.onChange = onChange

        // Block observers on `.main`, not `NotificationObservation`: its
        // handler runs asynchronously, but the Settings label (R4b's tests)
        // and section C require the text to be current on the line after
        // a post. A post on the main thread runs these blocks inline; a
        // post elsewhere is delivered on the main thread, so the main
        // actor is current either way (the codebase's ConfigFileWatcher
        // idiom). Removed in `deinit`.
        for name in [Notification.Name.calyxUsageTelemetryStatusDidChange, .calyxIPCStateDidChange] {
            observers.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange() }
                })
        }
        observeMonitor()
    }

    isolated deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    /// `UsageTelemetryStatusResolver.text` over the inputs as they are now.
    var text: String {
        Self.text(inputs: inputs, time: time)
    }

    /// The same text without a feed (the Usage window model's seam).
    static func text(
        inputs: Inputs, time: (Date) -> String = UsageTelemetryStatusResolver.defaultTime
    ) -> String {
        let monitor = inputs.monitor()
        let input = UsageTelemetryStatusInput(
            trackingOn: inputs.trackingOn(),
            ipcEnabled: inputs.ipcEnabled(),
            serverRunning: inputs.serverRunning(),
            config: inputs.activation().status,
            lastAcceptedAt: monitor.lastAcceptedAt,
            lastRejection: monitor.lastRejection)
        return UsageTelemetryStatusResolver.text(for: UsageTelemetryStatusResolver.resolve(input), time: time)
    }

    /// Moves the monitor observation to the monitor the inputs name now;
    /// the previous arming is retired.
    func monitorDidChange() {
        observeMonitor()
    }

    /// Observes the monitor's two values once; a change arms the
    /// observation again and calls `onChange`. Arming anew retires every
    /// earlier arming through the generation.
    private func observeMonitor() {
        monitorObservationGeneration += 1
        let generation = monitorObservationGeneration
        let monitor = inputs.monitor()
        withObservationTracking {
            _ = monitor.lastAcceptedAt
            _ = monitor.lastRejection
        } onChange: { [weak self] in
            // Called before the change is applied: read it on the next turn.
            Task { @MainActor [weak self] in
                guard let self, generation == self.monitorObservationGeneration else { return }
                self.observeMonitor()
                self.onChange()
            }
        }
    }
}
