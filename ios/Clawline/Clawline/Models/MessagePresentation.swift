//
//  MessagePresentation.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import CryptoKit
import OSLog
import UIKit

struct TableModel: Equatable {
    struct Column: Equatable {
        let alignment: ColumnAlignment
    }

    struct Cell: Equatable {
        let attributed: AttributedString
        let intrinsicWidth: CGFloat
        let plainText: String
        let isEmpty: Bool
    }

    struct Row: Equatable, Identifiable {
        let id: UUID
        let cells: [Cell]
    }

    let columns: [Column]
    let header: [Cell]?
    let rows: [Row]
    let messageID: String
    let rowOffset: Int

    func appendingRow(_ row: [Cell]) -> TableModel {
        guard row.count == columns.count else { return self }
        var updatedRows = rows
        let identifier = TableModel.makeRowIdentifier(
            messageID: messageID,
            rowIndex: rowOffset + updatedRows.count,
            cells: row.map(\.plainText)
        )
        updatedRows.append(Row(id: identifier, cells: row))
        return TableModel(
            columns: columns,
            header: header,
            rows: updatedRows,
            messageID: messageID,
            rowOffset: rowOffset
        )
    }
}

enum ColumnAlignment: Equatable {
    case leading
    case center
    case trailing

    init(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
        case (true, true):
            self = .center
        case (false, true):
            self = .trailing
        case (true, false):
            self = .leading
        default:
            self = .leading
        }
    }
}

struct StreamingTableParseState {
    private(set) var lastUpdatedAt: Date?
    private(set) var pendingStartIndex: Int?
    private(set) var pendingStartedAt: Date?

    mutating func markStreamingUpdate() {
        lastUpdatedAt = Date()
    }

    mutating func beginPending(at startIndex: Int) {
        pendingStartIndex = startIndex
        pendingStartedAt = Date()
    }

    mutating func clearPending() {
        pendingStartIndex = nil
        pendingStartedAt = nil
    }

    mutating func reset() {
        lastUpdatedAt = nil
        clearPending()
    }

    var isDirty: Bool {
        lastUpdatedAt != nil || pendingStartIndex != nil
    }
}

struct MessagePresentation: Equatable {
    let parts: [MessagePart]
    let wordCount: Int
    let hasTextualContent: Bool
    let isEmojiOnly: Bool
    let hasMediaOnly: Bool
    /// Unique http/https URLs detected in the message text, in first-seen order.
    /// Used for sizing (single-link wide bubbles) and link-card rendering independent of preview availability.
    let detectedURLs: [URL]
    /// Number of URL occurrences detected (including duplicates).
    let detectedURLCount: Int
    /// True when the message contains exactly one URL occurrence (http/https) in its text content.
    /// This is used for sizing/routing decisions even if we don't render a preview card.
    let hasSingleURL: Bool
}

enum MessagePart: Equatable {
    case text(String)
    case markdown(String)
    case table(TableModel)
    case code(language: String?, code: String)
    case linkPreview(URL)
    case image(Attachment)
    case gallery([Attachment])
    case file(Attachment)
    case terminalSession(TerminalSessionDescriptor)
    case interactiveHTML(InteractiveHTMLDescriptor)
    case inlineEmoji(String)
}

/// Content types that can render without bubble chrome when they are the only element.
enum ChromelessStyle: Equatable {
    case image
    case table
    case codeBlock
    case emoji  // 1-2 emojis only, centered with double font size
    // case blockquote (future)
}

extension MessagePart {
    private static let chromelessIgnorableCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}")
        return set
    }()

    var isTextual: Bool {
        switch self {
        case .text, .markdown, .table, .inlineEmoji, .code:
            return true
        case .linkPreview:
            return true
        case .image, .gallery, .file, .terminalSession, .interactiveHTML:
            return false
        }
    }

    var isChromelessIgnorable: Bool {
        switch self {
        case .text(let text), .markdown(let text):
            return text.trimmingCharacters(in: Self.chromelessIgnorableCharacters).isEmpty
        default:
            return false
        }
    }
}

extension MessagePresentation {
    /// Returns the chromeless style if this message qualifies for chromeless rendering.
    /// A message qualifies when it contains exactly one visible element of a supported type.
    var chromelessStyle: ChromelessStyle? {
        let chromelessCandidates = parts.filter { !$0.isChromelessIgnorable }
        guard chromelessCandidates.count == 1, let candidate = chromelessCandidates.first else { return nil }

        switch candidate {
        case .image:
            return .image
        case .gallery:
            return .image
        case .table:
            return .table
        case .code:
            return .codeBlock
        case .inlineEmoji(let value):
            // Only chromeless if 1-2 emojis
            let emojiCount = value.unicodeScalars.filter { $0.properties.isEmoji }.count
            return emojiCount >= 1 && emojiCount <= 2 ? .emoji : nil
        default:
            return nil
        }
    }

    /// Whether this message should render without bubble chrome.
    var isChromeless: Bool {
        chromelessStyle != nil
    }
}

enum MessagePresentationBuilder {
    private static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MarkdownTable")
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    private static let separatorPattern = try! NSRegularExpression(
        pattern: #"^\s*\|?(\s*:?-{3,}:?\s*\|)+\s*$"#,
        options: []
    )
    private static let maxColumns = 40
    private static let maxCellsPerMessage = 400
    private static let perTableBudget: TimeInterval = 0.4
    private static let perCellBudget: TimeInterval = 0.2
    private static let maxMarkdownNestingDepth = 5
    private static let pendingLineLimit = 6
    private static let pendingTimeLimit: TimeInterval = 1.0

    static func build(
        from message: Message,
        metrics: ChatFlowTheme.Metrics,
        streamingState: inout StreamingTableParseState
    ) -> MessagePresentation {
        let segments = Segmenter.split(message.content)
        let terminalAllowed = SessionKey.isClawlinePersonalDM(message.sessionKey)
        let terminalAttachments = terminalAllowed ? terminalSessionAttachments(from: message.attachments) : []
        let interactiveAttachments = interactiveHTMLAttachments(from: message.attachments)
        let imageAttachments = imageAttachments(from: message.attachments)
        let fileAttachments = fileAttachments(from: message.attachments)
        let hasAttachments = !terminalAttachments.isEmpty || !interactiveAttachments.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty
        var parts: [MessagePart] = []
        var collectedPlainText: [String] = []
        var hasTextual = false
        var emojiOnly = true
        var totalTableCells = 0
        var hasBlockedParts = hasAttachments
        var detectedURLOccurrences: [URL] = []
        let suppressTextForFiles = shouldSuppressTextForFileAttachments(
            content: message.content,
            fileAttachments: fileAttachments
        )

        // Terminal sessions are encoded as a special document attachment; intercept them early so
        // they never fall through to the generic file attachment UI.
        //
        // Policy: DM-only. If a provider violates this, we ignore and let it render as a generic file.
        var decodedTerminalAttachmentIDs: Set<String> = []
        for attachment in terminalAttachments {
            if let descriptor = decodeTerminalSessionDescriptor(from: attachment) {
                parts.append(.terminalSession(descriptor))
                hasBlockedParts = true
                decodedTerminalAttachmentIDs.insert(attachment.id)
            }
        }

        // Interactive HTML bubbles are encoded as a special document attachment; intercept them
        // so they never fall through to the generic file attachment UI.
        var decodedInteractiveAttachmentIDs: Set<String> = []
        for attachment in interactiveAttachments {
            if let descriptor = decodeInteractiveHTMLDescriptor(from: attachment) {
                parts.append(.interactiveHTML(descriptor))
                hasBlockedParts = true
                decodedInteractiveAttachmentIDs.insert(attachment.id)
            }
        }

        if message.streaming {
            streamingState.markStreamingUpdate()
        }

        for segment in segments {
            if suppressTextForFiles { break }
            switch segment.kind {
            case .code(let language):
                parts.append(.code(language: language, code: segment.content))
                hasBlockedParts = true
                emojiOnly = false
            case .text:
                detectedURLOccurrences.append(contentsOf: extractURLs(from: segment.content))
                processTextSegment(
                    segment.content,
                    message: message,
                    metrics: metrics,
                    hasAttachments: hasAttachments,
                    parts: &parts,
                    collectedPlainText: &collectedPlainText,
                    hasTextual: &hasTextual,
                    emojiOnly: &emojiOnly,
                    totalTableCells: &totalTableCells,
                    hasBlockedParts: &hasBlockedParts,
                    streamingState: &streamingState
                )
            }
        }

        // Preserve first-seen order for UI, but provide a stable unique list for sizing/cards.
        var uniqueURLs: [URL] = []
        var seen: Set<String> = []
        uniqueURLs.reserveCapacity(detectedURLOccurrences.count)
        for url in detectedURLOccurrences {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                uniqueURLs.append(url)
            }
        }

        if !hasBlockedParts,
           detectedURLOccurrences.count == 1 {
            parts.append(.linkPreview(detectedURLOccurrences[0]))
        }

        // Flynn #28: "single link" means exactly one detected URL occurrence, not "one unique URL repeated".
        let hasSingleURL = detectedURLOccurrences.count == 1

        var hasMedia = false
        if !imageAttachments.isEmpty {
            hasMedia = true
            if imageAttachments.count == 1 {
                parts.append(.image(imageAttachments[0]))
            } else {
                parts.append(.gallery(imageAttachments))
            }
        }
        if !fileAttachments.isEmpty {
            for attachment in fileAttachments {
                if decodedTerminalAttachmentIDs.contains(attachment.id) || decodedInteractiveAttachmentIDs.contains(attachment.id) {
                    continue
                }
                parts.append(.file(attachment))
            }
        }
        let hasTerminal = parts.contains(where: { if case .terminalSession = $0 { return true }; return false })

        let plainWordCount = stripMarkdownMarkers(from: collectedPlainText
            .joined(separator: " "))
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count

        return MessagePresentation(
            parts: parts,
            wordCount: plainWordCount,
            hasTextualContent: hasTextual,
            isEmojiOnly: emojiOnly && hasTextual,
            hasMediaOnly: !hasTerminal && hasMedia && !hasTextual,
            detectedURLs: uniqueURLs,
            detectedURLCount: detectedURLOccurrences.count,
            hasSingleURL: hasSingleURL
        )
    }

    private static func processTextSegment(
        _ text: String,
        message: Message,
        metrics: ChatFlowTheme.Metrics,
        hasAttachments: Bool,
        parts: inout [MessagePart],
        collectedPlainText: inout [String],
        hasTextual: inout Bool,
        emojiOnly: inout Bool,
        totalTableCells: inout Int,
        hasBlockedParts: inout Bool,
        streamingState: inout StreamingTableParseState
    ) {
        let lines = text.components(separatedBy: CharacterSet.newlines)
        var index = 0

        while index < lines.count {
            if totalTableCells >= maxCellsPerMessage {
                break
            }

            let trimmedLine = lines[index].trimmingCharacters(in: .whitespaces)
            // Providers/models sometimes insert invisible scalars (e.g. ZWSP) around/adjacent to fences.
            // Normalizing those away makes our fence fallback resilient (Flynn #50).
            let fenceCheckLine = Segmenter.normalizedForFenceDetection(trimmedLine)
            // Fallback: handle fenced code blocks that leak into text segments.
            // Observed when a fence follows a colon-terminated paragraph.
            if fenceCheckLine.hasPrefix("```") {
                let languageSpec = fenceCheckLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let language = languageSpec.isEmpty ? nil : String(languageSpec)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let line = lines[index]
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let fenceCheck = Segmenter.normalizedForFenceDetection(trimmed)
                    if fenceCheck.hasPrefix("```")
                        && fenceCheck.dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty {
                        index += 1
                        break
                    }
                    codeLines.append(line)
                    index += 1
                }
                parts.append(.code(language: language, code: codeLines.joined(separator: "\n")))
                hasTextual = true
                emojiOnly = false
                hasBlockedParts = true
                continue
            }
            if let result = parseTable(
                lines: lines,
                startIndex: index,
                message: message,
                metrics: metrics,
                totalTableCells: &totalTableCells
            ) {
                switch result {
                case .render(let model, let consumed, let plainText):
                    parts.append(.table(model))
                    collectedPlainText.append(contentsOf: plainText)
                    hasTextual = true
                    emojiOnly = false
                    hasBlockedParts = true
                    streamingState.clearPending()
                    index = consumed
                    continue
                case .pending:
                    if message.streaming {
                        if shouldBufferTableCandidate(
                            startIndex: index,
                            lines: lines,
                            streamingState: &streamingState
                        ) {
                            return
                        }
                    } else if streamingState.pendingStartIndex == index {
                        streamingState.clearPending()
                    }
                }
            } else if streamingState.pendingStartIndex == index {
                streamingState.clearPending()
            }

            index += 1
            guard !trimmedLine.isEmpty else { continue }
            if hasAttachments, isAttachmentSummaryLine(trimmedLine) {
                continue
            }

            collectedPlainText.append(trimmedLine)

            if isEmojiOnly(trimmedLine) {
                parts.append(.inlineEmoji(trimmedLine))
                emojiOnly = emojiOnly && true
                hasTextual = true
                continue
            }

            emojiOnly = false
            if looksLikeMarkdown(trimmedLine) {
                parts.append(.markdown(trimmedLine))
                hasTextual = true
            } else {
                parts.append(.text(trimmedLine))
                hasTextual = true
            }
        }

    }

    private static func isAttachmentSummaryLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("attachment:") || lower.hasPrefix("attachments:")
    }

    private enum TableParseOutcome {
        case render(model: TableModel, consumed: Int, plainText: [String])
        case pending
    }

    private static func parseTable(
        lines: [String],
        startIndex: Int,
        message: Message,
        metrics: ChatFlowTheme.Metrics,
        totalTableCells: inout Int
    ) -> TableParseOutcome? {
        guard startIndex < lines.count else { return nil }
        let headerLine = lines[startIndex]
        guard headerLine.contains("|") else { return nil }

        let headerTrimmed = headerLine.trimmingCharacters(in: .whitespaces)
        let headerHasLeadingPipe = headerTrimmed.hasPrefix("|")
        if !headerHasLeadingPipe && isAdjacentToListOrCode(lines: lines, headerIndex: startIndex) {
            return nil
        }

        let headerCells = splitRow(headerLine)
        let columnCount = headerCells.count
        guard columnCount >= 1 else {
            logTableFailure(
                phase: "parse",
                reason: "column_underflow",
                message: message,
                rowCount: 0,
                columnCount: columnCount
            )
            return nil
        }
        guard columnCount <= maxColumns else {
            logTableFailure(
                phase: "parse",
                reason: "column_limit",
                message: message,
                rowCount: 0,
                columnCount: columnCount
            )
            return nil
        }

        guard let separatorIdx = nextNonEmptyLineIndex(lines: lines, start: startIndex + 1) else {
            return nil
        }
        let canonicalSeparator = canonicalizedSeparator(lines[separatorIdx], expectedColumns: columnCount)
        guard isValidSeparator(canonicalSeparator) else { return nil }

        var alignmentTokens = splitRow(canonicalSeparator)
        if alignmentTokens.count != columnCount {
            alignmentTokens = Array(repeating: "---", count: columnCount)
        }
        let alignments = alignmentTokens.map { ColumnAlignment(token: $0) }

        guard let rowStartIdx = nextNonEmptyLineIndex(lines: lines, start: separatorIdx + 1) else {
            return .pending
        }

        var rows: [[String]] = []
        var cursor = rowStartIdx
        var plainText: [String] = []
        let tableStart = Date()
        let rowOffset = 0
        var exceededTableBudget = false
        var totalCellLimitHit = false
        var rowMismatch = false

        while cursor < lines.count {
            let candidate = lines[cursor]
            if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            guard candidate.contains("|") else { break }
            let cells = splitRow(candidate)
            if cells.count != columnCount {
                rowMismatch = true
                break
            }
            rows.append(cells)
            cursor += 1
            if rows.count * columnCount + totalTableCells >= maxCellsPerMessage {
                totalCellLimitHit = true
                break
            }
            let elapsed = Date().timeIntervalSince(tableStart)
            if elapsed > perTableBudget {
                exceededTableBudget = true
                break
            }
        }

        guard !rows.isEmpty else {
            return .pending
        }

        guard totalTableCells + headerCells.count <= maxCellsPerMessage else {
            logTableFailure(
                phase: "parse",
                reason: "cell_limit",
                message: message,
                rowCount: rows.count,
                columnCount: columnCount
            )
            return nil
        }

        var headerCellsModels: [TableModel.Cell] = []
        for header in headerCells {
            let cell = makeCell(from: header, metrics: metrics, messageID: message.id)
            headerCellsModels.append(cell)
            plainText.append(cell.plainText)
        }
        totalTableCells += headerCellsModels.count

        var bodyRows: [TableModel.Row] = []
        var rowIndex = 0
        var stopEarly = false
        var cellBudgetExceeded = false

        for row in rows {
            if stopEarly { break }
            var cellModels: [TableModel.Cell] = []
            var rowPlainTexts: [String] = []
            for cell in row {
                if totalTableCells >= maxCellsPerMessage {
                    stopEarly = true
                    totalCellLimitHit = true
                    break
                }
                let start = Date()
                let parsedCell = makeCell(from: cell, metrics: metrics, messageID: message.id)
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > perCellBudget {
                    stopEarly = true
                    cellBudgetExceeded = true
                    break
                }
                cellModels.append(parsedCell)
                rowPlainTexts.append(parsedCell.plainText)
                totalTableCells += 1
            }

            guard cellModels.count == columnCount else {
                break
            }

            plainText.append(contentsOf: rowPlainTexts)
            let uuid = TableModel.makeRowIdentifier(messageID: message.id, rowIndex: rowOffset + rowIndex, cells: row)
            bodyRows.append(TableModel.Row(id: uuid, cells: cellModels))
            rowIndex += 1
        }

        if rowMismatch {
            logTableFailure(
                phase: "parse",
                reason: "row_column_mismatch",
                message: message,
                rowCount: rows.count,
                columnCount: columnCount
            )
        }

        if exceededTableBudget {
            logTableFailure(
                phase: "parse",
                reason: "table_budget",
                message: message,
                rowCount: rows.count,
                columnCount: columnCount
            )
        }

        if totalCellLimitHit {
            logTableFailure(
                phase: "parse",
                reason: "cell_limit",
                message: message,
                rowCount: rows.count,
                columnCount: columnCount
            )
        }

        if cellBudgetExceeded {
            logTableFailure(
                phase: "render",
                reason: "cell_budget",
                message: message,
                rowCount: bodyRows.count,
                columnCount: columnCount
            )
        }

        guard !bodyRows.isEmpty else {
            logTableFailure(
                phase: "parse",
                reason: "no_renderable_rows",
                message: message,
                rowCount: 0,
                columnCount: columnCount
            )
            return nil
        }

        let model = TableModel(
            columns: alignments.map { TableModel.Column(alignment: $0) },
            header: headerCellsModels,
            rows: bodyRows,
            messageID: message.id,
            rowOffset: rowOffset
        )

        return .render(model: model, consumed: cursor, plainText: plainText)
    }

    private static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaping = false
        var inCode = false

        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if character == "`" {
                inCode.toggle()
                current.append(character)
                continue
            }
            if character == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }

        cells.append(current.trimmingCharacters(in: .whitespaces))
        if let first = cells.first, first.isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.isEmpty {
            cells.removeLast()
        }
        return cells
    }

    private static func shouldBufferTableCandidate(
        startIndex: Int,
        lines: [String],
        streamingState: inout StreamingTableParseState
    ) -> Bool {
        let lineCount = max(lines.count - startIndex, 0)
        if streamingState.pendingStartIndex != startIndex || streamingState.pendingStartedAt == nil {
            streamingState.beginPending(at: startIndex)
            return true
        }
        let now = Date()
        if let startedAt = streamingState.pendingStartedAt {
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed < pendingTimeLimit && lineCount < pendingLineLimit {
                return true
            }
        }
        streamingState.clearPending()
        return false
    }

    private static func canonicalizedSeparator(_ line: String, expectedColumns: Int) -> String {
        var canonical = line
        let trimmed = canonical.trimmingCharacters(in: .whitespaces)
        if !trimmed.hasPrefix("|") {
            canonical = "|\(canonical)"
        }
        if !trimmed.hasSuffix("|") {
            canonical.append("|")
        }
        return canonical
    }

    private static func nextNonEmptyLineIndex(lines: [String], start: Int) -> Int? {
        var idx = start
        while idx < lines.count {
            if !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                return idx
            }
            idx += 1
        }
        return nil
    }

    private static func previousNonEmptyLineIndex(lines: [String], start: Int) -> Int? {
        var idx = start
        while idx >= 0 {
            if !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                return idx
            }
            idx -= 1
        }
        return nil
    }

    private static func isAdjacentToListOrCode(lines: [String], headerIndex: Int) -> Bool {
        if let previous = previousNonEmptyLineIndex(lines: lines, start: headerIndex - 1) {
            if lineLooksLikeListOrFence(lines[previous]) {
                return true
            }
        }
        return false
    }

    private static func lineLooksLikeListOrFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if Segmenter.normalizedForFenceDetection(trimmed).hasPrefix("```") {
            return true
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }
        if trimmed.first?.isNumber == true, let dotIndex = trimmed.firstIndex(of: "."), trimmed.distance(from: trimmed.startIndex, to: dotIndex) < 3 {
            return true
        }
        return false
    }

    private static func isValidSeparator(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return separatorPattern.firstMatch(in: line, options: [], range: range) != nil
    }

    private static func logTableFailure(
        phase: String,
        reason: String,
        message: Message,
        rowCount: Int,
        columnCount: Int
    ) {
        logger.error(
            "table_render_failure phase=\(phase, privacy: .public) reason=\(reason, privacy: .public) message=\(message.id, privacy: .public) rows=\(rowCount) cols=\(columnCount)"
        )
    }

    private static func makeCell(
        from text: String,
        metrics: ChatFlowTheme.Metrics,
        messageID: String
    ) -> TableModel.Cell {
        let depth = markdownNestingDepth(in: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if depth > maxMarkdownNestingDepth {
            logRenderFallback(reason: "nesting_limit", messageID: messageID)
            let width = intrinsicWidth(for: trimmed, metrics: metrics)
            return TableModel.Cell(
                attributed: AttributedString(trimmed),
                intrinsicWidth: width,
                plainText: trimmed,
                isEmpty: trimmed.isEmpty
            )
        }

        var attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            logRenderFallback(reason: "markdown_parse_failed", messageID: messageID)
            attributed = AttributedString(trimmed)
        }

        sanitizeLinks(in: &attributed)
        let ns = NSAttributedString(attributed)
        let plainText = ns.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let width = intrinsicWidth(for: plainText, metrics: metrics)

        return TableModel.Cell(
            attributed: attributed,
            intrinsicWidth: width,
            plainText: plainText,
            isEmpty: plainText.isEmpty
        )
    }

    private static func sanitizeLinks(in attributed: inout AttributedString) {
        for run in attributed.runs {
            if let link = run.link, let scheme = link.scheme?.lowercased() {
                if !["http", "https", "mailto"].contains(scheme) {
                    attributed[run.range].link = nil
                }
            }
        }
    }

    private static func intrinsicWidth(for text: String, metrics: ChatFlowTheme.Metrics) -> CGFloat {
        let baseFont = UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
        let scaledFont = UIFontMetrics.default.scaledFont(for: baseFont)
        let width = (text as NSString).size(withAttributes: [.font: scaledFont]).width
        return ceil(width)
    }

    private static func markdownNestingDepth(in text: String) -> Int {
        var depth = 0
        var maxDepth = 0
        var stack: [Character] = []
        let openers: Set<Character> = ["[", "(", "{", "<"]
        let closers: [Character: Character] = ["]": "[", ")": "(", "}": "{", ">": "<"]

        for char in text {
            if openers.contains(char) {
                stack.append(char)
                depth += 1
            } else if let opener = closers[char], stack.last == opener {
                stack.removeLast()
                depth = max(depth - 1, 0)
            } else if char == "*" || char == "_" || char == "`" {
                if stack.last == char {
                    stack.removeLast()
                    depth = max(depth - 1, 0)
                } else {
                    stack.append(char)
                    depth += 1
                }
            }
            maxDepth = max(maxDepth, depth)
        }
        return maxDepth
    }

    private static func logRenderFallback(reason: String, messageID: String) {
        logger.error(
            "table_render_failure phase=render reason=\(reason, privacy: .public) message=\(messageID, privacy: .public)"
        )
    }

    private static func isImageMime(_ mime: String?) -> Bool {
        mime?.lowercased().hasPrefix("image/") == true
    }

    private static func imageAttachments(from attachments: [Attachment]) -> [Attachment] {
        attachments.filter { attachment in
            switch attachment.type {
            case .image:
                return true
            case .asset:
                // Check mime type first; only treat data-bearing assets as images
                // when mime is image/* (or absent, for backward compat with older data).
                if let mime = attachment.mimeType {
                    return isImageMime(mime)
                }
                // No mime: fall back to data presence (legacy behavior).
                return attachment.data != nil
            case .document:
                return false
            }
        }
    }

    private static func fileAttachments(from attachments: [Attachment]) -> [Attachment] {
        attachments.filter { attachment in
            switch attachment.type {
            case .document:
                return true
            case .asset:
                // Mirror of imageAttachments: non-image mime → file.
                if let mime = attachment.mimeType {
                    return !isImageMime(mime)
                }
                // No mime + no data → unknown, treat as file.
                return attachment.data == nil
            case .image:
                return false
            }
        }
    }

    private static func terminalSessionAttachments(from attachments: [Attachment]) -> [Attachment] {
        attachments.filter(isTerminalSessionAttachment)
    }

    private static func isTerminalSessionAttachment(_ attachment: Attachment) -> Bool {
        guard attachment.type == .document else { return false }
        return mimeTypeEquals(attachment.mimeType, expected: TerminalSessionDescriptor.mimeType)
    }

    private static func interactiveHTMLAttachments(from attachments: [Attachment]) -> [Attachment] {
        attachments.filter { attachment in
            guard attachment.type == .document else { return false }
            return mimeTypeEquals(attachment.mimeType, expected: InteractiveHTMLDescriptor.mimeType)
        }
    }

    private static func decodeTerminalSessionDescriptor(from attachment: Attachment) -> TerminalSessionDescriptor? {
        guard isTerminalSessionAttachment(attachment),
              let data = attachment.data,
              !data.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(TerminalSessionDescriptor.self, from: data)
        } catch {
            logger.error(
                "terminal_session_descriptor_decode_failed id=\(attachment.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func decodeInteractiveHTMLDescriptor(from attachment: Attachment) -> InteractiveHTMLDescriptor? {
        guard attachment.type == .document,
              mimeTypeEquals(attachment.mimeType, expected: InteractiveHTMLDescriptor.mimeType),
              let data = attachment.data,
              !data.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(InteractiveHTMLDescriptor.self, from: data)
        } catch {
            logger.error(
                "interactive_html_descriptor_decode_failed id=\(attachment.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        if text.contains("==") {
            return true
        }
        let markdownIndicators = ["#", "*", "_", "~", "`", ">", "[", "]"]
        return markdownIndicators.contains(where: { text.contains($0) })
    }

    private static func shouldSuppressTextForFileAttachments(
        content: String,
        fileAttachments: [Attachment]
    ) -> Bool {
        guard !fileAttachments.isEmpty else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard looksLikeJSON(trimmed) else { return false }
        return fileAttachments.contains { attachment in
            if let mime = normalizedMimeType(attachment.mimeType) {
                if mime == "application/json" || mime == "text/json" || mime.hasSuffix("+json") {
                    return true
                }
            }
            if let filename = attachment.filename?.lowercased(), filename.hasSuffix(".json") {
                return true
            }
            return false
        }
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        if (first == "{" && last == "}") || (first == "[" && last == "]") {
            return true
        }
        return false
    }

    private static func normalizedMimeType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
        let trimmed = base?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func mimeTypeEquals(_ raw: String?, expected: String) -> Bool {
        normalizedMimeType(raw) == expected
    }

    private static func extractURLs(from text: String) -> [URL] {
        guard let detector = linkDetector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var urls: [URL] = []
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            guard url.host != nil else { return }
            guard url.user == nil, url.password == nil else { return }
            if url.absoluteString.count > 2048 { return }
            urls.append(url)
        }
        return urls
    }

    private static func isEmojiOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isEmoji }
    }

    private static func stripMarkdownMarkers(from text: String) -> String {
        let replacements: [String] = [
            "**", "__", "~~", "`", "*", "_", "~", "[", "]", "(", ")", "#", ">", "!", "-", "+"
        ]
        var stripped = text
        for marker in replacements {
            stripped = stripped.replacingOccurrences(of: marker, with: " ")
        }
        return stripped
    }
}

private enum SegmentKind {
    case text
    case code(language: String?)
}

private struct Segment {
    let kind: SegmentKind
    let content: String
}

private enum Segmenter {
    // Some providers/models occasionally emit "fences" with invisible scalars between backticks
    // (e.g. zero-width space), which breaks naive substring matching for "```".
    // Normalizing away those scalars makes fence detection stable without impacting visible text.
    private static let invisibleScalars: Set<UnicodeScalar> = [
        "\u{200B}", // zero-width space
        "\u{200C}", // zero-width non-joiner
        "\u{200D}", // zero-width joiner
        "\u{2060}", // word joiner
        "\u{FEFF}"  // zero-width no-break space / BOM
    ]

    fileprivate static func normalizedForFenceDetection(_ input: String) -> String {
        guard input.unicodeScalars.contains(where: { invisibleScalars.contains($0) }) else {
            return input
        }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(input.unicodeScalars.count)
        for scalar in input.unicodeScalars {
            if !invisibleScalars.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    static func split(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        var remaining = normalizedForFenceDetection(input)

        while let fenceRange = remaining.range(of: "```") {
            let before = String(remaining[..<fenceRange.lowerBound])
            if !before.isEmpty {
                segments.append(Segment(kind: .text, content: before))
            }

            remaining = String(remaining[fenceRange.upperBound...])
            var language: String? = nil
            if let newline = remaining.firstIndex(of: "\n") {
                let languageLine = String(remaining[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                language = languageLine.isEmpty ? nil : languageLine
                remaining = String(remaining[remaining.index(after: newline)...])
            }

            if let endRange = remaining.range(of: "```") {
                let code = String(remaining[..<endRange.lowerBound])
                segments.append(Segment(kind: .code(language: language), content: code))
                remaining = String(remaining[endRange.upperBound...])
            } else {
                segments.append(Segment(kind: .code(language: language), content: remaining))
                remaining = ""
            }
        }

        if !remaining.isEmpty {
            segments.append(Segment(kind: .text, content: remaining))
        }

        return segments
    }
}

private extension Character {
    var isEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmoji && (scalar.properties.generalCategory == .otherSymbol || scalar.properties.generalCategory == .modifierSymbol || scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark)
        }
    }
}

private extension TableModel {
    static func makeRowIdentifier(
        messageID: String,
        rowIndex: Int,
        cells: [String]
    ) -> UUID {
        let raw = "\(messageID)|row|\(rowIndex)|\(cells.joined(separator: "|"))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        var bytes = Array(digest.prefix(16))
        if bytes.count < 16 {
            bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
        }
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
