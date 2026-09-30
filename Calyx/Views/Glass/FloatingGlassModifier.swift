// FloatingGlassModifier.swift
// Calyx
//
// Shared modifier for floating Liquid Glass styling on tab/group items.

import SwiftUI
import AppKit

enum GlassTheme {
    static func chromeTintOpacity(for glassOpacity: Double) -> Double {
        let clamped = max(0.0, min(1.0, glassOpacity))
        return 0.20 + (clamped * 0.80)
    }

    /// Derive chrome tint from theme color.
    static func chromeTint(for themeColor: NSColor, glassOpacity: Double) -> NSColor {
        let hsb = toHSB(themeColor)
        let opacity = chromeTintOpacity(for: glassOpacity)
        if hsb.saturation < 0.05 {
            // Neutral: use brightness only
            return NSColor(hue: 0, saturation: 0, brightness: hsb.brightness, alpha: opacity)
        }
        return NSColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness, alpha: opacity)
    }

    /// Opaque root-sheet fill used in place of the glass while Reduce Transparency is on.
    static func reducedTransparencyFill(for themeColor: NSColor) -> NSColor {
        chromeTint(for: themeColor, glassOpacity: 1.0)
    }

    /// Derive atmosphere top gradient color from theme color.
    static func atmosphereTop(for themeColor: NSColor, glassOpacity: Double) -> NSColor {
        let hsb = toHSB(themeColor)
        if hsb.saturation < 0.05 {
            let alpha = 0.28 + (max(0, min(1, glassOpacity)) * 0.64)
            return NSColor(hue: 0, saturation: 0, brightness: hsb.brightness, alpha: alpha)
        }
        return NSColor(hue: hsb.hue, saturation: hsb.saturation * 0.6, brightness: 0.84, alpha: 0.28)
    }

    /// Derive atmosphere bottom gradient color from theme color.
    static func atmosphereBottom(for themeColor: NSColor, glassOpacity: Double) -> NSColor {
        let hsb = toHSB(themeColor)
        if hsb.saturation < 0.05 {
            let alpha = 0.34 + (max(0, min(1, glassOpacity)) * 0.58)
            return NSColor(hue: 0, saturation: 0, brightness: hsb.brightness, alpha: alpha)
        }
        return NSColor(hue: hsb.hue, saturation: hsb.saturation * 0.8, brightness: 0.05, alpha: 0.34)
    }

    /// Derive accent gradient color from theme color.
    static func accentGradient(for themeColor: NSColor) -> NSColor {
        let hsb = toHSB(themeColor)
        if hsb.saturation < 0.05 {
            return NSColor(hue: 0, saturation: 0, brightness: 0, alpha: 0.0)
        }
        return NSColor(hue: hsb.hue, saturation: max(0.6, hsb.saturation), brightness: 0.8, alpha: 0.18)
    }

    static var specularStroke: Color {
        Color.white.opacity(0.24)
    }

    /// Derive the inactive-window tint overlay color: theme color hue/saturation/brightness
    /// preserved as-is, full opacity.
    static func inactiveOverlayColor(for themeColor: NSColor) -> NSColor {
        let hsb = toHSB(themeColor)
        return NSColor(hue: hsb.hue, saturation: min(hsb.saturation * 1.0, 1.0), brightness: hsb.brightness, alpha: 1.0)
    }

    /// Opacity for the inactive-window tint overlay: matches the active-state chrome tint's own alpha.
    static func inactiveOverlayOpacity(for glassOpacity: Double) -> Double {
        chromeTintOpacity(for: glassOpacity)
    }

    // HSB extraction helper
    private static func toHSB(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }
}

struct TabChromeModifier: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat
    let reduceTransparency: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(isActive ? 0.15 : 0.05))
            )
        } else {
            if isActive {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                    .opacity(controlActiveState == .key ? 1.0 : 0.5)
            } else {
                content
                    .opacity(controlActiveState == .key ? 1.0 : 0.5)
            }
        }
    }
}

/// The atmosphere-gradient background shared by `MainContentView` and
/// `QuickTerminalContentView`: a theme-derived linear gradient with a
/// bottom-trailing radial accent, applied as a `.background` layer that
/// ignores the safe area. Renders nothing while `reduceTransparency` is
/// true. `specularStroke` adds the hairline `GlassTheme.specularStroke`
/// outline -- `MainContentView` passes `true`, `QuickTerminalContentView`
/// passes `false` for a stroke-less atmosphere.
struct GlassAtmosphereBackground: ViewModifier {
    let themeColor: NSColor
    let glassOpacity: Double
    let reduceTransparency: Bool
    let specularStroke: Bool

    func body(content: Content) -> some View {
        content.background {
            if !reduceTransparency {
                atmosphereLayer
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var atmosphereLayer: some View {
        let gradient = Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(nsColor: GlassTheme.atmosphereTop(for: themeColor, glassOpacity: glassOpacity)), Color(nsColor: GlassTheme.atmosphereBottom(for: themeColor, glassOpacity: glassOpacity))],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RadialGradient(
                    colors: [Color(nsColor: GlassTheme.accentGradient(for: themeColor)), Color.clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 420
                )
            )
        if specularStroke {
            gradient.overlay(
                Rectangle()
                    .stroke(GlassTheme.specularStroke.opacity(0.30), lineWidth: 1)
            )
        } else {
            gradient
        }
    }
}

/// Overlays a theme-derived tint (hue, saturation, and brightness carried
/// through unchanged) when the window is not key, matching Ghostty's
/// inactive-window dimming (ported from TerminalViewContainer.swift).
/// The tint renders into the modified view's own `.background`: it covers exactly
/// the host view's frame (coverage is set by what you attach it to, not by options
/// here), and the glass or flat fill it dims must be chained after it so the tint
/// sits in front of that fill, not behind it.
struct GlassInactiveTintModifier: ViewModifier {
    let themeColor: NSColor
    let glassOpacity: Double
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content.background(
            Color(nsColor: GlassTheme.inactiveOverlayColor(for: themeColor))
                .opacity(controlActiveState == .key ? 0 : GlassTheme.inactiveOverlayOpacity(for: glassOpacity))
                .allowsHitTesting(false)
        )
    }
}
