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
    /// Unscaled content height to scale from. `nil` scales against the host's
    /// live height instead, which is what a resizable surface needs: the
    /// popover's drag handle resizes the AppKit window without publishing the
    /// new height to the model, so any height read from the model lags the
    /// window for the whole drag and the content stops short of the frame.
    var baseHeight: CGFloat?
    let scale: CGFloat

    func body(content: Content) -> some View {
        if scale == 1.0 {
            content
        } else if let baseHeight {
            content
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: (baseWidth * scale).rounded(),
                    height: (baseHeight * scale).rounded(),
                    alignment: .topLeading)
        } else {
            GeometryReader { geo in
                content
                    .frame(width: baseWidth, height: max(1, geo.size.height / scale))
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .frame(width: (baseWidth * scale).rounded())
        }
    }
}
