import Foundation

enum ConcurrencyClass: String, Codable, Equatable, Sendable {
    case read
    case mutation
}
