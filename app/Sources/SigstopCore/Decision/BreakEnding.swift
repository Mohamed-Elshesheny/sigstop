import Foundation

public enum BreakEnding {
    public static func ranOut(_ effects: [Effect], userAction: UserAction?) -> Bool {
        guard userAction == nil else { return false }
        return effects.contains { effect in
            if case .endBreak = effect { return true }
            return false
        }
    }
}
