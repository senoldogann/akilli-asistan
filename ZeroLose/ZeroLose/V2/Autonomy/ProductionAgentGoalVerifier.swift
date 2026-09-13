import Foundation

struct ProductionAgentGoalVerifier: GoalVerifying {
    func verify(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot
    ) async throws -> GoalVerificationResult {
        guard graph.goalID == goal.id,
              !graph.tasks.isEmpty else {
            return GoalVerificationResult(completed: false, evidence: nil)
        }

        let tasks = graph.tasks.values
        guard tasks.allSatisfy({ $0.lifecycle == .succeeded }),
              tasks.allSatisfy({ !$0.verificationEvidence.isEmpty }) else {
            return GoalVerificationResult(completed: false, evidence: nil)
        }

        let tainted = tasks.contains { task in
            task.verificationEvidence.contains(where: \.tainted)
        }
        let evidence = VerificationEvidence(
            summary: "Verified goal completion from \(tasks.count) task(s)",
            provenance: "agent-goal-verifier:task-evidence",
            tainted: tainted
        )
        return GoalVerificationResult(completed: true, evidence: evidence)
    }
}
