import AppKit

func renderInlineMarkdown(_ line: String, font base: NSFont) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let parsed = try? AttributedString(markdown: line, options: options) else {
        return NSAttributedString(string: line, attributes: [.font: base, .foregroundColor: NSColor.labelColor])
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
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if intent.contains(.code) { attrs[.backgroundColor] = NSColor.quaternaryLabelColor }
        if let link = run.link { attrs[.link] = link }
        result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
    }
    return result
}

func renderMarkdown(_ markdown: String) -> NSAttributedString {
    let size = NSFont.systemFontSize
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

    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    for raw in lines {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { inCode.toggle(); continue }
        if inCode {
            let mono = NSFont.monospacedSystemFont(ofSize: size * 0.95, weight: .regular)
            append(NSAttributedString(string: raw, attributes: [.font: mono, .foregroundColor: NSColor.labelColor,
                                                                .backgroundColor: NSColor.quaternaryLabelColor]),
                   paragraph(indent: 8, spacing: 0))
            continue
        }
        if trimmed.isEmpty { continue }

        let depth = CGFloat(raw.prefix { $0 == " " || $0 == "\t" }.count / 2) * 16

        if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let level = trimmed[m].filter { $0 == "#" }.count
            let font = NSFont.boldSystemFont(ofSize: size + CGFloat(max(0, 4 - level)) * 2)
            append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: font), paragraph(spacing: 6))
        } else if trimmed.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil {
            append(NSAttributedString(string: String(repeating: "─", count: 30),
                                      attributes: [.font: body, .foregroundColor: NSColor.separatorColor]), paragraph())
        } else if let m = trimmed.range(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) {
            let marker = trimmed[m]
            let bullet = marker.contains("[x]") || marker.contains("[X]") ? "☑︎ " : marker.contains("[ ]") ? "☐ " : "• "
            let line = NSMutableAttributedString(string: bullet, attributes: [.font: body, .foregroundColor: NSColor.labelColor])
            line.append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body))
            append(line, paragraph(indent: depth + 8, head: 12))
        } else if let m = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            let number = trimmed[m].trimmingCharacters(in: .whitespaces)
            let line = NSMutableAttributedString(string: number + " ", attributes: [.font: body, .foregroundColor: NSColor.labelColor])
            line.append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body))
            append(line, paragraph(indent: depth + 8, head: 18))
        } else if let m = trimmed.range(of: #"^>\s?"#, options: .regularExpression) {
            let line = NSMutableAttributedString(attributedString: renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body))
            line.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: line.length))
            append(line, paragraph(indent: 12))
        } else {
            append(renderInlineMarkdown(trimmed, font: body), paragraph())
        }
    }
    return output
}
