import SwiftUI
import AppKit

/// Quick Terminal root view.
///
/// Root-sheet rule: the Liquid Glass tile is a single sheet attached as a
/// `.background` on the `GlassEffectContainer`'s result, never a per-region
/// `.glassEffect` on the terminal and never placed inside the container.
/// A per-region glass tile draws an edge along its outline, which shows as a
/// hairline at the titlebar boundary; a sheet inside the container covers the
/// content (see 7f2e8e389). Mirrors `MainContentView` (3519a804e).
struct QuickTerminalContentView: View {
    let splitContainerView: SplitContainerView

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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

    var body: some View {
        GlassEffectContainer {
            TerminalContainerView(
                splitContainerView: splitContainerView,
                reduceTransparency: reduceTransparency,
                glassOpacity: glassOpacity
            )
            .padding(.leading, 8)
        }
        .background {
            Group {
                if reduceTransparency {
                    Color(nsColor: GlassTheme.reducedTransparencyFill(for: themeColor))
                } else {
                    Color.clear
                        .modifier(GlassInactiveTintModifier(themeColor: themeColor, glassOpacity: glassOpacity))
                        .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .modifier(GlassAtmosphereBackground(themeColor: themeColor, glassOpacity: glassOpacity, reduceTransparency: reduceTransparency, specularStroke: false))
    }
}
