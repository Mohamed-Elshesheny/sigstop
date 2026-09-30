import Foundation
import Testing

@testable import SigstopSensors

struct StaleEvidenceTests {

    @Test("the stale line never says zero minutes or one minutes")
    func staleLineReadsLikeEnglish() {
        #expect(ContextEngine.staleSummary(23) == "nothing has corroborated this for 23s")
        #expect(ContextEngine.staleSummary(83) == "nothing has corroborated this for 83s")
        #expect(ContextEngine.staleSummary(119) == "nothing has corroborated this for 119s")
        #expect(ContextEngine.staleSummary(120) == "nothing has corroborated this for 2 minutes")
        #expect(ContextEngine.staleSummary(610) == "nothing has corroborated this for 10 minutes")
    }
}
