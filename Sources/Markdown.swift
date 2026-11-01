import AppKit

func renderInlineMarkdown(_ line: String, font base: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let parsed = try? AttributedString(markdown: line, options: options) else {
        return NSAttributedString(string: line, attributes: [.font: base, .foregroundColor: color])
    }
    let result = NSMutableAttributedString()
    let fm = NSFontManager.shared
    for run in parsed.runs {
        var font = base
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.code) {
            font = .monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .regular)
        } else {
            if intent.contains(.stronglyEmphasized) { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if intent.contains(.code) { attrs[.backgroundColor] = NSColor.quaternaryLabelColor }
        if let link = run.link { attrs[.link] = link }
        result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
    }
    return result
}

private struct MarkdownTable {
    let rows: [[String]]
    let alignments: [NSTextAlignment]
    let end: Int

    private static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in body {
            if escaped {
                cell += character == "|" ? "|" : "\\\(character)"
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    init?(_ lines: [String], at start: Int) {
        guard start + 1 < lines.count, lines[start].contains("|"), lines[start + 1].contains("-") else { return nil }
        let header = Self.cells(lines[start]), marks = Self.cells(lines[start + 1])
        guard header.count == marks.count,
              marks.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) else { return nil }
        alignments = marks.map { $0.hasPrefix(":") && $0.hasSuffix(":") ? .center : $0.hasSuffix(":") ? .right : .left }
        var rows = [header]
        var next = start + 2
        while next < lines.count, lines[next].contains("|") {
            let row = Self.cells(lines[next])
            rows.append((0..<header.count).map { $0 < row.count ? row[$0] : "" })
            next += 1
        }
        self.rows = rows
        end = next
    }
}

func renderMarkdown(_ markdown: String, size: CGFloat = NSFont.systemFontSize, color: NSColor = .labelColor) -> NSAttributedString {
    let body = NSFont.systemFont(ofSize: size)
    let output = NSMutableAttributedString()
    var inCode = false

    func paragraph(indent: CGFloat = 0, head: CGFloat = 0, spacing: CGFloat = 4) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent + head
        style.paragraphSpacing = spacing
        return style
    }

    func append(_ text: NSAttributedString, _ style: NSParagraphStyle) {
        let line = NSMutableAttributedString(attributedString: text)
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        output.append(line)
    }

    func append(_ table: MarkdownTable) {
        let grid = NSTextTable()
        grid.numberOfColumns = table.alignments.count
        grid.setContentWidth(100, type: .percentageValueType)
        for (r, row) in table.rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let block = NSTextTableBlock(table: grid, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                if r == 0 { block.backgroundColor = .quaternaryLabelColor }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.alignment = table.alignments[c]
                append(renderInlineMarkdown(cell, font: r == 0 ? .boldSystemFont(ofSize: size) : body, color: color), style)
            }
        }
        append(NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: size / 2)]), paragraph(spacing: 0))
    }

    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
        let raw = lines[index]
        index += 1
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { inCode.toggle(); continue }
        if inCode {
            let mono = NSFont.monospacedSystemFont(ofSize: size * 0.95, weight: .regular)
            append(NSAttributedString(string: raw, attributes: [.font: mono, .foregroundColor: color,
                                                                .backgroundColor: NSColor.quaternaryLabelColor]),
                   paragraph(indent: 8, spacing: 0))
            continue
        }
        if trimmed.isEmpty { continue }
        if let table = MarkdownTable(lines, at: index - 1) {
            append(table)
            index = table.end
            continue
        }

        let depth = CGFloat(raw.prefix { $0 == " " || $0 == "\t" }.count / 2) * 16

        if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let level = trimmed[m].filter { $0 == "#" }.count
            let font = NSFont.boldSystemFont(ofSize: size + CGFloat(max(0, 4 - level)) * 2)
            append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: font, color: color), paragraph(spacing: 6))
        } else if trimmed.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil {
            append(NSAttributedString(string: String(repeating: "─", count: 30),
                                      attributes: [.font: body, .foregroundColor: NSColor.separatorColor]), paragraph())
        } else if let m = trimmed.range(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) {
            let marker = trimmed[m]
            let bullet = marker.contains("[x]") || marker.contains("[X]") ? "☑︎ " : marker.contains("[ ]") ? "☐ " : "• "
            let line = NSMutableAttributedString(string: bullet, attributes: [.font: body, .foregroundColor: color])
            line.append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body, color: color))
            append(line, paragraph(indent: depth + 8, head: 12))
        } else if let m = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            let number = trimmed[m].trimmingCharacters(in: .whitespaces)
            let line = NSMutableAttributedString(string: number + " ", attributes: [.font: body, .foregroundColor: color])
            line.append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body, color: color))
            append(line, paragraph(indent: depth + 8, head: 18))
        } else if let m = trimmed.range(of: #"^>\s?"#, options: .regularExpression) {
            let line = NSMutableAttributedString(attributedString: renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body, color: color))
            line.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.65), range: NSRange(location: 0, length: line.length))
            append(line, paragraph(indent: 12))
        } else {
            append(renderInlineMarkdown(trimmed, font: body, color: color), paragraph())
        }
    }
    return output
}
