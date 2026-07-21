import SwiftUI

/// Drop-in replacement for `.tertiary` foreground text.
///
/// Light mode keeps the system `tertiaryLabel` color, which is well-tuned on
/// light and glass backgrounds. Dark mode swaps in white at 0.40 opacity: the
/// system tertiary (~0.25 white) washes out over the translucent Liquid Glass
/// surfaces, so we lift de-emphasized text to a legible floor while still
/// sitting below `.secondary`. Light mode is left untouched on purpose — see
/// the fix/dark-mode-contrast branch.
struct TertiaryAdaptive: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.colorScheme == .dark
            ? AnyShapeStyle(Color.white.opacity(0.40))
            : AnyShapeStyle(.tertiary)
    }
}

extension ShapeStyle where Self == TertiaryAdaptive {
    /// Adaptive stand-in for `.tertiary`: system tertiary in light mode,
    /// white 0.40 in dark mode. See ``TertiaryAdaptive``.
    static var tertiaryAdaptive: TertiaryAdaptive { TertiaryAdaptive() }
}
