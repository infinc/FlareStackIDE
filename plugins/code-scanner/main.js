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
      for (;;) {
        skip();
        if (text[i] !== '"') fail("キーは \" で囲んだ文字列にしてください");
        string();
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
    if (i >= text.length) return null;
    value();
    skip();
    if (i < text.length) fail("余分な文字があります");
    return null;
  } catch (e) {
    if (e.at === undefined) throw e;
    return e;
  }
}

function diagnose(text, ext, name) {
  if (["json", "jsonc", "json5", "geojson"].indexOf(ext) < 0 && [".babelrc", ".eslintrc", ".prettierrc"].indexOf(name) < 0) return [];
  const loose = ext !== "json" && ext !== "geojson";
  const e = jsonCheck(text, loose);
  if (!e) return [];
  const before = text.slice(0, e.at);
  const line = before.split("\n").length;
  const column = e.at - before.lastIndexOf("\n");
  return [item(line, column, "error", e.message)];
}
