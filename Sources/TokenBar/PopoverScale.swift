import AppKit
import SwiftUI

/// Text scale for the popover content. Stored in UserDefaults and applied as
/// a geometric scaleEffect on the scroll content, with the height reported to
/// the ScrollView compensated so scrolling stays accurate.
enum PopoverScale: String, CaseIterable {
    case `default`
    case large
    case larger

    static let storageKey = "tokenbar.popover.scale"

    static var current: PopoverScale {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(PopoverScale.init(rawValue:)) ?? .default
    }

    var label: String {
        switch self {
        case .default: return "Default"
        case .large: return "Large"
        case .larger: return "Larger"
        }
    }

    /// Geometric scale factor applied to the whole popover.
    var factor: CGFloat {
        switch self {
        case .default: return 1.0
        case .large: return 1.15
        case .larger: return 1.30
        }
    }
}

/// Scales the popover body and reports the scaled dimensions to the layout
/// engine (and therefore to NSPopover via preferredContentSize). At scale 1
/// it is a no-op, so no extra layers are introduced in the default case.
struct PopoverScaleModifier: ViewModifier {
    let baseWidth: CGFloat
    let baseHeight: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        if scale == 1.0 {
            content
        } else {
            content
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: (baseWidth * scale).rounded(),
                    height: (baseHeight * scale).rounded(),
                    alignment: .topLeading)
        }
    }
}
