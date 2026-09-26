// SessionBrowserView.swift
// Calyx
//
// SwiftUI content view for `SessionBrowserWindowController`: lists
// every session `SessionBrowserModel.rows` reports, refreshed on a
// one-second poll (`.task`'s loop, cancelled automatically once the
// window closes and the view disappears). Row layout mirrors
// `AgentStatusView`'s row shape (state dot, name, secondary detail
// line, relative time via a `TimelineView`).

import SwiftUI

struct SessionBrowserView: View {
    @Bindable var model: SessionBrowserModel

    /// Single source of truth for every row list's left inset, so the
    /// scrolled calyx-session `VStack` and the two fixed sections above it
    /// (`remoteHostsSection`, `herdrSection`) can never drift apart again:
    /// each row view (`SessionBrowserRowView`, `HerdrSessionRowView`,
    /// `RemoteHostRowView`) already ends its own body with an identical
    /// `.padding(.horizontal, 14)`, so this constant is the only remaining
    /// variable standing between "these row types share one left edge"
    /// and "they don't." Section headers are intentionally NOT built from
    /// this constant -- they use their own fixed 14pt.
    private static let rowListHorizontalInset: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            if model.showRemoteHostsSection {
                remoteHostsSection
            }
            if model.showHerdrSection {
                herdrSection
            }
            Group {
                // `!model.showHerdrSection` guards this against
                // contradicting the herdr section rendered right above:
                // with herdr rows present but zero calyx-session rows,
                // "No sessions yet" would read as a lie one section down
                // from a list of sessions.
                if model.rows.isEmpty && !model.showHerdrSection {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        // Only labelled once a sibling section
                        // (remoteHostsSection/herdrSection) is also on
                        // screen -- see `showSessionsHeader`'s own doc
                        // comment for the full rule. `!model.rows.isEmpty`
                        // is baked into that property, so this never
                        // dangles over the empty ScrollView below it in
                        // the herdr-rows-but-zero-calyx-rows case.
                        if model.showSessionsHeader {
                            Text("Calyx Sessions")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(model.rows) { row in
                                        SessionBrowserRowView(row: row, now: context.date, model: model)
                                    }
                                }
                                .padding(.horizontal, Self.rowListHorizontalInset)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Compact "New Remote Session..." picker (SessionBrowserModel
    /// .remoteHostCandidates): one row per candidate host, mirroring
    /// SessionBrowserRowView's own dot + name + trailing-actions shape.
    /// Hidden entirely when there are no candidates.
    private var remoteHostsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remote Hosts")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            ForEach(model.remoteHostCandidates, id: \.self) { host in
                RemoteHostRowView(host: host, model: model)
            }
            .padding(.horizontal, Self.rowListHorizontalInset)
            Divider()
        }
    }

    /// herdr's own session section (`SessionBrowserModel.herdrRows`),
    /// mirroring `remoteHostsSection`'s exact shape one section down:
    /// same header/row/divider layout, hidden entirely (via
    /// `model.showHerdrSection` in `body` above) whenever herdr isn't
    /// detected or has zero live sessions -- an undetected herdr must
    /// render pixel-identical to today. Each server row
    /// (`HerdrSessionRowView`) is immediately followed by its own
    /// indented workspace rows (`row.workspaces`, `HerdrWorkspaceRowView`),
    /// in the order `session.snapshot` reported them -- a server with no
    /// workspaces (an empty snapshot, or one that failed) contributes
    /// just its own row, no orphaned workspace rows underneath.
    private var herdrSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("herdr Sessions")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            ForEach(model.herdrRows) { row in
                HerdrSessionRowView(row: row, model: model)
                ForEach(row.workspaces) { workspaceRow in
                    HerdrWorkspaceRowView(row: workspaceRow, model: model)
                }
            }
            .padding(.horizontal, Self.rowListHorizontalInset)
            Divider()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No sessions yet.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Persistent sessions you create will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row per `SessionBrowserModel.remoteHostCandidates` entry. Mirrors
/// `SessionBrowserRowView`'s dot + name + trailing-actions layout: a
/// neutral (no session state to represent yet) dot keeps the two
/// sections' columns aligned, "Attach" spawns a new session against the
/// host (`SessionBrowserModel.attachToRemoteHost(_:)`), "Install"
/// deploys the daemon to it first (`SessionBrowserModel.installRemote
/// (host:)`).
private struct RemoteHostRowView: View {
    let host: String
    let model: SessionBrowserModel

    private var installStatus: SessionBrowserModel.RemoteInstallStatus {
        model.installStatus(forHost: host)
    }

    /// User-visible label for the Install button, reflecting
    /// `installStatus` so a failed attempt (bad SSH auth, unreachable
    /// host) is distinguishable from a real success instead of the
    /// button silently doing nothing visible either way.
    private var installButtonLabel: String {
        switch installStatus {
        case .idle, .failed: return "Install"
        case .installing: return "Installing…"
        case .succeeded: return "Installed"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)

            Text(host)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(1)

            Spacer()

            Button("Attach") { model.attachToRemoteHost(host) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.SessionBrowser.remoteHostAttachButton(host))
            Button(installButtonLabel) { Task { await model.installRemote(host: host) } }
                .buttonStyle(.bordered)
                .disabled(installStatus == .installing)
                .accessibilityIdentifier(AccessibilityID.SessionBrowser.remoteHostInstallButton(host))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.SessionBrowser.remoteHostRow(host))
    }
}

/// One row per `SessionBrowserModel.herdrRows` entry -- the herdr
/// SERVER row (one per live socket); its own workspaces render as
/// separate, indented `HerdrWorkspaceRowView` rows immediately below it
/// (`herdrSection` above), not as part of this view. Same dot +
/// leading-VStack + trailing-action shape as `SessionBrowserRowView`
/// one section up: a fixed-green 8pt `Circle` is the outer `HStack`'s
/// first child, vertically centred against all three text lines below
/// it, followed by a three-line leading `VStack`. Line 1 is
/// `row.displayName` (bold -- the session's own name when discovery
/// found one, herdr's `"default"` term for the unnamed default session
/// included, falling back to its socket path only when discovery found
/// no name at all); line 2 is `row.info.id`, the session's socket path,
/// shown directly with no cwd summary. Line 3 is `row.statusLineText`,
/// which states the workspace/pane counts once known (`HerdrAttachGate
/// .decide`'s own doc comment, `SessionBrowserModel.swift`) -- those
/// counts come from a `session.snapshot` request per socket
/// (`HerdrSessionProvider.swift`'s own doc comment), never a
/// `herdr session list --json` shell-out. The dot itself is a fixed
/// green, never gray/orange -- every row here already passed a live
/// `connect()` probe (see `HerdrAttachGate`'s own doc comment), so there
/// is no "not running" or "orphaned" state for it to represent, unlike
/// `SessionBrowserRowView.dotColor`. The trailing button's title is
/// always `HerdrSessionRow.createButtonLabel` ("New"), never disabled --
/// pressing it always creates a new workspace and opens it
/// (`SessionBrowserWindowController.createHerdrWorkspace(_:)`),
/// regardless of how many workspaces this session already reports.
private struct HerdrSessionRowView: View {
    let row: HerdrSessionRow
    let model: SessionBrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Text(row.info.id)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(row.statusLineText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(HerdrSessionRow.createButtonLabel) { model.createHerdrWorkspace(row) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.SessionBrowser.herdrCreateButton(row.id))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.SessionBrowser.herdrRow(row.id))
    }
}

/// One row per `HerdrSessionRow.workspaces` entry -- a single workspace
/// nested under its own server row (`herdrSection` above), indented past
/// the server row's own left edge so the hierarchy reads visually. Same
/// dot + leading-VStack + trailing-actions shape as the server row one
/// type up, just two lines instead of three: line 1 is `row.displayLabel`
/// (bold -- the workspace's own label, falling back to its bare id when
/// blank, `HerdrTabTitlePolicy`'s own rule); line 2 is `row.paneCountText`
/// ("N pane(s)"). The dot is a fixed green for the identical reason the
/// server row's own is (`HerdrSessionRowView`'s own doc comment). Both
/// trailing buttons are never disabled: the leading button always opens
/// this workspace natively through the same path
/// (`SessionBrowserModel.attachHerdrWorkspace(_:)`,
/// `SessionBrowserWindowController.attachHerdrWorkspace(_:)`, which
/// focuses the tab instead of opening a second one when it is already
/// open), with its own label following `row.attachButtonLabel` --
/// "Show" once the row's own stored `isAttachedHere` is true (set by
/// `SessionBrowserModel.refresh()`; because it is part of the row's
/// `Equatable` value, a flip changes `herdrRows` and re-renders this
/// view), unchanged "Attach" otherwise, mirroring
/// `SessionBrowserRowView`'s own calyx-session button exactly; "Kill"
/// sends `workspace.close` for it, then refreshes
/// (`SessionBrowserModel.killHerdrWorkspace(_:)`), with no confirmation
/// dialog -- mirrors `SessionBrowserRowView`'s own calyx-session Kill
/// button exactly.
private struct HerdrWorkspaceRowView: View {
    let row: HerdrWorkspaceRow
    let model: SessionBrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayLabel)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Text(row.paneCountText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(row.attachButtonLabel) { model.attachHerdrWorkspace(row) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.SessionBrowser.herdrWorkspaceAttachButton(row.id))
            Button("Kill") { Task { await model.killHerdrWorkspace(row) } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.SessionBrowser.herdrWorkspaceKillButton(row.id))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.SessionBrowser.herdrWorkspaceRow(row.id))
    }
}

private struct SessionBrowserRowView: View {
    let row: SessionBrowserRow
    let now: Date
    let model: SessionBrowserModel

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    private var isRunning: Bool {
        row.info.state == .running
    }

    private var stateLabel: String {
        switch row.info.state {
        case .running: return "Running"
        case .exited(let code): return "Exited (\(code))"
        }
    }

    private var dotColor: Color {
        guard isRunning else { return .gray }
        return row.isOrphan ? .orange : .green
    }

    private var createdAt: Date {
        Date(timeIntervalSince1970: Double(row.info.createdAtMs) / 1000)
    }

    private var detailLine: String {
        var parts = [stateLabel, "\(row.info.attachedClients) client(s)"]
        parts.append(Self.relativeDateFormatter.localizedString(for: createdAt, relativeTo: now))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.info.name ?? row.info.id)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if row.isOrphan {
                        Text(SessionBrowserRow.orphanBadgeLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                if let cwd = row.info.cwd {
                    Text(cwd)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detailLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isRunning {
                Button(row.attachButtonLabel) { model.attach(row) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.SessionBrowser.attachButton(row.id))
                Button("Kill") { Task { await model.kill(row) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.SessionBrowser.killButton(row.id))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.SessionBrowser.row(row.id))
    }
}
