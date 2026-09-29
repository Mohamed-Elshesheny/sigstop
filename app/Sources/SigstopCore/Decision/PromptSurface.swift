import Foundation

public enum PromptSurface: Sendable, Hashable {
    case card
    case fullScreen

    public init(level: EscalationLevel) {
        switch level {
        case .first, .second: self = .card
        case .third, .incident: self = .fullScreen
        }
    }
}

public enum PromptCardPlacement {
    public struct Box: Sendable, Hashable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
        public var isEmpty: Bool { width <= 0 || height <= 0 }

        public func contains(_ other: Box) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }

        public func contains(x px: Double, y py: Double) -> Bool {
            px >= x && px < maxX && py >= y && py < maxY
        }

        public func overlap(with other: Box) -> Double {
            let w = min(maxX, other.maxX) - max(x, other.x)
            let h = min(maxY, other.maxY) - max(y, other.y)
            return w > 0 && h > 0 ? w * h : 0
        }

        public func flippedVertically(primaryHeight: Double) -> Box {
            Box(x: x, y: primaryHeight - maxY, width: width, height: height)
        }
    }

    public static let width: Double = 420
    public static let inset: Double = 12

    public static func display(for window: Box, among displays: [Box]) -> Int? {
        guard !window.isEmpty else { return nil }
        if let index = displays.firstIndex(where: { $0.contains(x: window.midX, y: window.midY) }) {
            return index
        }
        let overlaps = displays.enumerated().map { ($0.offset, $0.element.overlap(with: window)) }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    public static func place(width: Double, height: Double, in visible: Box) -> Box {
        let w = min(width, visible.width)
        let h = min(height, visible.height)
        return Box(
            x: max(visible.x, visible.maxX - inset - w),
            y: max(visible.y, visible.maxY - inset - h),
            width: w,
            height: h
        )
    }
}
