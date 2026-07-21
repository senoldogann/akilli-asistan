import SwiftUI

struct DiagramData: Codable, Equatable {
    struct Node: Codable, Identifiable, Equatable {
        let id: String
        let label: String
        let type: String?
    }
    struct Link: Codable, Equatable {
        let from: String
        let to: String
        let label: String?
    }
    let nodes: [Node]
    let links: [Link]
}

struct SystemDiagramView: View {
    let data: DiagramData
    
    @State private var hoveredNodeId: String? = nil
    
    private var nodePositions: [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        let count = data.nodes.count
        guard count > 0 else { return [:] }
        
        for (index, node) in data.nodes.enumerated() {
            // Layout nodes in columns/rows depending on index
            let row = index / 2
            let col = index % 2
            
            // Dynamic calculations to prevent layout overlap
            let x = CGFloat(110 + col * 220)
            let y = CGFloat(60 + row * 110)
            positions[node.id] = CGPoint(x: x, y: y)
        }
        return positions
    }
    
    var body: some View {
        ZStack {
            // 1. Connection lines & labels
            let positions = nodePositions
            ForEach(0..<data.links.count, id: \.self) { index in
                let link = data.links[index]
                if let start = positions[link.from], let end = positions[link.to] {
                    ConnectionArrow(start: start, end: end, label: link.label)
                }
            }
            
            // 2. Nodes
            ForEach(data.nodes) { node in
                if let pos = nodePositions[node.id] {
                    NodeCardView(node: node, isHovered: hoveredNodeId == node.id)
                        .position(pos)
                        .onHover { hovering in
                            hoveredNodeId = hovering ? node.id : nil
                        }
                }
            }
        }
        .frame(width: 440, height: CGFloat(80 + ((data.nodes.count + 1) / 2) * 110))
        .background(Color.black.opacity(0.12))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.glassStroke, lineWidth: 0.8)
        )
        .padding(.vertical, 8)
    }
}

struct NodeCardView: View {
    let node: DiagramData.Node
    let isHovered: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: nodeIcon(for: node.type ?? ""))
                .font(.system(size: 13))
                .foregroundColor(.orange)
                .symbolEffect(.bounce, value: isHovered)
            
            Text(node.label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.orange.opacity(0.15) : Color.glassFill)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovered ? Color.orange : Color.glassStroke, lineWidth: isHovered ? 1.2 : 0.8)
        )
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
    }
    
    private func nodeIcon(for type: String) -> String {
        switch type.lowercased() {
        case "client", "user", "browser", "app": return "laptopcomputer"
        case "gateway", "api", "proxy", "ingress": return "network"
        case "database", "db", "sql", "nosql", "postgres": return "server.rack"
        case "cache", "redis", "memcached": return "bolt.horizontal.fill"
        case "queue", "kafka", "rabbitmq", "pubsub": return "arrow.3.trianglepath"
        case "service", "svc", "microservice", "backend": return "cpu"
        default: return "square.grid.2x2"
        }
    }
}

struct ConnectionArrow: View {
    let start: CGPoint
    let end: CGPoint
    let label: String?
    
    var body: some View {
        ZStack {
            // Clean connected lines
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            
            // Arrow head
            Path { path in
                let angle = atan2(end.y - start.y, end.x - start.x)
                let arrowLength: CGFloat = 7
                let arrowAngle = CGFloat.pi / 6
                
                let p1 = CGPoint(
                    x: end.x - arrowLength * cos(angle - arrowAngle),
                    y: end.y - arrowLength * sin(angle - arrowAngle)
                )
                let p2 = CGPoint(
                    x: end.x - arrowLength * cos(angle + arrowAngle),
                    y: end.y - arrowLength * sin(angle + arrowAngle)
                )
                
                path.move(to: end)
                path.addLine(to: p1)
                path.addLine(to: p2)
                path.closeSubpath()
            }
            .fill(Color.orange.opacity(0.8))
            
            if let label = label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.glassStroke, lineWidth: 0.5))
                    // Position label in center of path line
                    .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            }
        }
    }
}
