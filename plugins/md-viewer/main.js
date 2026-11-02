function escape(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

const allowedTags = ["img", "br", "a", "p", "div", "center", "span", "b", "i", "u", "strong", "em", "sub", "sup", "small", "picture", "source", "details", "summary", "kbd"];
const allowedAttrs = ["src", "srcset", "alt", "title", "width", "height", "align", "href", "media", "style"];

function unsafe(url) {
  const plain = url.replace(/&#(x?)([0-9a-f]+);?/gi, (_, hex, n) => String.fromCharCode(parseInt(n, hex ? 16 : 10)))
    .replace(/&(tab|newline|colon);/gi, (_, n) => n.toLowerCase() === "colon" ? ":" : "")
    .replace(/[\u0000-\u0020]/g, "");
  return /^(javascript:|vbscript:|data:text\/html)/i.test(plain);
}

function attrs(source) {
  const out = [];
  source.replace(/([a-zA-Z-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))/g, (_, name, __, d, s, b) => {
    const key = name.toLowerCase(), value = d ?? s ?? b ?? "";
    if (!allowedAttrs.includes(key) || unsafe(value)) return "";
    out.push(` ${key}="${value.replace(/"/g, "&quot;")}"`);
    return "";
  });
  return out.join("");
}

const TARGET = "\\(\\s*(?:<([^>\\n]+)>|((?:[^()\\s]|\\([^()\\s]*\\))+))(?:\\s+\"([^\"]*)\")?\\s*\\)";

function inline(text) {
  const keep = [];
  const hold = (html) => { keep.push(html); return "\u0000" + (keep.length - 1) + "\u0000"; };
  const open = (url, title) => hold(`<a href="${escape(url)}"${title ? ` title="${escape(title)}"` : ""}>`);
  const linkable = (url) => /^(https?:|mailto:|#)/i.test(url);
  let s = text.replace(/(`+)(?!`)(.+?)\1(?!`)|\\([\\`*_{}\[\]()#+\-.!~|<>])/g, (_, ticks, c, mark) =>
    mark ? hold(escape(mark)) : hold(`<code>${escape(c.replace(/^ (.*) $/, "$1"))}</code>`));
  s = s.replace(new RegExp("!\\[([^\\]]*)\\]" + TARGET, "g"), (_, alt, wrapped, plain, title) => {
    const url = wrapped ?? plain;
    return unsafe(url) ? alt : hold(`<img src="${url.replace(/"/g, "%22")}" alt="${escape(alt)}"${title ? ` title="${escape(title)}"` : ""}>`);
  });
  s = s.replace(new RegExp("\\[([^\\]]+)\\]" + TARGET, "g"), (_, label, wrapped, plain, title) => {
    const url = wrapped ?? plain;
    return linkable(url) ? open(url, title) + label + hold("</a>") : label;
  });
  s = s.replace(/<((?:https?:\/\/|mailto:)[^\s<>]+)>/gi, (_, url) => open(url) + escape(url) + hold("</a>"));
  s = s.replace(/<(\/?)([a-zA-Z]+)([^>]*?)\/?>/g, (all, close, tag, rest) =>
    allowedTags.includes(tag.toLowerCase()) ? hold(close ? `</${tag.toLowerCase()}>` : `<${tag.toLowerCase()}${attrs(rest)}>`) : all);
  s = escape(s);
  s = s.replace(/(\*\*|__)(\S(?:.*?\S)?)\1/g, "<strong>$2</strong>")
       .replace(/\*(\S(?:.*?\S)?)\*/g, "<em>$1</em>")
       .replace(/(^|\W)_(\S(?:.*?\S)?)_(?=\W|$)/g, "$1<em>$2</em>")
       .replace(/~~(.+?)~~/g, "<del>$1</del>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => keep[i]);
}

function slug(text) {
  return escape(text.trim().toLowerCase().replace(/[`*_~\[\]()!"'.,:;?#]/g, "").replace(/\s+/g, "-"));
}

function cells(line) {
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
  const result = [];
  let cell = "", tick = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "\\" && s[i + 1] === "|") { cell += "|"; i++; continue; }
    if (c === "`") tick = !tick;
    if (c === "|" && !tick) { result.push(cell.trim()); cell = ""; continue; }
    cell += c;
  }
  result.push(cell.trim());
  return result;
}

function isDivider(line) {
  return line.includes("-") && /^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$/.test(line.trim());
}

function table(header, divider, rows) {
  const aligns = cells(divider).map(c => c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : c.startsWith(":") ? "left" : "");
  const cell = (tag, text, i) => `<${tag}${aligns[i] ? ` style="text-align:${aligns[i]}"` : ""}>${inline(text || "")}</${tag}>`;
  const head = cells(header).map((c, i) => cell("th", c, i)).join("");
  const body = rows.map(r => { const cs = cells(r); return `<tr>${aligns.map((_, i) => cell("td", cs[i], i)).join("")}</tr>`; }).join("");
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function body(markdown) {
  const out = [];
  let code = null, fence = null, list = null, para = [], quote = [];
  const flushPara = () => { if (para.length) { out.push(`<p>${para.map(inline).join("<br>")}</p>`); para = []; } };
  const closeList = () => { if (list) { out.push(`</${list}>`); list = null; } };
  const openList = (tag) => { if (list !== tag) { closeList(); out.push(`<${tag}>`); list = tag; } };
  const flushQuote = () => { if (quote.length) { out.push(`<blockquote>${body(quote.join("\n"))}</blockquote>`); quote = []; } };

  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  for (let n = 0; n < lines.length; n++) {
    const raw = lines[n];
    const line = raw.trim();
    const mark = line.match(/^(`{3,}|~{3,})(.*)$/);
    if (code !== null) {
      if (mark && mark[1][0] === fence[0] && mark[1].length >= fence.length && !mark[2].trim()) {
        out.push(`<pre><code>${escape(code.join("\n"))}</code></pre>`);
        code = null;
      } else {
        code.push(raw);
      }
      continue;
    }
    if (mark && !(mark[1][0] === "`" && mark[2].includes("`"))) {
      flushPara(); closeList(); flushQuote();
      code = [];
      fence = mark[1];
      continue;
    }
    const quoted = raw.match(/^ {0,3}>\s?(.*)$/);
    if (quoted) { flushPara(); closeList(); quote.push(quoted[1]); continue; }
    flushQuote();
    if (!line) { flushPara(); closeList(); continue; }

    const depth = Math.floor((raw.match(/^[ \t]*/)[0].length) / 2);
    let m;
    if (para.length && /^(=+|-+)$/.test(line)) {
      const level = line[0] === "=" ? 1 : 2;
      out.push(`<h${level} id="${slug(para.join(" "))}">${inline(para.join(" "))}</h${level}>`);
      para = [];
    } else if (line.includes("|") && n + 1 < lines.length && isDivider(lines[n + 1]) && cells(line).length === cells(lines[n + 1]).length) {
      flushPara(); closeList();
      const rows = [];
      let k = n + 2;
      while (k < lines.length && lines[k].trim() && lines[k].includes("|")) rows.push(lines[k++]);
      out.push(table(line, lines[n + 1], rows));
      n = k - 1;
    } else if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
      flushPara(); closeList();
      out.push(`<h${m[1].length} id="${slug(m[2])}">${inline(m[2])}</h${m[1].length}>`);
    } else if (/^([-*_])(\s*\1){2,}$/.test(line)) {
      flushPara(); closeList();
      out.push("<hr>");
    } else if ((m = line.match(/^[-*+]\s+(?:\[([ xX])\]\s+)?(.*)$/))) {
      flushPara(); openList("ul");
      const box = m[1] === undefined ? "" : (m[1] === " " ? "☐ " : "☑︎ ");
      out.push(`<li class="${box ? "task" : ""}" style="margin-left:${depth * 16}px">${box}${inline(m[2])}</li>`);
    } else if ((m = line.match(/^(\d+)[.)]\s+(.*)$/))) {
      flushPara(); openList("ol");
      out.push(`<li value="${m[1]}" style="margin-left:${depth * 16}px">${inline(m[2])}</li>`);
    } else if (list && !para.length && /^\s/.test(raw)) {
      out[out.length - 1] = out[out.length - 1].replace(/<\/li>$/, () => `<br>${inline(line)}</li>`);
    } else {
      closeList();
      para.push(line);
    }
  }
  if (code !== null) out.push(`<pre><code>${escape(code.join("\n"))}</code></pre>`);
  flushPara(); closeList(); flushQuote();
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
    table { border-collapse: collapse; margin: 0 0 0.9em; display: block; overflow-x: auto; max-width: 100%; }
    th, td { border: 1px solid ${settings.dark ? "rgba(255,255,255,0.22)" : "rgba(0,0,0,0.18)"}; padding: 5px 12px; }
    th { background: ${subtle}; font-weight: 600; }
    tbody tr:nth-child(even) { background: ${settings.dark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.025)"}; }
    img { max-width: 100%; height: auto; vertical-align: middle; }
    a { color: ${settings.dark ? "#6cb6ff" : "#0a62c9"}; }
  `;
  return `<head><meta charset="utf-8"><style>${css}</style></head><body>${body(text)}</body>`;
}
