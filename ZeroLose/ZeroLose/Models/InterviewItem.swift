import Foundation

struct InterviewItem: Identifiable, Codable, Hashable {
    let id: String
    let category: String
    let question: String
    let answer: String
}
