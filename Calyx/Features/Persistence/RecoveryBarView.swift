// RecoveryBarView.swift
// Calyx
//
// Chrome-style in-app "your previous session was preserved" bar,
// shown at the top of a window's content when `model.showRecoveryBar`
// is true (see RecoveryBarModel's own file header for the full
// design-decision writeup). Hosted via `MainContentView.body`'s
// `mainContent.safeAreaInset(edge: .top)`, above the tab bar/pane
// content -- never intercepts first responder/keyboard focus, since
// neither the bar nor its buttons are ever made first responder by any
// code path.

import SwiftUI

struct RecoveryBarView: View {
    let model: RecoveryBarModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            Text("Your previous session was preserved.")
                .font(.callout)

            Spacer()

            Button("Restore") {
                model.restore()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.restoreButton)

            Button("Dismiss") {
                model.dismiss()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.dismissButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.RecoveryBar.container)
    }
}

/// Ties a chrome bar's text/button colors to the user's theme color and
/// glass opacity rather than a fixed `.thinMaterial`, so it reads as
/// part of the window chrome. Applies no `.glassEffect` of its own:
/// `MainContentView`'s single root glass sheet (one `.background` with
/// `.ignoresSafeArea()`, covering the whole window) already paints
/// through wherever this modifier is applied, using the same
/// `GlassTheme.chromeTint(...)` formula as `chromeScheme` below. A
/// second `.glassEffect` here would stack a second tint pass on top of
/// that one, reading visibly darker than the single-pass chrome around
/// it. This modifier supplies legibility handling only; the glass
/// surface itself comes from the root sheet.
///
/// The glass path has no bottom stroke of its own, since it stays
/// seamless with the root sheet by construction; the reduceTransparency
/// path keeps its `Divider()`, since that flat mode has no shared glass
/// surface to stay seamless with.
///
/// Reused by `BrowserContainerView`'s toolbar and its `ErrorBannerView`,
/// both hosted on the same root sheet. `ApprovalBannerView` does NOT use
/// this modifier: it renders on its own untinted regular glass panel
/// (`ApprovalPanelContentView`), independent of the Calyx theme, so it
/// draws standard `.primary`/`.secondary` text/button colors instead.
struct RecoveryBarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    private var chromeScheme: ColorScheme {
        let tint = reduceTransparency ? GlassTheme.reducedTransparencyFill(for: themeColor) : GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
        return ColorLuminance.prefersDarkText(for: tint) ? .light : .dark
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if reduceTransparency { Divider() }
            }
            .environment(\.colorScheme, chromeScheme)
            .foregroundStyle(themePreset == "ghostty"
                ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                : AnyShapeStyle(.primary))
    }
}
