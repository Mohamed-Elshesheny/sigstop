import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

struct GitDeadlineTests {

    @Test("a read that beats its deadline cancels the deadline's timer")
    func fastReadCancelsTheDeadline() async {
        let once = GitCollector.ResumeOnce()
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + 30)
        deadline.setEventHandler { once.resume(nil) }

        let value: Result<GitSignal, GitCollector.GitReadFailure>? = await withCheckedContinuation { continuation in
            once.attach(continuation, deadline: deadline)
            deadline.resume()
            once.resume(.success(GitSignal(branch: "main", repoState: .clean, repoName: nil, readAt: Date())))
        }

        #expect((try? value?.get())?.branch == "main")
        #expect(deadline.isCancelled, "a timer left armed wakes the Mac for nothing")
    }

    @Test("a deadline that fires first still answers nil")
    func deadlineStillAnswers() async {
        let once = GitCollector.ResumeOnce()
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + 0.01)
        deadline.setEventHandler { once.resume(nil) }

        let value: Result<GitSignal, GitCollector.GitReadFailure>? = await withCheckedContinuation { continuation in
            once.attach(continuation, deadline: deadline)
            deadline.resume()
        }

        #expect(value == nil)
        #expect(deadline.isCancelled)
    }
}
