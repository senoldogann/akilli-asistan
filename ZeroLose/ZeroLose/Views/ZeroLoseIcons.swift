import SwiftUI

/// ZeroLose için özel SVG ikonlarının koleksiyonu.
/// Maksimum performans ve vektör kalitesi için SwiftUI Shapes veya Paths olarak uygulanır.
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
            .contentShape(Rectangle()) // Tüm çerçeveyi tıklanabilir yapar
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
                    // Sol yarım küre
                    path.addEllipse(in: CGRect(x: w*0.1, y: h*0.2, width: w*0.4, height: h*0.6))
                    // Sağ yarım küre
                    path.addEllipse(in: CGRect(x: w*0.5, y: h*0.2, width: w*0.4, height: h*0.6))
                    // Üst eğri
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
                Path { path in
                    // Kafa dış hattı
                    path.addArc(
                        center: CGPoint(x: w/2, y: h*0.35),
                        radius: w*0.18,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360),
                        clockwise: false
                    )
                    
                    // Omuz dış hattı
                    path.move(to: CGPoint(x: w*0.18, y: h*0.82))
                    path.addQuadCurve(
                        to: CGPoint(x: w*0.82, y: h*0.82),
                        control: CGPoint(x: w/2, y: h*0.55)
                    )
                }
                .stroke(color, style: StrokeStyle(lineWidth: w*0.1, lineCap: .round, lineJoin: .round))
                
            case .trash:
                Path { path in
                    // Çöp kutusu dış hattı
                    // Kapak
                    path.move(to: CGPoint(x: w*0.15, y: h*0.28))
                    path.addLine(to: CGPoint(x: w*0.85, y: h*0.28))
                    
                    // Kapak Tutamacı
                    path.move(to: CGPoint(x: w*0.35, y: h*0.28))
                    path.addLine(to: CGPoint(x: w*0.35, y: h*0.15))
                    path.addLine(to: CGPoint(x: w*0.65, y: h*0.15))
                    path.addLine(to: CGPoint(x: w*0.65, y: h*0.28))
                    
                    // Gövde
                    path.move(to: CGPoint(x: w*0.25, y: h*0.28))
                    path.addLine(to: CGPoint(x: w*0.28, y: h*0.85))
                    path.addLine(to: CGPoint(x: w*0.72, y: h*0.85))
                    path.addLine(to: CGPoint(x: w*0.75, y: h*0.28))
                }
                .stroke(color, style: StrokeStyle(lineWidth: w*0.1, lineCap: .round, lineJoin: .round))
                
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
                    
                    // Meridyenler
                    Ellipse()
                        .stroke(color, lineWidth: w*0.08)
                        .frame(width: w*0.4, height: h)
                    
                    // Ekvator
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
                    
                    // Sayfalar
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
