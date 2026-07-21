import SwiftUI

struct TeleprompterView: View {
    @AppStorage("teleprompterText") private var teleprompterText: String = ""
    @AppStorage("teleprompterAutoIncludeVault") private var autoIncludeVaultNotes: Bool = true
    @Binding var isPresented: Bool
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    @ObservedObject private var audioService = DependencyContainer.shared.audioService
    @ObservedObject private var vaultService = VaultService.shared
    @State private var noteBlocks: [InterviewNoteBlock] = []
    @State private var activeBlockIDs: Set<String> = []
    @State private var primaryActiveBlockID: String? = nil
    @State private var focusModeEnabled: Bool = true
    @State private var autoFollowEnabled: Bool = true
    @State private var pendingAutoFocusTask: Task<Void, Never>? = nil
    @State private var lastFocusedTranscriptNormalized: String = ""
    @State private var lastAutoFocusAt: Date = .distantPast
    
    private var themeColor: Color {
        switch selectedTheme {
        case "Red":      return Color(red: 242/255, green: 78/255, blue: 78/255)
        case "Orange":   return Color.orange
        case "Blue":     return Color(red: 0.2, green: 0.6, blue: 1.0)
        case "Purple":   return Color(red: 0.7, green: 0.3, blue: 1.0)
        case "Green":    return Color(red: 0.2, green: 0.85, blue: 0.5)
        case "Graphite": return Color(white: 0.5)
        default:         return Color(red: 242/255, green: 78/255, blue: 78/255)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header / Drag Area
            HStack {
                HStack(spacing: 8) {
                    ZeroLoseIcon(type: .textbubble, color: themeColor, size: 14)
                    Text("INTERVIEW NOTES")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .kerning(1)
                }
                
                Spacer()

                liveStatusChip

                Button(action: { withAnimation(.easeInOut(duration: 0.16)) { focusModeEnabled.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: focusModeEnabled ? "text.alignleft" : "scope")
                            .font(.system(size: 10, weight: .semibold))
                        Text(focusModeEnabled ? "Edit" : "Focus")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.glassFill)
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.interactive)
                .pointerCursor()

                Button(action: { autoFollowEnabled.toggle() }) {
                    HStack(spacing: 5) {
                        Image(systemName: autoFollowEnabled ? "location.fill.viewfinder" : "location.viewfinder")
                            .font(.system(size: 9, weight: .semibold))
                        Text(autoFollowEnabled ? "Follow ON" : "Follow OFF")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(autoFollowEnabled ? themeColor : .white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background((autoFollowEnabled ? themeColor : Color.white).opacity(0.12))
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(autoFollowEnabled ? themeColor.opacity(0.4) : Color.glassStroke, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.interactive)
                .pointerCursor()
                
                Button(action: { isPresented = false }) {
                    ZeroLoseIcon(type: .xmark, color: Color.textSecondary, size: 12)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.12))
            
            Divider()
                .overlay(Color.glassStroke)
            
            if focusModeEnabled {
                focusModeView
            } else {
                editorView
            }
        }
        .background {
            Color.black.opacity(0.1)
                .ignoresSafeArea()
        }
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.glassStroke, lineWidth: 0.8)
        )
        .preferredColorScheme(.dark)
        .onAppear {
            rebuildNoteBlocks()
            focusModeEnabled = !noteBlocks.isEmpty
        }
        .onDisappear {
            pendingAutoFocusTask?.cancel()
            pendingAutoFocusTask = nil
        }
        .onChange(of: teleprompterText) { _, _ in
            rebuildNoteBlocks()
        }
        .onReceive(vaultService.$categories) { _ in
            rebuildNoteBlocks()
        }
        .onChange(of: audioService.lastVoiceTranscript) { _, newValue in
            scheduleAutoFocus(for: newValue)
        }
    }

    private var editorView: some View {
        ZStack {
            if teleprompterText.isEmpty {
                Text("Type or paste your interview notes here...")
                    .font(.system(size: fontSize + 1, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            
            TextEditor(text: $teleprompterText)
                .font(.system(size: fontSize + 1, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(8)
        }
        .background(Color.black.opacity(0.15))
    }

    @ViewBuilder
    private var focusModeView: some View {
        if noteBlocks.isEmpty {
            VStack(spacing: 10) {
                Text("No question blocks detected.")
                    .font(.system(size: fontSize + 1, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))

                Text("Paste interview notes in Edit mode. Question lines with '?' will be auto-indexed.")
                    .font(.system(size: fontSize - 1, weight: .regular, design: .rounded))
                    .foregroundColor(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.15))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(noteBlocks) { block in
                            noteBlockCard(
                                block,
                                isActive: activeBlockIDs.contains(block.id),
                                isPrimary: block.id == primaryActiveBlockID
                            )
                                .id(block.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color.black.opacity(0.15))
                .onAppear {
                    guard let primaryActiveBlockID else { return }
                    proxy.scrollTo(primaryActiveBlockID, anchor: .center)
                }
                .onChange(of: primaryActiveBlockID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private var liveStatusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(audioService.isListening ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(audioService.isListening ? "LIVE" : "IDLE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(audioService.isListening ? .green : .white.opacity(0.55))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background((audioService.isListening ? Color.green : Color.white).opacity(0.12))
        .cornerRadius(7)
    }

    @ViewBuilder
    private func noteBlockCard(_ block: InterviewNoteBlock, isActive: Bool, isPrimary: Bool) -> some View {
        let hasActiveSelection = !activeBlockIDs.isEmpty
        let shouldDim = hasActiveSelection && !isActive

        VStack(alignment: .leading, spacing: 8) {
            Text(block.question)
                .font(.system(size: fontSize + 0.5, weight: .bold, design: .rounded))
                .foregroundColor(isActive ? .white : (shouldDim ? .white.opacity(0.5) : .white.opacity(0.85)))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if !block.details.isEmpty {
                Text(block.details)
                    .font(.system(size: fontSize, weight: .medium, design: .rounded))
                    .foregroundColor(isActive ? .white.opacity(0.95) : (shouldDim ? .white.opacity(0.3) : .white.opacity(0.65)))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isPrimary
                        ? themeColor.opacity(0.18)
                        : (isActive ? themeColor.opacity(0.08) : Color.glassFill)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isPrimary
                        ? themeColor.opacity(0.8)
                        : (isActive ? themeColor.opacity(0.4) : Color.glassStroke),
                    lineWidth: isPrimary ? 1.4 : 0.8
                )
        )
    }

    private func rebuildNoteBlocks() {
        let manualBlocks = InterviewNoteBlockParser.parse(from: teleprompterText, sourcePrefix: "manual")
        let vaultBlocks = autoIncludeVaultNotes ? makeVaultBlocks() : []
        noteBlocks = mergeBlocks(manualBlocks: manualBlocks, vaultBlocks: vaultBlocks)
        activeBlockIDs = activeBlockIDs.intersection(Set(noteBlocks.map(\.id)))
        if let current = primaryActiveBlockID, !noteBlocks.contains(where: { $0.id == current }) {
            primaryActiveBlockID = activeBlockIDs.first
        }
    }

    private func mergeBlocks(
        manualBlocks: [InterviewNoteBlock],
        vaultBlocks: [InterviewNoteBlock]
    ) -> [InterviewNoteBlock] {
        var merged: [InterviewNoteBlock] = []
        var seenQuestionKeys = Set<String>()

        func appendUnique(_ block: InterviewNoteBlock) {
            let key = InterviewKnowledgeMatcher.normalize(block.question)
            guard !key.isEmpty else { return }
            guard seenQuestionKeys.insert(key).inserted else { return }
            merged.append(block)
        }

        manualBlocks.forEach(appendUnique)
        vaultBlocks.forEach(appendUnique)
        return merged
    }

    private func makeVaultBlocks() -> [InterviewNoteBlock] {
        vaultService.categories.flatMap { category in
            category.items.compactMap { item in
                let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty else { return nil }

                let answer = item.answerFinnish.trimmingCharacters(in: .whitespacesAndNewlines)
                let translation = item.translationTr.trimmingCharacters(in: .whitespacesAndNewlines)
                let details = answer.isEmpty ? translation : answer

                let recordKeyPoints = item.keyPoints
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let dynamicKeyPoints = InterviewNoteBlockParser.extractKeyPoints(from: question + "\n" + details)
                let keyPoints = Array(Set(recordKeyPoints + dynamicKeyPoints)).sorted()

                return InterviewNoteBlock(
                    id: "vault-\(category.id.uuidString)-\(item.id.uuidString)",
                    question: question,
                    details: details,
                    keyPoints: keyPoints,
                    questionLanguageCode: InterviewKnowledgeMatcher.dominantLanguageCode(for: question)
                )
            }
        }
    }

    private func scheduleAutoFocus(for transcript: String) {
        guard focusModeEnabled, autoFollowEnabled, audioService.isListening else { return }

        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedTranscript.count >= 8 else { return }
        guard !noteBlocks.isEmpty else { return }

        pendingAutoFocusTask?.cancel()
        pendingAutoFocusTask = Task { [cleanedTranscript] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                autoFocusBestMatch(for: cleanedTranscript)
            }
        }
    }

    private func autoFocusBestMatch(for transcript: String) {
        let now = Date()
        if now.timeIntervalSince(lastAutoFocusAt) < 0.32 {
            return
        }

        let normalizedTranscript = InterviewKnowledgeMatcher.normalize(transcript)
        guard normalizedTranscript != lastFocusedTranscriptNormalized else {
            return
        }

        let matches = resolveAutoFocusCandidates(for: transcript)
        guard !matches.isEmpty else { return }

        primaryActiveBlockID = matches[0].block.id
        activeBlockIDs = Set(matches.map(\.block.id))
        lastFocusedTranscriptNormalized = normalizedTranscript
        lastAutoFocusAt = now
    }

    private func resolveAutoFocusCandidates(for transcript: String) -> [AutoFocusCandidate] {
        guard !noteBlocks.isEmpty else { return [] }
        let transcriptLanguage = InterviewKnowledgeMatcher.dominantLanguageCode(for: transcript)

        let records = noteBlocks.map { block in
            InterviewKnowledgeRecord(
                category: "Interview Notes",
                question: block.question,
                answer: block.details,
                keyPoints: block.keyPoints,
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: block.question,
                    answer: block.details,
                    keyPoints: block.keyPoints,
                    category: "Interview Notes"
                )
            )
        }

        var bestScoreByBlockID: [String: Double] = [:]
        for fragment in transcriptFragments(from: transcript) {
            let fragmentMatches = InterviewKnowledgeMatcher.topMatches(
                query: fragment,
                records: records,
                maxResults: 3,
                minimumScore: 0.12
            )

            for match in fragmentMatches {
                guard let matchedBlock = block(for: match.record) else { continue }
                let adjustedScore = adjustedCandidateScore(
                    baseScore: match.score,
                    fragment: fragment,
                    transcriptLanguageCode: transcriptLanguage,
                    block: matchedBlock
                )
                guard adjustedScore > 0 else { continue }
                let existing = bestScoreByBlockID[matchedBlock.id] ?? 0
                bestScoreByBlockID[matchedBlock.id] = max(existing, adjustedScore)
            }
        }

        let threshold = adaptiveMatchThreshold(for: transcript)
        let sorted = bestScoreByBlockID
            .compactMap { blockID, score -> AutoFocusCandidate? in
                guard score >= threshold,
                      let block = noteBlocks.first(where: { $0.id == blockID }) else {
                    return nil
                }
                return AutoFocusCandidate(block: block, score: score)
            }
            .sorted { lhs, rhs in lhs.score > rhs.score }

        guard let top = sorted.first else { return [] }
        var selected: [AutoFocusCandidate] = [top]

        if sorted.count > 1 {
            let second = sorted[1]
            if second.score >= threshold + 0.02,
               (top.score - second.score) <= 0.14 {
                selected.append(second)
            }
        }

        return selected
    }

    private func adjustedCandidateScore(
        baseScore: Double,
        fragment: String,
        transcriptLanguageCode: String?,
        block: InterviewNoteBlock
    ) -> Double {
        var score = baseScore

        let overlapCount = InterviewKnowledgeMatcher.keywordOverlapCount(
            query: fragment,
            target: block.question
        )
        if overlapCount == 0 {
            return 0
        }
        score += min(0.12, Double(overlapCount) * 0.05)

        if let transcriptLanguageCode,
           let questionLanguageCode = block.questionLanguageCode,
           !transcriptLanguageCode.isEmpty,
           !questionLanguageCode.isEmpty,
           transcriptLanguageCode != questionLanguageCode {
            score *= 0.62
        }

        return min(score, 1.0)
    }

    private func transcriptFragments(from transcript: String) -> [String] {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var fragments: [String] = [cleaned]
        fragments.append(
            contentsOf: IntelligenceService
                .detectedQuestionSegments(cleaned)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "?.! \n\t")) }
                .filter { $0.count >= 5 }
        )

        let punctuationFragments = cleaned
            .components(separatedBy: CharacterSet(charactersIn: "?.!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 5 }
        fragments.append(contentsOf: punctuationFragments)

        let connectorTokens = [" ja ", " and ", " ve ", " sekä ", " tai ", " or "]
        for token in connectorTokens {
            if cleaned.lowercased().contains(token) {
                let parts = cleaned
                    .lowercased()
                    .components(separatedBy: token)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 5 }
                fragments.append(contentsOf: parts)
            }
        }

        var seen = Set<String>()
        return fragments.filter { fragment in
            let key = InterviewKnowledgeMatcher.normalize(fragment)
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func adaptiveMatchThreshold(for transcript: String) -> Double {
        let normalized = InterviewKnowledgeMatcher.normalize(transcript)
        let wordCount = normalized.split(separator: " ").count

        let askIntentTokens = [
            "kysy", "kysya", "kysyä", "kysymys", "kysymyksia", "kysymyksiä",
            "question", "questions", "ask", "soru", "sorular"
        ]
        if askIntentTokens.contains(where: { normalized.contains($0) }) {
            return 0.27
        }
        if wordCount <= 6 {
            return 0.31
        }
        return 0.34
    }

    private func block(for record: InterviewKnowledgeRecord) -> InterviewNoteBlock? {
        noteBlocks.first(where: {
            $0.question == record.question && $0.details == record.answer
        })
    }
}

private struct InterviewNoteBlock: Identifiable, Hashable {
    let id: String
    let question: String
    let details: String
    let keyPoints: [String]
    let questionLanguageCode: String?
}

private struct AutoFocusCandidate {
    let block: InterviewNoteBlock
    let score: Double
}

private enum InterviewNoteBlockParser {
    static func parse(from rawText: String, sourcePrefix: String = "manual") -> [InterviewNoteBlock] {
        let lines = rawText.components(separatedBy: .newlines)
        var blocks: [InterviewNoteBlock] = []
        var currentQuestion: String?
        var currentBodyLines: [String] = []
        var order = 0

        func flushCurrent() {
            guard let currentQuestion else { return }
            let details = currentBodyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedQuestion = InterviewKnowledgeMatcher.normalize(currentQuestion)
            let keyPoints = extractKeyPoints(from: currentQuestion + "\n" + details)
            let questionLanguageCode = InterviewKnowledgeMatcher.dominantLanguageCode(for: currentQuestion)
            let block = InterviewNoteBlock(
                id: "\(sourcePrefix)-\(order)-\(normalizedQuestion)",
                question: currentQuestion,
                details: details,
                keyPoints: keyPoints,
                questionLanguageCode: questionLanguageCode
            )
            blocks.append(block)
            order += 1
            currentBodyLines.removeAll(keepingCapacity: true)
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if isQuestionLine(line) {
                flushCurrent()
                currentQuestion = cleanedQuestionLine(from: line)
                continue
            }

            guard currentQuestion != nil else { continue }

            if isSeparatorLine(line) {
                currentBodyLines.append("")
                continue
            }

            currentBodyLines.append(rawLine)
        }

        flushCurrent()
        return blocks
    }

    private static func isQuestionLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        guard line.contains("?") else { return false }
        guard line.count <= 180 else { return false }

        let normalized = InterviewKnowledgeMatcher.normalize(line)
        guard !normalized.isEmpty else { return false }

        let blockedPrefixes = [
            "turkcesi", "turkcesi:", "fince cevap", "daha kisa", "daha net", "ornek", "example"
        ]
        if blockedPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return false
        }

        if isSeparatorLine(line) {
            return false
        }

        return true
    }

    private static func isSeparatorLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let separatorChars = CharacterSet(charactersIn: "-_—–=•*|")
        let filtered = line.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !filtered.isEmpty else { return false }
        let separatorCount = filtered.filter { separatorChars.contains($0) }.count
        return separatorCount >= max(8, Int(Double(filtered.count) * 0.8))
    }

    private static func cleanedQuestionLine(from line: String) -> String {
        let removedNumbering = line.replacingOccurrences(
            of: #"^\s*\d+\s*[\.\)]\s*"#,
            with: "",
            options: .regularExpression
        )
        return removedNumbering.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractKeyPoints(from text: String) -> [String] {
        let normalized = InterviewKnowledgeMatcher.normalize(text)
        let tokens = normalized.split(separator: " ").map(String.init)
        let filtered = tokens.filter { $0.count >= 4 }
        return Array(Set(filtered)).sorted().prefix(8).map { $0 }
    }
}
