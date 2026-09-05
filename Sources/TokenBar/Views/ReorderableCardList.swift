import SwiftUI
import TokenBarCore

/// The settings list that orders and hides one lens's cards: a drag handle, the
/// card's name, and a switch, over the same comma-separated order/hidden
/// defaults every other id list in the app persists.
///
/// Factored out because Overview and Quota need exactly the same list. The
/// client-tabs list above it is deliberately NOT built on this: its rows carry
/// an agent icon, a "quota card only" caption and a disabled state driven by a
/// second preference, and folding those in would make this take a row-content
/// closure to serve one caller each way.
///
/// The list shows every card, hidden ones included — hiding a card must not
/// remove the switch that brings it back, and its position has to stay
/// draggable so it lands where the user meant when it returns.
struct ReorderableCardList: View {
    struct Item: Identifiable, Hashable {
        let id: String
        let label: String
        /// False for a card pinned by its lens (Overview's chart), which gets
        /// a caption instead of a switch.
        var canHide = true
    }

    /// Every card, in the order it currently renders.
    let items: [Item]
    @Binding var orderRaw: String
    @Binding var hiddenRaw: String
    /// Distinct per list: two lists sharing a drag coordinate space would let a
    /// drag in one target rows in the other.
    let dragSpace: String

    @State private var dragId: String?
    @State private var overId: String?
    @State private var rowFrames: [String: CGRect] = [:]

    private struct RowFramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    private var hidden: Set<String> { ClientRegistry.parseIdSet(hiddenRaw) }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(items) { item in
                row(item)
            }
        }
        .coordinateSpace(name: dragSpace)
        .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
        .glassCard(cornerRadius: 8)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Text("⠿")
                .font(.caption)
                .foregroundStyle(
                    dragId == item.id
                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiaryAdaptive))
                .help("Drag to reorder")
                .gesture(dragGesture(id: item.id))

            Text(item.label.localized)
                .font(.caption)

            if !item.canHide {
                Text("(always shown)")
                    .font(.caption2)
                    .foregroundStyle(.tertiaryAdaptive)
            }

            Spacer()

            if item.canHide {
                Toggle("", isOn: Binding(
                    get: { !hidden.contains(item.id) },
                    set: { show in
                        var next = hidden
                        if show { next.remove(item.id) } else { next.insert(item.id) }
                        hiddenRaw = next.sorted().joined(separator: ",")
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(dragId == item.id ? 0.5 : 1)
        .overlay(alignment: dropEdge(for: item.id) == .top ? .top : .bottom) {
            if let edge = dropEdge(for: item.id) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: edge == .top ? -3 : 3)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFramesKey.self,
                    value: [item.id: geo.frame(in: .named(dragSpace))])
            })
    }

    private func dropEdge(for id: String) -> VerticalEdge? {
        let order = items.map(\.id)
        guard let dragId, overId == id, dragId != id,
              let fromI = order.firstIndex(of: dragId),
              let toI = order.firstIndex(of: id)
        else { return nil }
        return fromI < toI ? .bottom : .top
    }

    private func dragGesture(id: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(dragSpace))
            .onChanged { value in
                dragId = id
                let over = rowFrames.first { $0.value.contains(value.location) }?.key
                overId = (over != nil && over != id) ? over : nil
            }
            .onEnded { _ in
                if let over = overId, over != id {
                    // The list is the whole universe of this lens's cards, so
                    // the reordered sequence IS the order to persist — no
                    // off-screen ids to merge back in the way the client-tabs
                    // list has to.
                    orderRaw = ClientRegistry.reorder(items.map(\.id), from: id, to: over)
                        .joined(separator: ",")
                }
                dragId = nil
                overId = nil
            }
    }
}
