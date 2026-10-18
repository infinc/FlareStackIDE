function escape(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function inline(text) {
  const codes = [];
  let s = escape(text).replace(/`([^`]+)`/g, (_, c) => { codes.push(c); return "\u0000" + (codes.length - 1) + "\u0000"; });
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, url) =>
    /^(https?:|mailto:|#)/.test(url) ? `<a href="${url}">${label}</a>` : label);
  s = s.replace(/(\*\*|__)(.+?)\1/g, "<strong>$2</strong>")
       .replace(/\*(.+?)\*/g, "<em>$1</em>")
       .replace(/(^|\W)_(.+?)_(?=\W|$)/g, "$1<em>$2</em>")
       .replace(/~~(.+?)~~/g, "<del>$1</del>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[i]}</code>`);
}

function body(markdown) {
  const out = [];
  let code = null, list = null, para = [];
  const flushPara = () => { if (para.length) { out.push(`<p>${para.map(inline).join("<br>")}</p>`); para = []; } };
  const closeList = () => { if (list) { out.push(`</${list}>`); list = null; } };
  const openList = (tag) => { if (list !== tag) { closeList(); out.push(`<${tag}>`); list = tag; } };

  for (const raw of markdown.replace(/\r\n/g, "\n").split("\n")) {
    const line = raw.trim();
    if (line.startsWith("```")) {
      flushPara(); closeList();
      if (code === null) { code = []; } else { out.push(`<pre><code>${escape(code.join("\n"))}</code></pre>`); code = null; }
      continue;
    }
    if (code !== null) { code.push(raw); continue; }
    if (!line) { flushPara(); closeList(); continue; }

    const depth = Math.floor((raw.match(/^[ \t]*/)[0].length) / 2);
    let m;
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
      flushPara(); closeList();
      out.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`);
    } else if (/^([-*_]\s*){3,}$/.test(line)) {
      flushPara(); closeList();
      out.push("<hr>");
    } else if ((m = line.match(/^[-*+]\s+(?:\[([ xX])\]\s+)?(.*)$/))) {
      flushPara(); openList("ul");
      const box = m[1] === undefined ? "" : (m[1] === " " ? "☐ " : "☑︎ ");
      out.push(`<li class="${box ? "task" : ""}" style="margin-left:${depth * 16}px">${box}${inline(m[2])}</li>`);
    } else if ((m = line.match(/^(\d+)[.)]\s+(.*)$/))) {
      flushPara(); openList("ol");
      out.push(`<li value="${m[1]}" style="margin-left:${depth * 16}px">${inline(m[2])}</li>`);
    } else if ((m = line.match(/^>\s?(.*)$/))) {
      flushPara(); closeList();
      out.push(`<blockquote>${inline(m[1])}</blockquote>`);
    } else {
      closeList();
      para.push(line);
    }
  }
  if (code !== null) out.push(`<pre><code>${escape(code.join("\n"))}</code></pre>`);
  flushPara(); closeList();
  return out.join("\n");
}

function render(text, settings) {
  const fg = settings.foreground, bg = settings.background, size = settings.fontSize;
  const subtle = settings.dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.07)";
  const css = `
    html { background: ${bg}; color: ${fg}; }
    body { font: ${size}px -apple-system, "Hiragino Sans", sans-serif; line-height: 1.6; margin: 12px 14px; word-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 0.9em 0 0.4em; }
    h1 { font-size: 1.7em; } h2 { font-size: 1.4em; } h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; }
    p, ul, ol, pre, blockquote { margin: 0 0 0.7em; }
    ul, ol { padding-left: 1.4em; }
    li.task { list-style: none; margin-left: -1.2em; }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em; background: ${subtle}; border-radius: 4px; padding: 0.1em 0.3em; }
    pre { background: ${subtle}; border-radius: 6px; padding: 10px 12px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid ${subtle}; padding-left: 10px; opacity: 0.7; }
    hr { border: none; border-top: 1px solid ${subtle}; margin: 1em 0; }
    a { color: ${settings.dark ? "#6cb6ff" : "#0a62c9"}; }
  `;
  return `<head><meta charset="utf-8"><style>${css}</style></head><body>${body(text)}</body>`;
}
