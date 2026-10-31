const PYTHON = [
  "import sys, ast, warnings",
  "p = sys.argv[1]",
  "src = open(p, encoding='utf-8').read()",
  "with warnings.catch_warnings(record=True) as w:",
  "    warnings.simplefilter('always')",
  "    try:",
  "        tree = compile(src, p, 'exec', ast.PyCF_ONLY_AST)",
  "        compile(tree, p, 'exec')",
  "    except SyntaxError as e:",
  "        print(f'{e.lineno or 1}:{e.offset or 0}:error:{type(e).__name__}: {e.msg}')",
  "        tree = None",
  "    for x in w:",
  "        print(f'{x.lineno}:0:warning:{x.category.__name__}: {x.message}')",
  "if tree is not None and not p.endswith('__init__.py'):",
  "    used = set()",
  "    exported = set()",
  "    for n in ast.walk(tree):",
  "        if isinstance(n, ast.Name): used.add(n.id)",
  "        elif isinstance(n, ast.Attribute):",
  "            b = n",
  "            while isinstance(b, ast.Attribute): b = b.value",
  "            if isinstance(b, ast.Name): used.add(b.id)",
  "        elif isinstance(n, ast.Constant) and isinstance(n.value, str): exported.add(n.value)",
  "    for n in tree.body:",
  "        if isinstance(n, (ast.Import, ast.ImportFrom)):",
  "            if isinstance(n, ast.ImportFrom) and n.module == '__future__': continue",
  "            for a in n.names:",
  "                name = (a.asname or a.name).split('.')[0]",
  "                if name != '*' and name not in used and name not in exported:",
  "                    print(f'{n.lineno}:{n.col_offset + 1}:warning:未使用の import: {a.asname or a.name}')",
].join("\n");

function checker(ext, name) {
  switch (ext) {
    case "py": case "pyw": case "pyi":
      return { args: ["python3", "-c", PYTHON, "$FILE"], format: "simple" };
    case "js": case "mjs": case "cjs":
      return { args: ["node", "--check", "$FILE"], format: "node" };
    case "swift":
      return { args: ["swiftc", "-parse", "$FILE"], format: "gcc" };
    case "c": case "h": case "m":
      return { args: ["clang", "-fsyntax-only", "-Wall", "-I", "$DIR", "$FILE"], format: "gcc" };
    case "cpp": case "cc": case "cxx": case "hpp": case "hh": case "hxx": case "mm":
      return { args: ["clang++", "-std=c++17", "-fsyntax-only", "-Wall", "-I", "$DIR", "$FILE"], format: "gcc" };
    case "go":
      return { args: ["gofmt", "-e", "-l", "$FILE"], format: "gcc" };
    case "rb": case "rake":
      return { args: ["ruby", "-wc", "$FILE"], format: "ruby" };
    case "sh": case "bash":
      return { args: ["bash", "-n", "$FILE"], format: "bash" };
    case "zsh":
      return { args: ["zsh", "-n", "$FILE"], format: "zsh" };
    case "php":
      return { args: ["php", "-l", "$FILE"], format: "php" };
    case "pl": case "pm":
      return { args: ["perl", "-wc", "$FILE"], format: "perl" };
    case "lua":
      return { args: ["luac", "-p", "$FILE"], format: "lua" };
  }
  if (name === "gemfile" || name === "rakefile" || name === "podfile") return { args: ["ruby", "-wc", "$FILE"], format: "ruby" };
  return null;
}

function item(line, column, severity, message) {
  return { line: Number(line) || 1, column: Number(column) || 0, severity: severity, message: String(message).trim() };
}

function parse(output, format, file) {
  const out = [];
  const lines = output.split("\n");
  const sev = (s) => (/warning/i.test(s || "") ? "warning" : "error");
  switch (format) {
    case "simple":
      for (const l of lines) {
        const m = /^(\d+):(\d+):(error|warning):(.*)$/.exec(l);
        if (m) out.push(item(m[1], m[2], m[3], m[4]));
      }
      break;
    case "gcc":
      for (const l of lines) {
        const m = /^.*?:(\d+):(?:(\d+):)?\s*(?:(fatal error|error|warning|note|remark):\s*)?(.*)$/.exec(l);
        if (!m || m[3] === "note" || m[3] === "remark" || !m[4]) continue;
        out.push(item(m[1], m[2], sev(m[3]), m[4]));
      }
      break;
    case "node": {
      let line = 0, column = 0, message = "";
      for (let i = 0; i < lines.length; i++) {
        const head = /:(\d+)$/.exec(lines[i]);
        if (!line && head) {
          line = Number(head[1]);
          const caret = lines[i + 2] || "";
          const at = caret.indexOf("^");
          if (at >= 0 && /^\s*\^+\s*$/.test(caret)) column = at + 1;
        }
        const m = /^(\w*Error): (.*)$/.exec(lines[i]);
        if (m && !message) message = m[1] + ": " + m[2];
      }
      if (message) out.push(item(line || 1, column, "error", message));
      break;
    }
    case "ruby":
      for (const l of lines) {
        if (/Syntax OK/.test(l)) continue;
        const m = /^.*?:(\d+): (warning: )?(.*)$/.exec(l);
        if (m) out.push(item(m[1], 0, m[2] ? "warning" : "error", m[3]));
      }
      break;
    case "bash":
      for (const l of lines) {
        const m = /^.*?: (?:line )?(\d+): (.*)$/.exec(l);
        if (m && m[2][0] !== "`") out.push(item(m[1], 0, "error", m[2]));
      }
      break;
    case "zsh":
      for (const l of lines) {
        const m = /^.*?:(\d+): (.*)$/.exec(l);
        if (m) out.push(item(m[1], 0, "error", m[2]));
      }
      break;
    case "php":
      for (const l of lines) {
        const m = /^(?:PHP )?(Parse error|Fatal error|Warning|Deprecated):\s*(.*) in .* on line (\d+)/.exec(l);
        if (m) out.push(item(m[3], 0, sev(m[1]), m[2]));
      }
      break;
    case "perl":
      for (const l of lines) {
        const m = /^(.*) at .* line (\d+)[.,]/.exec(l);
        if (m) out.push(item(m[2], 0, /syntax error|Can't|Missing|Unmatched/.test(m[1]) ? "error" : "warning", m[1]));
      }
      break;
    case "lua":
      for (const l of lines) {
        const m = /^.*?:.*?:(\d+): (.*)$/.exec(l);
        if (m) out.push(item(m[1], 0, "error", m[2]));
      }
      break;
  }
  return out;
}

function jsonCheck(text, loose) {
  let i = 0;
  const duplicates = [];
  const fail = (message) => { throw { at: i, message: message }; };
  const skip = () => {
    for (;;) {
      while (i < text.length && " \t\r\n".indexOf(text[i]) >= 0) i++;
      if (loose && text.startsWith("//", i)) { while (i < text.length && text[i] !== "\n") i++; continue; }
      if (loose && text.startsWith("/*", i)) {
        const end = text.indexOf("*/", i + 2);
        if (end < 0) fail("コメントが閉じられていません");
        i = end + 2;
        continue;
      }
      return;
    }
  };
  const string = () => {
    i++;
    while (i < text.length) {
      const c = text[i];
      if (c === '"') { i++; return; }
      if (c === "\n") fail("文字列が閉じられていません");
      if (c === "\\") {
        const e = text[i + 1];
        if (e === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(text.substr(i + 2, 4))) fail("不正なエスケープ \\u");
          i += 6;
          continue;
        }
        if ('"\\/bfnrt'.indexOf(e) < 0) fail("不正なエスケープ \\" + (e || ""));
        i += 2;
        continue;
      }
      i++;
    }
    fail("文字列が閉じられていません");
  };
  const value = () => {
    skip();
    const c = text[i];
    if (c === "{") {
      i++;
      skip();
      if (text[i] === "}") { i++; return; }
      const keys = new Set();
      for (;;) {
        skip();
        if (text[i] !== '"') fail("キーは \" で囲んだ文字列にしてください");
        const start = i;
        string();
        const key = text.slice(start, i);
        if (keys.has(key)) duplicates.push({ at: start, message: "キー " + key + " が重複しています" });
        keys.add(key);
        skip();
        if (text[i] !== ":") fail(": がありません");
        i++;
        value();
        skip();
        if (text[i] === ",") {
          i++;
          skip();
          if (text[i] === "}") { if (!loose) fail("末尾のカンマは使えません"); i++; return; }
          continue;
        }
        if (text[i] === "}") { i++; return; }
        fail(", または } がありません");
      }
    }
    if (c === "[") {
      i++;
      skip();
      if (text[i] === "]") { i++; return; }
      for (;;) {
        value();
        skip();
        if (text[i] === ",") {
          i++;
          skip();
          if (text[i] === "]") { if (!loose) fail("末尾のカンマは使えません"); i++; return; }
          continue;
        }
        if (text[i] === "]") { i++; return; }
        fail(", または ] がありません");
      }
    }
    if (c === '"') return string();
    const m = /^(?:-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)/.exec(text.slice(i, i + 400));
    if (m) { i += m[0].length; return; }
    fail(i >= text.length ? "値がありません" : "不正な値です");
  };
  try {
    skip();
    if (i >= text.length) return { error: null, duplicates: duplicates };
    value();
    skip();
    if (i < text.length) fail("余分な文字があります");
    return { error: null, duplicates: duplicates };
  } catch (e) {
    if (e.at === undefined) throw e;
    return { error: e, duplicates: duplicates };
  }
}

function located(text, at, severity, message) {
  const before = text.slice(0, at);
  return item(before.split("\n").length, at - before.lastIndexOf("\n"), severity, message);
}

const C_LIKE = { line: ["//"], block: [["/*", "*/"]], triple: [], quotes: ['"', "'"], multiline: [] };
const LEXERS = {
  ts: { ...C_LIKE, multiline: ["`"], templates: true, regex: true },
  js: { ...C_LIKE, multiline: ["`"], templates: true, regex: true },
  java: { ...C_LIKE, triple: ['"""'] },
  kotlin: { ...C_LIKE, triple: ['"""'], templates: true },
  rust: { ...C_LIKE, lifetimes: true },
  csharp: { ...C_LIKE, triple: ['@"', '"""'] },
  dart: { ...C_LIKE, triple: ['"""', "'''"], templates: true },
  c: C_LIKE,
  swift: { ...C_LIKE, quotes: ['"'], triple: ['"""'] },
  go: { ...C_LIKE, multiline: ["`"] },
  css: { line: [], block: [["/*", "*/"]], triple: [], quotes: ['"', "'"], multiline: [] },
  python: { line: ["#"], block: [], triple: ['"""', "'''"], quotes: ['"', "'"], multiline: [] },
  ruby: { line: ["#"], block: [], triple: [], quotes: ['"', "'"], multiline: [] },
  shell: { line: ["#"], block: [], triple: [], quotes: ['"', "'"], multiline: [] },
  php: { line: ["//", "#"], block: [["/*", "*/"]], triple: [], quotes: ['"', "'"], multiline: [] },
  lua: { line: ["--"], block: [["--[[", "]]"]], triple: [], quotes: ['"', "'"], multiline: [] },
};
const LANGUAGES = {
  ts: "ts", mts: "ts", cts: "ts", tsx: "ts", js: "js", mjs: "js", cjs: "js", jsx: "js", java: "java", kt: "kotlin", kts: "kotlin",
  rs: "rust", cs: "csharp", dart: "dart", c: "c", h: "c", m: "c", mm: "c", cpp: "c", cc: "c", cxx: "c", hpp: "c", hh: "c", hxx: "c",
  swift: "swift", go: "go", css: "css", scss: "css", less: "css", py: "python", pyw: "python", pyi: "python", rb: "ruby", rake: "ruby",
  sh: "shell", bash: "shell", zsh: "shell", php: "php", lua: "lua",
};
const BRACKET_CHECKED = ["ts", "mts", "cts", "java", "kt", "kts", "rs", "cs", "dart", "css", "scss", "less"];

function mask(text, c) {
  const out = text.split("");
  const n = text.length;
  const blank = (a, b) => { for (let k = a; k < b; k++) if (out[k] !== "\n") out[k] = " "; };
  const pairs = c.block.concat(c.triple.map((q) => [q, q === '@"' ? '"' : q]));
  let i = 0, previous = "";
  while (i < n) {
    const t = text[i];
    if (c.line.some((s) => text.startsWith(s, i)) && !pairs.some((p) => text.startsWith(p[0], i))) {
      let end = text.indexOf("\n", i);
      if (end < 0) end = n;
      blank(i, end);
      i = end;
      continue;
    }
    const pair = pairs.find((p) => text.startsWith(p[0], i));
    if (pair) {
      const end = text.indexOf(pair[1], i + pair[0].length);
      const stop = end < 0 ? n : end + pair[1].length;
      blank(i, stop);
      i = stop;
      previous = '"';
      continue;
    }
    if (c.lifetimes && t === "'" && !/^'(\\.[^']*|[^\\'\n])'/.test(text.slice(i, i + 12))) { i++; continue; }
    if (c.quotes.indexOf(t) >= 0 || c.multiline.indexOf(t) >= 0) {
      const multiline = c.multiline.indexOf(t) >= 0;
      let k = i + 1;
      while (k < n && text[k] !== t && (multiline || text[k] !== "\n")) {
        if (text[k] === "\\") { k += 2; continue; }
        if (c.templates && text[k] === "$" && text[k + 1] === "{") {
          let depth = 1;
          k += 2;
          while (k < n && depth > 0) {
            if (text[k] === "{") depth++;
            if (text[k] === "}") depth--;
            k++;
          }
          continue;
        }
        k++;
      }
      const stop = Math.min(k + 1, n);
      blank(i, stop);
      i = stop;
      previous = '"';
      continue;
    }
    if (c.regex && t === "/" && "(,=:[!&|?{};\n".indexOf(previous || "\n") >= 0) {
      const m = /^\/(?:\\.|\[(?:\\.|[^\]\n])*\]|[^/\\\n])+\/[a-z]*/.exec(text.slice(i, i + 500));
      if (m) {
        blank(i, i + m[0].length);
        i += m[0].length;
        previous = '"';
        continue;
      }
    }
    if (" \t\r\n".indexOf(t) < 0) previous = t;
    i++;
  }
  return out.join("");
}

function brackets(text, masked) {
  const close = { ")": "(", "]": "[", "}": "{" };
  const open = { "(": ")", "[": "]", "{": "}" };
  const stack = [];
  for (let i = 0; i < masked.length; i++) {
    const t = masked[i];
    if (open[t]) stack.push(i);
    else if (close[t]) {
      if (!stack.length) return [located(text, i, "error", "対応する " + close[t] + " がありません")];
      const top = stack.pop();
      if (masked[top] !== close[t]) return [located(text, i, "error", open[masked[top]] + " で閉じる必要があります（" + t + " になっています）")];
    }
  }
  return stack.length ? [located(text, stack[stack.length - 1], "error", masked[stack[stack.length - 1]] + " が閉じられていません")] : [];
}

function fullWidthSpaces(text, masked) {
  const out = [];
  for (let i = masked.indexOf("\u3000"); i >= 0; i = masked.indexOf("\u3000", i + 1)) {
    out.push(located(text, i, "warning", "コードの中に全角スペースがあります"));
    if (out.length >= 50) break;
  }
  return out;
}

function mixedIndent(lines) {
  let spaces = 0, tabs = 0;
  const out = [];
  lines.forEach((l, i) => {
    if (/^ +\S/.test(l)) spaces++;
    if (/^\t+\S/.test(l)) tabs++;
    if (spaces && tabs && !out.length) out.push(item(i + 1, 0, "warning", "インデントにタブとスペースが混ざっています"));
  });
  return out;
}

function conflicts(lines) {
  const out = [];
  lines.forEach((l, i) => {
    if (/^(<{7} |>{7} )/.test(l)) out.push(item(i + 1, 0, "error", "マージの競合が残っています"));
  });
  return out;
}

function listNumbers(out, items) {
  if (items.length < 2 || items.every((x) => x.n === 1)) return;
  for (let i = 1; i < items.length; i++) {
    const p = items[i - 1].n, x = items[i];
    if (x.n === p) out.push(item(x.line, x.column, "warning", "番号 " + x.n + " が続いています（" + (p + 1) + " のはずです）"));
    else if (x.n !== p + 1) out.push(item(x.line, x.column, "warning", "番号が飛んでいます（" + p + " の次は " + (p + 1) + " のはずです）"));
  }
}

function tableCells(line) {
  const cleaned = line.replace(/(`+).*?\1/g, "").replace(/\\\|/g, "").trim().replace(/^\|/, "").replace(/\|$/, "");
  return cleaned.split("|").length;
}

function markdown(lines, dir) {
  const out = [];
  let fence = null, heading = 0;
  let lists = [];
  const flush = (keep) => {
    lists.filter((l) => !keep(l)).forEach((l) => listNumbers(out, l.items));
    lists = lists.filter(keep);
  };
  const isItem = (l) => /^\s*([-*+]|\d{1,9}[.)])(\s|$)/.test(l);
  let i = 0;
  if (lines[0] !== undefined && /^---\s*$/.test(lines[0])) {
    const end = lines.findIndex((l, k) => k > 0 && /^(---|\.\.\.)\s*$/.test(l));
    if (end > 0) i = end + 1;
  }
  for (; i < lines.length; i++) {
    const line = lines[i];
    const mark = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      if (mark && mark[1][0] === fence.char && mark[1].length >= fence.size && !mark[2].trim()) fence = null;
      continue;
    }
    if (mark) {
      fence = { char: mark[1][0], size: mark[1].length, line: i + 1 };
      continue;
    }
    if (!line.trim()) continue;
    const indent = /^\s*/.exec(line)[0].length;
    const numbered = /^(\s*)(\d{1,9})[.)](\s|$)/.exec(line);
    if (numbered) {
      flush((l) => l.indent <= indent);
      let list = lists[lists.length - 1];
      if (!list || list.indent !== indent) {
        list = { indent: indent, items: [] };
        lists.push(list);
      }
      list.items.push({ n: Number(numbered[2]), line: i + 1, column: indent + 1 });
    } else {
      flush((l) => l.indent < indent);
    }
    const empty = /^\s*([-*+]|\d{1,9}[.)])\s*$/.test(line);
    if (empty && (i === 0 || !lines[i - 1].trim() || isItem(lines[i - 1]))) out.push(item(i + 1, indent + 1, "warning", "リストの項目が空です"));
    const atx = /^ {0,3}(#{1,6})(.*)$/.exec(line);
    if (atx && !line.trim().startsWith("#!")) {
      if (atx[2] && !/^\s/.test(atx[2]) && atx[2][0] !== "#") out.push(item(i + 1, 0, "warning", "# の後に空白がないため見出しになりません"));
      else if (!atx[2].trim() && atx[2][0] !== "#") out.push(item(i + 1, 0, "warning", "見出しの中身が空です"));
      else if (/^\s/.test(atx[2])) {
        const level = atx[1].length;
        if (heading && level > heading + 1) out.push(item(i + 1, 0, "warning", "見出しのレベルが飛んでいます（" + "#".repeat(heading) + " の次が " + atx[1] + "）"));
        heading = level;
      }
    }
    const next = lines[i + 1];
    if (line.indexOf("|") >= 0 && next !== undefined && next.indexOf("-") >= 0 && next.indexOf("|") >= 0 && /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(next)) {
      const columns = tableCells(line);
      let k = i + 1;
      for (; k < lines.length && lines[k].indexOf("|") >= 0; k++) {
        if (tableCells(lines[k]) !== columns) out.push(item(k + 1, 0, "warning", "表の列の数が合いません（" + columns + " 列のはずです）"));
      }
      i = k - 1;
      continue;
    }
    const plain = line.replace(/`[^`]*`/g, (m) => " ".repeat(m.length));
    const link = /!?\[[^\]]*\]\(([^)\s]*)(?:\s+"[^"]*")?\)/g;
    for (let m = link.exec(plain); m; m = link.exec(plain)) {
      const target = m[1];
      if (!target) out.push(item(i + 1, m.index + 1, "warning", "リンク先が空です"));
      else if (dir && typeof fileExists === "function" && !/^([a-z][a-z0-9+.-]*:|#|\/)/i.test(target)) {
        const path = decodeURI(target.replace(/[#?].*$/, ""));
        if (path && !fileExists(path, dir)) out.push(item(i + 1, m.index + 1, "warning", "ファイルが見つかりません: " + path));
      }
    }
  }
  flush(() => false);
  if (fence) out.push(item(fence.line, 0, "error", "コードブロックが閉じられていません"));
  return out;
}

const VOID_TAGS = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"];
const OPTIONAL_TAGS = ["li", "p", "td", "th", "tr", "thead", "tbody", "tfoot", "dt", "dd", "option", "optgroup", "colgroup", "caption", "html", "head", "body"];

function markup(text, strict) {
  const severity = strict ? "error" : "warning";
  const out = [];
  const stack = [];
  const re = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<![^>]*>|<(script|style)\b(?:"[^"]*"|'[^']*'|[^'">])*?(?<!\/)>[\s\S]*?<\/\1\s*>|<(\/?)([A-Za-z][\w:.-]*)((?:"[^"]*"|'[^']*'|[^'">])*?)(\/?)>/gi;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (!m[3]) continue;
    const name = strict ? m[3] : m[3].toLowerCase();
    if (m[5] || (!strict && VOID_TAGS.indexOf(name) >= 0)) continue;
    if (!m[2]) {
      stack.push({ name: name, at: m.index });
      continue;
    }
    let k = stack.length - 1;
    while (k >= 0 && stack[k].name !== name && !strict) k--;
    if (k >= 0 && stack[k].name === name) {
      for (const open of stack.splice(k).slice(1)) {
        if (OPTIONAL_TAGS.indexOf(open.name) < 0) out.push(located(text, open.at, severity, "<" + open.name + "> が閉じられていません"));
      }
      continue;
    }
    out.push(located(text, m.index, severity, "</" + m[3] + "> に対応する開始タグがありません"));
    if (strict) return out;
  }
  for (const open of stack) {
    if (strict || OPTIONAL_TAGS.indexOf(open.name) < 0) out.push(located(text, open.at, severity, "<" + open.name + "> が閉じられていません"));
  }
  return out;
}

function yaml(lines) {
  const out = [];
  let stack = [{ indent: -1, keys: new Set() }];
  let scalar = null;
  lines.forEach((line, i) => {
    if (/^\s*$/.test(line)) return;
    const indent = /^ */.exec(line)[0].length;
    if (scalar !== null) {
      if (indent > scalar) return;
      scalar = null;
    }
    if (/^ *\t/.test(line)) return out.push(item(i + 1, 0, "error", "YAML のインデントにタブは使えません"));
    if (/^\s*#/.test(line)) return;
    if (/^(---|\.\.\.)(\s|$)/.test(line)) { stack = [{ indent: -1, keys: new Set() }]; return; }
    const m = /^( *)((?:- +)*)("[^"]*"|'[^']*'|[^\s#'"{\[&*!|>%@`-][^#]*?)\s*:(?:\s+(.*))?$/.exec(line);
    if (!m) {
      if (/^ *- /.test(line) && /[|>][+-]?\s*$/.test(line)) scalar = indent;
      return;
    }
    const at = m[1].length + m[2].length;
    while (stack.length > 1 && stack[stack.length - 1].indent > at) stack.pop();
    if (m[2]) {
      while (stack.length > 1 && stack[stack.length - 1].indent >= at) stack.pop();
      stack.push({ indent: at, keys: new Set() });
    } else if (stack[stack.length - 1].indent < at) {
      stack.push({ indent: at, keys: new Set() });
    }
    const keys = stack[stack.length - 1].keys;
    if (keys.has(m[3])) out.push(item(i + 1, at + 1, "warning", "キー " + m[3] + " が重複しています"));
    keys.add(m[3]);
    if (/^[|>][+-]?\d*\s*(#.*)?$/.test(m[4] || "")) scalar = at;
  });
  return out;
}

function toml(lines) {
  const out = [];
  const tables = new Set();
  let keys = new Set(), depth = 0, multi = false;
  const strings = /"(?:\\.|[^"\\])*"|'[^']*'/g;
  lines.forEach((line, i) => {
    const triples = (line.match(/"""|'''/g) || []).length;
    if (multi) {
      if (triples % 2) multi = false;
      return;
    }
    const plain = line.replace(strings, '""').replace(/#.*$/, "").trim();
    if (depth > 0) {
      depth += (plain.match(/[\[{]/g) || []).length - (plain.match(/[\]}]/g) || []).length;
      return;
    }
    if (!plain) return;
    const table = /^\[\[?([^\]]+)\]\]?$/.exec(plain);
    if (table) {
      if (!plain.startsWith("[[")) {
        if (tables.has(table[1])) out.push(item(i + 1, 0, "error", "テーブル [" + table[1] + "] が重複しています"));
        tables.add(table[1]);
      }
      keys = new Set();
      return;
    }
    const m = /^([^=]+?)\s*=\s*(.*)$/.exec(line.trim());
    if (!m) return out.push(item(i + 1, 0, "error", "「キー = 値」の形式ではありません"));
    if (!m[2].replace(/#.*$/, "").trim()) out.push(item(i + 1, 0, "error", "値がありません"));
    if (keys.has(m[1])) out.push(item(i + 1, 0, "error", "キー " + m[1] + " が重複しています"));
    keys.add(m[1]);
    if (triples % 2) multi = true;
    const value = m[2].replace(strings, '""').replace(/#.*$/, "");
    depth = Math.max((value.match(/[\[{]/g) || []).length - (value.match(/[\]}]/g) || []).length, 0);
  });
  return out;
}

function diagnose(text, ext, name, dir) {
  if (text.length > 400000) return [];
  const lines = text.split("\n").map((l) => l.replace(/\r$/, ""));
  let out = conflicts(lines);
  if (["json", "jsonc", "json5", "geojson"].indexOf(ext) >= 0 || [".babelrc", ".eslintrc", ".prettierrc"].indexOf(name) >= 0) {
    const result = jsonCheck(text, ext !== "json" && ext !== "geojson");
    if (result.error) out.push(located(text, result.error.at, "error", result.error.message));
    return out.concat(result.duplicates.map((d) => located(text, d.at, "warning", d.message)));
  }
  if (["md", "markdown", "mdown", "mkd"].indexOf(ext) >= 0) return out.concat(markdown(lines, dir));
  if (["html", "htm"].indexOf(ext) >= 0) return out.concat(markup(text, false));
  if (["xhtml", "xml", "svg", "plist", "xsd", "xsl", "rss", "atom", "storyboard", "xib"].indexOf(ext) >= 0) return out.concat(markup(text, true));
  if (ext === "yaml" || ext === "yml") return out.concat(yaml(lines));
  if (ext === "toml") return out.concat(toml(lines));
  const language = LEXERS[LANGUAGES[ext]];
  if (!language) return out;
  const masked = mask(text, language);
  out = out.concat(fullWidthSpaces(text, masked));
  if (BRACKET_CHECKED.indexOf(ext) >= 0) out = out.concat(brackets(text, masked));
  if (LANGUAGES[ext] === "python") out = out.concat(mixedIndent(lines));
  return out;
}
