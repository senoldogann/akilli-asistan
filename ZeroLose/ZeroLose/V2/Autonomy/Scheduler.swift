import Foundation

actor Scheduler {
    private let maxParallelReads: Int
    private let maxParallelMutations: Int

    init(maxParallelReads: Int, maxParallelMutations: Int = 1) {
        self.maxParallelReads = max(0, maxParallelReads)
        self.maxParallelMutations = max(0, maxParallelMutations)
    }

    func select(from tasks: [TaskNode]) -> [TaskID] {
        var selected: [TaskID] = []
        var selectedReads = 0
        var selectedMutations = 0

        for task in tasks where task.lifecycle == .ready {
            switch task.concurrencyClass {
            case .read:
                guard selectedReads < maxParallelReads else {
                    continue
                }
                selectedReads += 1
                selected.append(task.id)

            case .mutation:
                guard selectedMutations < maxParallelMutations else {
                    continue
                }
                selectedMutations += 1
                selected.append(task.id)
            }
        }

        return selected
    }
}
