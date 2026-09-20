import Foundation

/// SplitMix64.
///
/// Small, well distributed, and identical on every platform and every run, which is
/// the entire requirement. Core must not reach for `SystemRandomNumberGenerator`:
/// a message engine that cannot be replayed cannot be tested, and "it picked a
/// different joke that time" is not a debuggable bug report.
///
/// Shared by the message engine and the daily summary. Both needed exactly this and
/// each originally shipped its own copy.
public struct SeededGenerator: RandomNumberGenerator, Sendable, Hashable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform-enough index into a pool. Pools here are a handful of entries, so the
    /// modulo bias is far below anything a human would notice.
    public mutating func index(below count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int(next() % UInt64(count))
    }
}
