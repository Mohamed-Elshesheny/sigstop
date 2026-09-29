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

        public func contains(_ other: Box) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }
    }

    public static let width: Double = 420
    public static let inset: Double = 12

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
