// GlassThemeTests.swift
// CalyxTests
//
// Tests for GlassTheme.chromeTintOpacity(for:) which maps a glass opacity
// value (0.0-1.0) to a chrome tint opacity via 0.20 + (clamped * 0.80).
//
// Coverage:
// - Zero input -> minimum tint (0.20)
// - Default input (0.7) -> 0.76
// - Maximum input (1.0) -> 1.00
// - Negative input clamped to 0.0 -> 0.20
// - Above-one input clamped to 1.0 -> 1.00
// - Theme color derivation: chromeTint(for:glassOpacity:), atmosphereTop(for:),
//   atmosphereBottom(for:), accentGradient(for:)

import AppKit
import Testing
@testable import Calyx

@Suite("GlassTheme chromeTintOpacity Tests")
struct GlassThemeTests {

    // MARK: - Happy Path

    @Test("chromeTintOpacity returns 0.20 for zero input")
    func chromeTintOpacity_atZero() {
        let result = GlassTheme.chromeTintOpacity(for: 0.0)
        #expect(result == 0.20)
    }

    @Test("chromeTintOpacity returns 0.76 for default (0.7)")
    func chromeTintOpacity_atDefault() {
        let result = GlassTheme.chromeTintOpacity(for: 0.7)
        #expect(abs(result - 0.76) < 0.01)
    }

    @Test("chromeTintOpacity returns 1.00 for max (1.0)")
    func chromeTintOpacity_atMax() {
        let result = GlassTheme.chromeTintOpacity(for: 1.0)
        #expect(result == 1.00)
    }

    // MARK: - Clamping

    @Test("chromeTintOpacity clamps negative input to 0.20")
    func chromeTintOpacity_clampNegative() {
        let result = GlassTheme.chromeTintOpacity(for: -0.5)
        #expect(result == 0.20)
    }

    @Test("chromeTintOpacity clamps above-one input to 1.00")
    func chromeTintOpacity_clampAboveOne() {
        let result = GlassTheme.chromeTintOpacity(for: 1.5)
        #expect(result == 1.00)
    }
}

// MARK: - Theme Color Derivation Tests

@Suite("GlassTheme Theme Color Derivation")
struct GlassThemeColorDerivationTests {

    // MARK: - Helpers

    /// Extract RGBA components from an NSColor for approximate comparison.
    private func components(of color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return (converted.redComponent, converted.greenComponent, converted.blueComponent)
    }

    /// Check whether a color is approximately neutral (saturation below threshold).
    private func isNeutral(_ color: NSColor, threshold: CGFloat = 0.05) -> Bool {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return converted.saturationComponent < threshold
    }

    // MARK: - chromeTint(for:glassOpacity:)

    @Test("chromeTint with Original preset produces a dark blue tint")
    func chromeTintOriginalPreset() {
        let baseColor = ThemeColorPreset.original.color
        let tint = GlassTheme.chromeTint(for: baseColor, glassOpacity: 0.7)
        let (r, g, b) = components(of: tint)
        // Original color is dark blue: r ~0.02, g ~0.05, b ~0.11
        // The tint should preserve that blue-dominant hue
        #expect(b > r, "Blue component should exceed red for original blue tint")
        #expect(b > g, "Blue component should exceed green for original blue tint")
    }

    @Test("chromeTint with Red preset produces a dark red tint")
    func chromeTintRedPreset() {
        let redColor = NSColor(red: 0.3, green: 0.02, blue: 0.02, alpha: 1.0)
        let tint = GlassTheme.chromeTint(for: redColor, glassOpacity: 0.7)
        let (r, g, b) = components(of: tint)
        // A red-based color should produce a red-dominant tint
        #expect(r > g, "Red component should exceed green for red tint")
        #expect(r > b, "Red component should exceed blue for red tint")
    }

    // MARK: - atmosphereTop(for:)

    @Test("atmosphereTop with Original preset returns a blue-ish color")
    func atmosphereTopOriginalPreset() {
        let baseColor = ThemeColorPreset.original.color
        let top = GlassTheme.atmosphereTop(for: baseColor, glassOpacity: 0.7)
        let (r, _, b) = components(of: top)
        // Original theme atmosphere top should lean blue
        #expect(b > r, "Blue should exceed red for original atmosphere top")
    }

    @Test("atmosphereTop with Ghostty preset returns a neutral color")
    func atmosphereTopGhosttyPreset() {
        let baseColor = ThemeColorPreset.ghostty.color
        let top = GlassTheme.atmosphereTop(for: baseColor, glassOpacity: 0.7)
        #expect(
            isNeutral(top),
            "Ghostty atmosphere top should be neutral (saturation < 0.05)"
        )
    }

    // MARK: - atmosphereBottom(for:)

    @Test("atmosphereBottom with Black preset returns a neutral color")
    func atmosphereBottomBlackPreset() {
        let baseColor = ThemeColorPreset.black.color
        let bottom = GlassTheme.atmosphereBottom(for: baseColor, glassOpacity: 0.7)
        #expect(
            isNeutral(bottom),
            "Black atmosphere bottom should be neutral (saturation < 0.05)"
        )
    }

    // MARK: - accentGradient(for:)

    @Test("accentGradient with Original preset returns a colored result")
    func accentGradientOriginalPreset() {
        let baseColor = ThemeColorPreset.original.color
        let accent = GlassTheme.accentGradient(for: baseColor)
        let converted = accent.usingColorSpace(.sRGB) ?? accent
        let saturation = converted.saturationComponent
        // Original preset has a blue hue, so accent gradient should have noticeable color
        #expect(
            saturation > 0.01,
            "Original accent gradient should have visible color (saturation \(saturation))"
        )
    }

    @Test("accentGradient with Gray preset returns a neutral result")
    func accentGradientGrayPreset() {
        let baseColor = ThemeColorPreset.gray.color
        let accent = GlassTheme.accentGradient(for: baseColor)
        #expect(
            isNeutral(accent),
            "Gray accent gradient should be neutral (saturation < 0.05)"
        )
    }
}

// MARK: - Reduce Transparency Fill Tests

@Suite("GlassTheme reducedTransparencyFill")
struct GlassThemeReducedTransparencyFillTests {

    private let tolerance: CGFloat = 0.005

    private func hsba(of color: NSColor) -> (h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b, a)
    }

    private func rgba(of color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    @Test("fill is fully opaque")
    func fillIsOpaque() {
        let input = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 0.3)
        let fill = GlassTheme.reducedTransparencyFill(for: input)
        #expect(abs(rgba(of: fill).a - 1.0) < tolerance)
    }

    @Test("saturated input preserves hue, saturation, brightness")
    func saturatedPreservesHSB() {
        // sRGB(0.1, 0.2, 0.4): max=0.4, min=0.1 -> s=0.75, b=0.4,
        // hue=(4 + (0.1-0.2)/0.3)/6 = 0.6111
        let input = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1.0)
        let out = hsba(of: GlassTheme.reducedTransparencyFill(for: input))
        #expect(abs(out.h - 0.6111) < tolerance)
        #expect(abs(out.s - 0.75) < tolerance)
        #expect(abs(out.b - 0.4) < tolerance)
        #expect(abs(out.a - 1.0) < tolerance)
    }

    @Test("neutral input yields zero saturation with brightness preserved")
    func neutralDesaturates() {
        // sRGB(0.5, 0.5, 0.51): s = 0.01/0.51 ~ 0.0196 (< 0.05), b = 0.51
        let input = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.51, alpha: 1.0)
        let fill = GlassTheme.reducedTransparencyFill(for: input)
        let out = hsba(of: fill)
        #expect(out.s < tolerance)
        #expect(abs(out.b - 0.51) < tolerance)
        let (r, g, b, a) = rgba(of: fill)
        #expect(abs(r - 0.51) < tolerance)
        #expect(abs(g - 0.51) < tolerance)
        #expect(abs(b - 0.51) < tolerance)
        #expect(abs(a - 1.0) < tolerance)
    }

    @Test("fill equals chromeTint at glassOpacity 1.0", arguments: [
        NSColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1.0),
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.51, alpha: 1.0),
        NSColor(srgbRed: 0.3, green: 0.02, blue: 0.02, alpha: 0.5),
        ThemeColorPreset.original.color,
    ])
    func matchesChromeTintAtFullOpacity(input: NSColor) {
        let fill = rgba(of: GlassTheme.reducedTransparencyFill(for: input))
        let tint = rgba(of: GlassTheme.chromeTint(for: input, glassOpacity: 1.0))
        #expect(abs(fill.r - tint.r) < tolerance)
        #expect(abs(fill.g - tint.g) < tolerance)
        #expect(abs(fill.b - tint.b) < tolerance)
        #expect(abs(fill.a - tint.a) < tolerance)
    }

    @Test("Original preset fill does not prefer dark text")
    func originalPresetPrefersLightText() {
        let fill = GlassTheme.reducedTransparencyFill(for: ThemeColorPreset.original.color)
        #expect(ColorLuminance.prefersDarkText(for: fill) == false)
        let (r, g, b, a) = rgba(of: fill)
        // #050D1C = (5, 13, 28) / 255
        #expect(abs(r - 5.0 / 255.0) < tolerance)
        #expect(abs(g - 13.0 / 255.0) < tolerance)
        #expect(abs(b - 28.0 / 255.0) < tolerance)
        #expect(abs(a - 1.0) < tolerance)
    }
}
