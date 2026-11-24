import Foundation
@testable import NiruxCore
import Testing

struct ContextOfferTests {
    private let now: TimeInterval = 1_795_262_400

    private func session(_ agent: UsageAgent = .claude, context: Int?, idle: TimeInterval) -> UsageReport.LatestSession {
        UsageReport.LatestSession(key: UsageSessionKey(agent, "s"), contextTokens: context, contextWindow: nil, lastResponseAt: now - idle)
    }

    @Test func aClaudeSessionIsOfferedOnceHeavyOrColdOnly() {
        #expect(ContextOffer(session(context: 279_999, idle: 60), now: now) == nil)
        #expect(ContextOffer(session(context: 280_000, idle: 60), now: now)
            == ContextOffer(reason: .heavy, contextTokens: 280_000, lastResponseAt: now - 60))
        #expect(ContextOffer(session(context: 150_000, idle: 3_599), now: now) == nil, "its cache still holds")
        #expect(ContextOffer(session(context: 150_000, idle: 3_600), now: now)?.reason == .cold)
        #expect(ContextOffer(session(context: 400_000, idle: 7_200), now: now)?.reason == .cold, "cold says more than heavy")
        #expect(ContextOffer(session(context: 149_999, idle: 7_200), now: now) == nil)
        #expect(ContextOffer(session(context: nil, idle: 7_200), now: now) == nil, "compacted: no response since")
        #expect(ContextOffer(session(.codex, context: 400_000, idle: 60), now: now) == nil)
        #expect(ContextOffer(session(context: 300_000, idle: 60), now: now, startsFresh: false)?.choices == [.compact])
    }

    @Test func aLeadStartsAfreshOnceColdWithAHeavyContextOnly() {
        let started = now - 86_400
        #expect(ContextOffer.restartsLead(session(context: 200_000, idle: 3_600), runningSince: started, now: now))
        #expect(!ContextOffer.restartsLead(session(context: 199_999, idle: 7_200), runningSince: started, now: now))
        #expect(!ContextOffer.restartsLead(session(context: 400_000, idle: 3_599), runningSince: started, now: now))
        #expect(!ContextOffer.restartsLead(session(context: 400_000, idle: 7_200), runningSince: now - 60, now: now), "just resumed")
        #expect(!ContextOffer.restartsLead(session(.agy, context: 400_000, idle: 7_200), runningSince: started, now: now))
    }
}
