import SwiftUI

/// Renders the block-level Markdown Claude produces (headings, bullets,
/// task lists, numbered lists, rules, paragraphs). Inline formatting
/// (bold, italics, code, links) is handled by `AttributedString`.
struct MarkdownView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case task(done: Bool, indent: Int, text: String)
        case numbered(number: String, indent: Int, text: String)
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level == 1 ? .title.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case let .bullet(indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .task(done, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square" : "square").foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .numbered(number, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .quote(text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case let .code(text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case let .paragraph(text):
            Text(Self.inline(text))
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(rawLine)
                continue
            }

            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count / 2
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let level = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.rule)
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("* [ ] ") {
                flushParagraph()
                blocks.append(.task(done: false, indent: indent, text: String(line.dropFirst(6))))
            } else if line.lowercased().hasPrefix("- [x] ") || line.lowercased().hasPrefix("* [x] ") {
                flushParagraph()
                blocks.append(.task(done: true, indent: indent, text: String(line.dropFirst(6))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(indent: indent, text: String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                blocks.append(.numbered(number: String(line[...dot]), indent: indent, text: String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if let lines = codeLines { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }
}
