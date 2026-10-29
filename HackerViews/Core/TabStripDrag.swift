import CoreGraphics

/// Where the tabs of a strip sit while one is dragged along it: the dragged tab
/// follows the pointer, held within the strip, and the tabs it passes slide
/// aside to open the gap it drops into.
public struct TabStripDrag: Equatable, Sendable {
    /// Each tab's frame at rest, in strip order.
    public let frames: [CGRect]
    /// The dragged tab's index at rest.
    public let from: Int
    public let spacing: CGFloat
    /// The pointer's horizontal travel since the drag began.
    public var translation: CGFloat = 0
    /// Set once the tab is let go: the index it settles into.
    public private(set) var dropped: Int?

    public init(frames: [CGRect], from: Int, spacing: CGFloat) {
        self.frames = frames
        self.from = from
        self.spacing = spacing
    }

    private var width: CGFloat { frames[from].width }

    /// The index the dragged tab would drop into now: past every tab whose
    /// middle its leading edge has crossed, so the strip's either end is in
    /// reach whatever the widths.
    public var target: Int {
        if let dropped { return dropped }
        let minX = frames[from].minX + draggedOffset, maxX = minX + width
        let before = frames[..<from].filter { minX < $0.midX }.count
        let after = frames[(from + 1)...].filter { maxX > $0.midX }.count
        return from - before + after
    }

    /// The dragged tab's offset from its resting place.
    public var draggedOffset: CGFloat {
        if let dropped { return settledOffset(at: dropped) }
        guard let first = frames.first, let last = frames.last else { return 0 }
        let start = frames[from].minX
        return min(max(translation, first.minX - start), last.maxX - width - start)
    }

    /// The offset of the tab resting at `index`.
    public func offset(at index: Int) -> CGFloat {
        if index == from { return draggedOffset }
        let target = target, shift = width + spacing
        if index > from && index <= target { return -shift }
        if index < from && index >= target { return shift }
        return 0
    }

    /// Let go: the dragged tab settles into the gap it is over.
    public mutating func drop() { dropped = target }

    private func settledOffset(at index: Int) -> CGFloat {
        if index > from { return frames[index].maxX - width - frames[from].minX }
        if index < from { return frames[index].minX - frames[from].minX }
        return 0
    }
}
