import Foundation
import SwiftUI
import Combine

struct MessageContent: View, Equatable {
    let text: String
    let isUser: Bool
    let thinking: String?
    let isStreaming: Bool
    
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontDesign") private var fontDesignStr: String = "monospaced"
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    @State private var showThinking: Bool = false
    @State private var hasBeenExplicitlyToggled: Bool = false

    private var accent: Color {
        ThemeStore.accent(for: selectedTheme)
    }

    init(text: String, isUser: Bool, thinking: String?, isStreaming: Bool = false) {
        self.text = text
        self.isUser = isUser
        self.thinking = thinking
        self.isStreaming = isStreaming
    }
    
    var fontDesign: Font.Design {
        switch fontDesignStr {
        case "serif": return .serif
        case "rounded": return .rounded
        case "default": return .default
        default: return .monospaced
        }
    }
    
    var body: some View {
        // Keep the thinking header on the same visual line as the answer
        // content so the icon + "Thinking" label reads as part of the reply,
        // not as a separate block floating above it.
        VStack(alignment: .leading, spacing: 6) {
            if let thinking, !thinking.isEmpty, !isUser {
                ThinkingCollapsePanel(
                    thinking: thinking,
                    isExpanded: Binding(
                        get: { showThinking },
                        set: { newValue in
                            hasBeenExplicitlyToggled = true
                            showThinking = newValue
                        }
                    ),
                    fontSize: fontSize,
                    fontDesign: fontDesign
                )
            }
            let isPlaceholder = text.isEmpty || text == "Thinking..."
            let segments = isPlaceholder ? [] : MessageParser.parse(text, forUserMessage: isUser)
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment.type {
                case .heading(let level, let content):
                    Text(verbatim: content)
                        .font(headingFont(level))
                        .foregroundColor(isUser ? .black : .white)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let content):
                    Text(verbatim: content)
                        .font(.system(size: fontSize, weight: .regular, design: fontDesign))
                        .foregroundColor(isUser ? .black : .white.opacity(0.9))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows, fontSize: fontSize, isUser: isUser)
                case .code(let language, let code):
                    if language.lowercased() == "diagram",
                       let data = code.data(using: .utf8),
                       let diagramData = try? JSONDecoder().decode(DiagramData.self, from: data) {
                        SystemDiagramView(data: diagramData)
                    } else {
                        CodeBlockView(language: language, code: code, fontSize: fontSize)
                    }
                case .searchIndicator(let content):
                    HStack(spacing: 8) {
                        ZeroLoseIcon(type: .globe, color: accent, size: 14)
                        Text(content)
                            .font(.system(size: fontSize - 2, weight: .bold, design: .rounded))
                            .foregroundColor(accent)
                            .kerning(0.5)
                    }
                    .padding(.vertical, 4)
                case .slashCommand(let content):
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(accent)
                        Text(verbatim: content)
                            .font(.system(size: fontSize - 1, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.96))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("SLASH")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.14))
                            .cornerRadius(4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(accent.opacity(0.35), lineWidth: 1)
                    )
                    .cornerRadius(8)
                }
            }
        }
        .textSelection(.enabled)
        // While the model is still producing the answer the thinking panel is
        // held open so the user can watch reasoning live. Once the final answer
        // arrives it auto-collapses (unless the user manually expanded it).
        .onAppear {
            if (text.isEmpty || text == "Thinking...") && !(self.thinking ?? "").isEmpty {
                showThinking = true
            }
        }
        .onChange(of: text) { _, newValue in
            guard !hasBeenExplicitlyToggled else { return }
            if (newValue.isEmpty || newValue == "Thinking...") && !(self.thinking ?? "").isEmpty {
                showThinking = true
            } else if !newValue.isEmpty && !isStreaming {
                // Only collapse the thinking panel once the final answer is
                // fully present. While the agent is still producing text we
                // keep it open so the user can read the reasoning live.
                showThinking = false
            }
        }
        .onChange(of: thinking) { _, newThinking in
            guard !hasBeenExplicitlyToggled else { return }
            if !(newThinking ?? "").isEmpty && (text.isEmpty || text == "Thinking...") {
                showThinking = true
            }
        }
        .onChange(of: isStreaming) { _, newStreaming in
            guard !hasBeenExplicitlyToggled else { return }
            if newStreaming && !(self.thinking ?? "").isEmpty {
                showThinking = true
            } else if !newStreaming && !(self.thinking ?? "").isEmpty {
                showThinking = false
            }
        }
    }

    static func == (lhs: MessageContent, rhs: MessageContent) -> Bool {
        lhs.text == rhs.text &&
            lhs.isUser == rhs.isUser &&
            lhs.thinking == rhs.thinking &&
            lhs.isStreaming == rhs.isStreaming
    }
    
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: fontSize + 6, weight: .bold, design: .rounded)
        case 2: return .system(size: fontSize + 4, weight: .bold, design: .rounded)
        case 3: return .system(size: fontSize + 2, weight: .bold, design: .rounded)
        default: return .system(size: fontSize + 1, weight: .bold, design: .rounded)
        }
    }
}


/// A collapsible, model-agnostic "thinking" panel.
///
/// Any provider that surfaces a reasoning trace (DeepSeek `reasoning_content`,
/// OpenAI-compatible `delta.reasoning_content`, etc.) is streamed into
/// `ChatMessage.thinking`. This panel renders it collapsed by default and lets
/// the user expand / collapse it per message.
struct ThinkingCollapsePanel: View {
    let thinking: String
    @Binding var isExpanded: Bool
    let fontSize: Double
    let fontDesign: Font.Design

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.brandPrimary)
                    Text("Thinking")
                        .font(.system(size: fontSize - 2, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary.opacity(0.85))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                }
                .padding(.horizontal, 0)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(verbatim: thinking)
                    .font(.system(size: fontSize - 1, weight: .regular, design: fontDesign))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }
}


struct CodeBlockView: View {
    let language: String
    let code: String
    let fontSize: Double
    @State private var isCopied = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                Spacer()
                
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isCopied = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.15))
            
            // Code Content
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: max(10, fontSize - 2), design: .monospaced))
                    .foregroundColor(Color(red: 0.8, green: 0.8, blue: 0.8))
                    .padding(12)
                    .frame(minWidth: 400, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(white: 0.1))
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let fontSize: Double
    let isUser: Bool
    
    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }
    
    private var normalizedHeaders: [String] {
        normalized(headers, to: columnCount)
    }
    
    private var normalizedRows: [[String]] {
        rows.map { normalized($0, to: columnCount) }
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                rowView(normalizedHeaders, isHeader: true)
                ForEach(Array(normalizedRows.enumerated()), id: \.offset) { _, row in
                    rowView(row, isHeader: false)
                }
            }
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func rowView(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(verbatim: cell)
                    .font(.system(size: max(11, fontSize - 1), weight: isHeader ? .bold : .regular, design: .rounded))
                    .foregroundColor(isHeader ? .white : (isUser ? .black : .white.opacity(0.9)))
                    .frame(minWidth: 130, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isHeader ? Color.brandPrimary.opacity(0.25) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
    
    private func normalized(_ values: [String], to count: Int) -> [String] {
        guard count > 0 else { return values }
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: "", count: count - values.count)
    }
}

// MARK: - Parser Logic

struct MessageSegment {
    let type: SegmentType
    
    enum SegmentType {
        case heading(level: Int, text: String)
        case paragraph(String)
        case table(headers: [String], rows: [[String]])
        case code(language: String, code: String)
        case searchIndicator(String)
        case slashCommand(String)
    }
}

struct MessageCopyButton: View {
    let text: String
    @State private var isCopied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                Text(isCopied ? "Copied" : "Copy")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .cornerRadius(6)
        }
        .buttonStyle(.interactive)
        .pointerCursor()
        .help("Copy message")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isCopied = false
        }
    }
}

struct MessageBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(.brandPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.brandPrimary.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.brandPrimary.opacity(0.25), lineWidth: 0.5)
            )
            .cornerRadius(6)
    }
}

struct MessageAIButton: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("AI")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(disabled ? .white.opacity(0.45) : .white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.brandPrimary.opacity(disabled ? 0.08 : 0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.brandPrimary.opacity(disabled ? 0.16 : 0.3), lineWidth: 0.5)
            )
            .cornerRadius(6)
        }
        .buttonStyle(.interactive)
        .pointerCursor()
        .disabled(disabled)
        .help("Re-answer this question with AI reasoning")
    }
}

class MessageParser {
    static func parse(_ text: String, forUserMessage: Bool = false) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        let lines = text.components(separatedBy: .newlines)
        
        var inCodeBlock = false
        var currentBlockLanguage = ""
        var currentBlockContent = ""
        var currentTextContent = ""
        
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeBlock {
                    // End of block
                    segments.append(MessageSegment(type: .code(language: currentBlockLanguage, code: currentBlockContent.trimmingCharacters(in: .newlines))))
                    currentBlockContent = ""
                    inCodeBlock = false
                } else {
                    // Start of block
                    // Flush existing text
                    if !currentTextContent.isEmpty {
                        segments.append(contentsOf: parseTextBlock(currentTextContent, forUserMessage: forUserMessage))
                        currentTextContent = ""
                    }
                    
                    let suffix = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                    currentBlockLanguage = String(suffix).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
            } else {
                if inCodeBlock {
                    currentBlockContent += line + "\n"
                } else if line.contains("[WEB_SEARCH]") {
                    // Flush existing text
                    if !currentTextContent.isEmpty {
                        segments.append(contentsOf: parseTextBlock(currentTextContent, forUserMessage: forUserMessage))
                        currentTextContent = ""
                    }
                    let content = line.replacingOccurrences(of: "[WEB_SEARCH]", with: "").trimmingCharacters(in: .whitespaces)
                    segments.append(MessageSegment(type: .searchIndicator(content)))
                } else if line.contains("[SLASH_COMMAND]") {
                    if !currentTextContent.isEmpty {
                        segments.append(contentsOf: parseTextBlock(currentTextContent, forUserMessage: forUserMessage))
                        currentTextContent = ""
                    }
                    let content = line.replacingOccurrences(of: "[SLASH_COMMAND]", with: "").trimmingCharacters(in: .whitespaces)
                    segments.append(MessageSegment(type: .slashCommand(content)))
                } else {
                    currentTextContent += line + "\n"
                }
            }
        }
        
        // Flush remaining text
        if !currentTextContent.isEmpty {
            segments.append(contentsOf: parseTextBlock(currentTextContent, forUserMessage: forUserMessage))
        }
        // If code block wasn't closed, flush it as text or code?
        if !currentBlockContent.isEmpty {
             segments.append(MessageSegment(type: .code(language: currentBlockLanguage, code: currentBlockContent.trimmingCharacters(in: .newlines))))
        }
        
        return segments
    }
    
    private static func parseTextBlock(_ text: String, forUserMessage: Bool) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        let lines = text.components(separatedBy: .newlines)
        var paragraphBuffer: [String] = []
        var index = 0
        
        func flushParagraph() {
            let paragraph = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else {
                paragraphBuffer.removeAll()
                return
            }
            let normalizedParagraph = normalizeInlineMarkdown(paragraph)
            let paragraphs = forUserMessage ? [normalizedParagraph] : splitLongParagraphForReadability(normalizedParagraph)
            for item in paragraphs {
                segments.append(MessageSegment(type: .paragraph(item)))
            }
            paragraphBuffer.removeAll()
        }
        
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            
            if let heading = parseHeading(from: trimmed) {
                flushParagraph()
                segments.append(MessageSegment(type: .heading(level: heading.level, text: normalizeInlineMarkdown(heading.text))))
                index += 1
                continue
            }
            
            if index + 1 < lines.count {
                let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if looksLikeTableHeader(line) && isTableDivider(nextTrimmed) {
                    flushParagraph()
                    let headers = parseTableRow(line).map { normalizeInlineMarkdown($0) }
                    index += 2 // Skip header + separator
                    
                    var rows: [[String]] = []
                    while index < lines.count {
                        let rowLine = lines[index]
                        let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                        
                        if rowTrimmed.isEmpty || !rowLine.contains("|") {
                            break
                        }
                        if isTableDivider(rowTrimmed) {
                            index += 1
                            continue
                        }
                        
                        let rowValues = parseTableRow(rowLine).map { normalizeInlineMarkdown($0) }
                        if rowValues.isEmpty {
                            break
                        }
                        rows.append(rowValues)
                        index += 1
                    }
                    
                    if !headers.isEmpty {
                        segments.append(MessageSegment(type: .table(headers: headers, rows: rows)))
                    }
                    continue
                }
            }
            
            paragraphBuffer.append(line)
            index += 1
        }
        
        flushParagraph()
        return segments
    }

    private static func splitLongParagraphForReadability(_ paragraph: String) -> [String] {
        guard paragraph.count >= 220 else { return [paragraph] }
        guard !paragraph.contains("\n"), !paragraph.contains("|"), !paragraph.contains("```") else { return [paragraph] }

        let sentenceBreakRegex = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+"#, options: [])
        guard let sentenceBreakRegex else { return [paragraph] }

        let nsRange = NSRange(paragraph.startIndex..<paragraph.endIndex, in: paragraph)
        let matches = sentenceBreakRegex.matches(in: paragraph, options: [], range: nsRange)
        guard !matches.isEmpty else { return [paragraph] }

        var sentences: [String] = []
        var start = paragraph.startIndex
        for match in matches {
            guard let splitRange = Range(match.range, in: paragraph) else { continue }
            let sentence = paragraph[start..<splitRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(String(sentence))
            }
            start = splitRange.upperBound
        }
        let tail = paragraph[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(String(tail))
        }

        guard sentences.count >= 4 else { return [paragraph] }

        var groupedParagraphs: [String] = []
        var bucket: [String] = []
        for sentence in sentences {
            bucket.append(sentence)
            if bucket.count == 2 {
                groupedParagraphs.append(bucket.joined(separator: " "))
                bucket.removeAll(keepingCapacity: true)
            }
        }
        if !bucket.isEmpty {
            groupedParagraphs.append(bucket.joined(separator: " "))
        }

        return groupedParagraphs.isEmpty ? [paragraph] : groupedParagraphs
    }
    
    private static func parseHeading(from line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level > 0 && level <= 6 else { return nil }
        
        let remainder = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return (level, remainder)
    }
    
    private static func looksLikeTableHeader(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return parseTableRow(line).count >= 2
    }
    
    private static func parseTableRow(_ line: String) -> [String] {
        var normalized = line.trimmingCharacters(in: .whitespaces)
        guard normalized.contains("|") else { return [] }
        
        if normalized.hasPrefix("|") {
            normalized.removeFirst()
        }
        if normalized.hasSuffix("|") {
            normalized.removeLast()
        }
        
        return normalized
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
    
    private static func isTableDivider(_ line: String) -> Bool {
        let cells = parseTableRow(line)
        guard !cells.isEmpty else { return false }
        
        for cell in cells {
            let dashCount = cell.filter { $0 == "-" }.count
            let remainder = cell
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
                .trimmingCharacters(in: .whitespaces)
            
            if dashCount < 3 || !remainder.isEmpty {
                return false
            }
        }
        
        return true
    }
    
    private static func normalizeInlineMarkdown(_ text: String) -> String {
        var normalized = text
        normalized = normalized.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: "**", with: "")
        normalized = normalized.replacingOccurrences(of: "__", with: "")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


/// Sohbette ajanın çalıştırdığı bir aracı (komut) görünür bir kart olarak gösterir.
/// Çalışırken shimmer animasyonu akar; bitince "Başarılı" + çıktı; hata olursa kırmızı.
struct MessagingToolRunCard: View {
    let run: ChatMessage.ToolRun
    @State private var animateShimmer = false
    @State private var dotCount = 0
    @State private var expanded = false
    private let dotTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var isRunning: Bool {
        if case .running = run.status { return true }
        return false
    }

    /// Çıktı bu eşiği aşarsa kart varsayılan olarak daraltılmış gösterilir.
    private var isLongOutput: Bool {
        run.output.count > 700
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(run.command)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                statusBadge
            }

            if isRunning {
                HStack(spacing: 6) {
                    ZeroLoseIcon(type: .sparkles, color: .brandPrimary, size: 12)
                        .symbolEffect(.pulse)
                    Text("Komut çalışıyor" + String(repeating: ".", count: dotCount))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .overlay(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.5), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 70)
                    .offset(x: animateShimmer ? 160 : -70)
                    .blendMode(.plusLighter)
                )
                .clipped()
            } else if !run.output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if run.output.hasPrefix("Directory:") || run.output.contains("\n") {
                        if isLongOutput {
                            shouldExpandToggle
                        }
                        Text(displayOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .lineLimit(expanded ? nil : 6)
                    } else {
                        Text(displayOutput)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.85))
                            .textSelection(.enabled)
                            .lineLimit(expanded ? nil : 3)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isRunning ? Color.brandPrimary.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .onAppear {
            if isRunning {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    animateShimmer = true
                }
            }
        }
        .onReceive(dotTimer) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                dotCount = (dotCount + 1) % 4
            }
        }
    }

    /// Uzun çıktılarda daralt/ genişlet düğmesi.
    @ViewBuilder
    private var shouldExpandToggle: some View {
        HStack {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
            Text(expanded ? "Daralt" : "\(run.output.count) karakter göster")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.brandPrimary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                expanded.toggle()
            }
        }
    }

    /// Daraltılmışken çıktının ilk kısmını gösterir.
    private var displayOutput: String {
        guard isLongOutput, !expanded else { return run.output }
        return String(run.output.prefix(500)) + (run.output.count > 500 ? "\n…" : "")
    }

    private var iconName: String {
        switch run.kind {
        case "shell": return "terminal"
        case "web_search": return "globe"
        case "applescript": return "applescript"
        case "file": return "folder"
        case "computer": return "cursorarrow.click.2"
        case "system_status": return "gauge.with.dots.needle.67percent"
        default: return "gearshape"
        }
    }

    private var iconColor: Color {
        if case .error = run.status { return .red }
        return isRunning ? .brandPrimary : .secondary
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch run.status {
        case .running:
            HStack(spacing: 4) {
                Circle().fill(Color.brandPrimary).frame(width: 6, height: 6)
                Text("Çalışıyor")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.brandPrimary)
            }
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Başarılı")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            }
        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                Text(message.isEmpty ? "Hata" : "Hata")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.red)
            }
        }
    }
}
