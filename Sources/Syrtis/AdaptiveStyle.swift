import SwiftUI

// Drop-in replacements for the SwiftUI hierarchical foreground styles, for text
// drawn on the app's vibrant surfaces.
//
// Every window this app puts on screen — the popover, the settings window, the
// icon gallery — is backed by `PopoverBackdrop` (an `NSVisualEffectView` using
// `.hudWindow`, `behindWindow`), with Liquid Glass on top from macOS 26. On a
// vibrant surface AppKit blends the *semantic* label colors that `.secondary`
// and `.tertiary` resolve to into the backdrop, so how light they land depends
// on the wallpaper showing through rather than on the value they nominally
// carry. A literal `Color.white.opacity(_:)` is not a semantic color and takes
// no part in that blend: it composites at full strength.
//
// That difference is the whole fix. Both styles below restate the system value
// as a literal color in dark mode, which is what stops the glass from eating
// it. Light mode keeps the system styles, which are well-tuned there and were
// never the complaint.
//
// The opacities are not guesses. Rendered over an opaque dark background on
// macOS 27.0 (build 26A5425a) and measured by relative luminance:
//
//     .primary   0.877        white 0.40   0.476
//     .secondary 0.618        white 0.55   0.618
//     .tertiary  0.315        white 0.62   0.682
//
// So white 0.55 reproduces `.secondary`'s intended appearance exactly, and the
// two-level hierarchy the cards have used since their first version — value
// text secondary, supporting metadata tertiary — survives unchanged. Tertiary
// is deliberately *not* a match at 0.315: it was illegible on glass, and 0.40
// is a legibility floor that still sits clearly below secondary.

/// Drop-in replacement for `.secondary` foreground text on vibrant surfaces.
///
/// Dark mode swaps in white at 0.55 opacity, which measures the same luminance
/// as the system `.secondary` it stands in for — this restates the value as a
/// literal color so glass vibrancy cannot blend it away. Light mode keeps the
/// system style. See the file comment for the measurements.
struct SecondaryAdaptive: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.colorScheme == .dark
            ? AnyShapeStyle(Color.white.opacity(0.55))
            : AnyShapeStyle(.secondary)
    }
}

/// Drop-in replacement for `.tertiary` foreground text on vibrant surfaces.
///
/// Dark mode swaps in white at 0.40 opacity. Unlike ``SecondaryAdaptive`` this
/// is not a like-for-like restatement: the system tertiary (0.315) washed out
/// over the translucent surfaces, so de-emphasized text is lifted to a legible
/// floor that still sits below ``SecondaryAdaptive``. Light mode is untouched.
struct TertiaryAdaptive: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.colorScheme == .dark
            ? AnyShapeStyle(Color.white.opacity(0.40))
            : AnyShapeStyle(.tertiary)
    }
}

extension ShapeStyle where Self == SecondaryAdaptive {
    /// Adaptive stand-in for `.secondary`: system secondary in light mode,
    /// white 0.55 in dark mode. See ``SecondaryAdaptive``.
    static var secondaryAdaptive: SecondaryAdaptive { SecondaryAdaptive() }
}

extension ShapeStyle where Self == TertiaryAdaptive {
    /// Adaptive stand-in for `.tertiary`: system tertiary in light mode,
    /// white 0.40 in dark mode. See ``TertiaryAdaptive``.
    static var tertiaryAdaptive: TertiaryAdaptive { TertiaryAdaptive() }
}
