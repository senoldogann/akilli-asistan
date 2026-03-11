import SwiftUI

/// A collection of custom SVG icons for ZeroLose.
/// These are implemented as SwiftUI Shapes or Paths for maximum performance and vector quality.
struct ZeroLoseIcon: View {
    enum IconType {
        case sparkles, clipboard, gear, paperplane, eye, mic, micSlash, brain, camera, plus, waveform, person, trash, textbubble, xmark, globe, book
    }
    
    let type: IconType
    var color: Color = .white
    var size: CGFloat = 20
    
    var body: some View {
        iconView
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundColor(color)
            .contentShape(Rectangle()) // Makes the whole frame clickable
    }
    
    @ViewBuilder
    private var iconView: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            switch type {
            case .sparkles:
                Path { path in
                    path.move(to: CGPoint(x: w/2, y: 0))
                    path.addLine(to: CGPoint(x: w*0.6, y: h*0.35))
                    path.addLine(to: CGPoint(x: w, y: h/2))
                    path.addLine(to: CGPoint(x: w*0.6, y: h*0.65))
                    path.addLine(to: CGPoint(x: w/2, y: h))
                    path.addLine(to: CGPoint(x: w*0.4, y: h*0.65))
                    path.addLine(to: CGPoint(x: 0, y: h/2))
                    path.addLine(to: CGPoint(x: w*0.4, y: h*0.35))
                    path.closeSubpath()
                }
                .fill(color)
                
            case .clipboard:
                ZStack {
                    RoundedRectangle(cornerRadius: w*0.15)
                        .stroke(color, lineWidth: w*0.1)
                        .frame(width: w*0.7, height: h*0.9)
                    
                    Rectangle()
                        .fill(color)
                        .frame(width: w*0.4, height: h*0.2)
                        .offset(y: -h*0.4)
                }
                .frame(width: w, height: h)
                
            case .gear:
                ZStack {
                    Circle()
                        .stroke(color, lineWidth: w*0.1)
                        .frame(width: w*0.6, height: h*0.6)
                    
                    ForEach(0..<8) { i in
                        RoundedRectangle(cornerRadius: w*0.05)
                            .fill(color)
                            .frame(width: w*0.15, height: h*0.15)
                            .offset(y: -h*0.35)
                            .rotationEffect(.degrees(Double(i) * 45))
                    }
                }
                .frame(width: w, height: h)

            case .paperplane:
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h*0.5))
                    path.addLine(to: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w*0.5, y: h))
                    path.addLine(to: CGPoint(x: w*0.4, y: h*0.6))
                    path.closeSubpath()
                }
                .stroke(color, lineWidth: w*0.1)
                
            case .eye:
                ZStack {
                    Path { path in
                        path.addArc(center: CGPoint(x: w/2, y: h/2), radius: w*0.4, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                        path.addArc(center: CGPoint(x: w/2, y: h/2), radius: w*0.4, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                    }
                    .stroke(color, lineWidth: w*0.1)
                    
                    Circle()
                        .fill(color)
                        .frame(width: w*0.3, height: h*0.3)
                }
                
            case .mic:
                ZStack {
                    Capsule()
                        .stroke(color, lineWidth: w*0.1)
                        .frame(width: w*0.4, height: h*0.7)
                    
                    Path { path in
                        path.addArc(center: CGPoint(x: w/2, y: h*0.4), radius: w*0.45, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                    }
                    .stroke(color, lineWidth: w*0.1)
                }
                
            case .micSlash:
                ZStack {
                    ZeroLoseIcon(type: .mic, color: color, size: size)
                    Rectangle()
                        .fill(color.opacity(0.8))
                        .frame(width: w*0.1, height: h)
                        .rotationEffect(.degrees(45))
                }
                
            case .brain:
                Path { path in
                    // Left hemisphere
                    path.addEllipse(in: CGRect(x: w*0.1, y: h*0.2, width: w*0.4, height: h*0.6))
                    // Right hemisphere
                    path.addEllipse(in: CGRect(x: w*0.5, y: h*0.2, width: w*0.4, height: h*0.6))
                    // Top curve
                    path.addEllipse(in: CGRect(x: w*0.3, y: h*0.1, width: w*0.4, height: h*0.4))
                }
                .stroke(color, lineWidth: w*0.1)
                
            case .camera:
                ZStack {
                    RoundedRectangle(cornerRadius: w*0.1)
                        .stroke(color, lineWidth: w*0.1)
                        .frame(width: w*0.8, height: h*0.6)
                    
                    Circle()
                        .stroke(color, lineWidth: w*0.1)
                        .frame(width: w*0.3, height: h*0.3)
                    
                    Rectangle()
                        .fill(color)
                        .frame(width: w*0.2, height: h*0.1)
                        .offset(x: w*0.2, y: -h*0.35)
                }
                
            case .plus:
                Path { path in
                    path.move(to: CGPoint(x: w*0.2, y: h/2))
                    path.addLine(to: CGPoint(x: w*0.8, y: h/2))
                    path.move(to: CGPoint(x: w/2, y: h*0.2))
                    path.addLine(to: CGPoint(x: w/2, y: h*0.8))
                }
                .stroke(color, style: StrokeStyle(lineWidth: w*0.1, lineCap: .round))
                
            case .waveform:
                HStack(spacing: w*0.1) {
                    ForEach(0..<5) { i in
                        RoundedRectangle(cornerRadius: w*0.05)
                            .fill(color)
                            .frame(width: w*0.1, height: h * [0.4, 0.7, 1.0, 0.6, 0.3][i])
                    }
                }
                .frame(width: w, height: h)
                
            case .person:
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: w*0.4, height: h*0.4)
                        .offset(y: -h*0.2)
                    
                    Path { path in
                        path.addArc(center: CGPoint(x: w/2, y: h*1.1), radius: w*0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    }
                    .fill(color)
                }
                
            case .trash:
                Path { path in
                    // Adjust scale by adding padding (0.1 -> 0.9 range)
                    let pad: CGFloat = 0.05
                    let tw = w * (1 - pad*2)
                    let th = h * (1 - pad*2)
                    let ox = w * pad
                    let oy = h * pad
                    
                    // Lid
                    path.move(to: CGPoint(x: ox + tw*0.15, y: oy + th*0.2))
                    path.addLine(to: CGPoint(x: ox + tw*0.85, y: oy + th*0.2))
                    
                    // Handle on lid
                    path.move(to: CGPoint(x: ox + tw*0.4, y: oy + th*0.2))
                    path.addQuadCurve(to: CGPoint(x: ox + tw*0.6, y: oy + th*0.2), control: CGPoint(x: w/2, y: oy + th*0.05))
                    
                    // Body
                    path.move(to: CGPoint(x: ox + tw*0.25, y: oy + th*0.2))
                    path.addLine(to: CGPoint(x: ox + tw*0.3, y: oy + th*0.9))
                    path.addLine(to: CGPoint(x: ox + tw*0.7, y: oy + th*0.9))
                    path.addLine(to: CGPoint(x: ox + tw*0.75, y: oy + th*0.2))
                    
                    // Vertical lines in body
                    path.move(to: CGPoint(x: ox + tw*0.4, y: oy + th*0.35))
                    path.addLine(to: CGPoint(x: ox + tw*0.4, y: oy + th*0.75))
                    path.move(to: CGPoint(x: ox + tw*0.5, y: oy + th*0.35))
                    path.addLine(to: CGPoint(x: ox + tw*0.5, y: oy + th*0.75))
                    path.move(to: CGPoint(x: ox + tw*0.6, y: oy + th*0.35))
                    path.addLine(to: CGPoint(x: ox + tw*0.6, y: oy + th*0.75))
                }
                .stroke(color, style: StrokeStyle(lineWidth: w*0.08, lineCap: .round, lineJoin: .round))
                
            case .textbubble:
                Path { path in
                    path.addRoundedRect(in: CGRect(x: w*0.1, y: h*0.1, width: w*0.8, height: h*0.6), cornerSize: CGSize(width: w*0.1, height: w*0.1))
                    path.move(to: CGPoint(x: w*0.3, y: h*0.7))
                    path.addLine(to: CGPoint(x: w*0.2, y: h*0.9))
                    path.addLine(to: CGPoint(x: w*0.5, y: h*0.7))
                }
                .stroke(color, lineWidth: w*0.1)
                
            case .xmark:
                Path { path in
                    path.move(to: CGPoint(x: w*0.2, y: h*0.2))
                    path.addLine(to: CGPoint(x: w*0.8, y: h*0.8))
                    path.move(to: CGPoint(x: w*0.8, y: h*0.2))
                    path.addLine(to: CGPoint(x: w*0.2, y: h*0.8))
                }
                .stroke(color, lineWidth: w*0.1)
                
            case .globe:
                ZStack {
                    Circle()
                        .stroke(color, lineWidth: w*0.1)
                    
                    // Meridians
                    Ellipse()
                        .stroke(color, lineWidth: w*0.08)
                        .frame(width: w*0.4, height: h)
                    
                    // Equator
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h/2))
                        path.addLine(to: CGPoint(x: w, y: h/2))
                    }
                    .stroke(color, lineWidth: w*0.08)
                }
            
            case .book:
                Path { path in
                    // Book spine
                    path.move(to: CGPoint(x: w*0.2, y: h*0.1))
                    path.addLine(to: CGPoint(x: w*0.2, y: h*0.9))
                    
                    // Pages
                    path.move(to: CGPoint(x: w*0.2, y: h*0.1))
                    path.addQuadCurve(to: CGPoint(x: w*0.8, y: h*0.15), control: CGPoint(x: w*0.5, y: h*0.05))
                    path.addLine(to: CGPoint(x: w*0.8, y: h*0.95))
                    path.addQuadCurve(to: CGPoint(x: w*0.2, y: h*0.9), control: CGPoint(x: w*0.5, y: h*0.8))
                    
                    // Cover line
                    path.move(to: CGPoint(x: w*0.8, y: h*0.15))
                    path.addLine(to: CGPoint(x: w*0.85, y: h*0.15))
                    path.addLine(to: CGPoint(x: w*0.85, y: h*0.95))
                    path.addLine(to: CGPoint(x: w*0.8, y: h*0.95))
                }
                .stroke(color, lineWidth: w*0.08)
            }
        }
    }
}
