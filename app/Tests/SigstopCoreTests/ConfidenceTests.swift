import Foundation
import Testing

@testable import SigstopCore

@Suite("confidence")
struct ConfidenceTests {

    @Test("confidence clamps at construction, however it arrives")
    func clampsAtConstruction() throws {
        #expect(Confidence(1.5).value == 1.0)
        #expect(Confidence(-0.5).value == 0.0)
        #expect(Confidence(.nan).value == 0.0)
        #expect(Confidence(.infinity).value == 0.0)
        #expect(Confidence(0.42).value == 0.42)
        let decoded = try JSONDecoder().decode([Confidence].self, from: Data("[7, -3]".utf8))
        #expect(decoded.map(\.value) == [1.0, 0.0])
    }
}
