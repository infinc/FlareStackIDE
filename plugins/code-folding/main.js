var INDENT = { py: 1, pyw: 1, pyi: 1, yaml: 1, yml: 1 };
var TAGS = { html: 1, htm: 1, xhtml: 1, xml: 1, svg: 1, plist: 1, xsd: 1, xsl: 1, rss: 1, atom: 1, storyboard: 1, xib: 1, vue: 1, svelte: 1 };
var HEADINGS = { md: 1, markdown: 1, mdown: 1, mkd: 1 };
var HASH = { py: 1, pyw: 1, pyi: 1, yaml: 1, yml: 1, rb: 1, sh: 1, bash: 1, zsh: 1, toml: 1, pl: 1 };
var DASH = { sql: 1, lua: 1 };
var SCRIPT = { js: 1, mjs: 1, cjs: 1, jsx: 1, ts: 1, tsx: 1, mts: 1, cts: 1 };
var SHELL = { sh: 1, bash: 1, zsh: 1 };
var VOID = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };

function mask(text, ext) {
  var out = text.split(""), i = 0, n = text.length, hash = HASH[ext], dash = DASH[ext], previous = "";
  function blank(from, to) {
    for (var k = from; k < to && k < n; k++) if (out[k] !== "\n") out[k] = " ";
  }
  while (i < n) {
    var c = text[i], d = text[i + 1];
    if (dash && c === "-" && d === "-" && text.substr(i, 4) === "--[[") {
      var long = text.indexOf("]]", i + 4);
      long = long < 0 ? n : long + 2;
      blank(i, long);
      i = long;
    } else if ((c === "/" && d === "/" && !hash && !dash) || (dash && c === "-" && d === "-") || (c === "#" && hash && !(SHELL[ext] && i > 0 && !/[\s;]/.test(text[i - 1])))) {
      var end = text.indexOf("\n", i);
      if (end < 0) end = n;
      blank(i, end);
      i = end;
    } else if (c === "/" && d === "*" && !hash) {
      var close = text.indexOf("*/", i + 2);
      close = close < 0 ? n : close + 2;
      blank(i, close);
      i = close;
    } else if (SCRIPT[ext] && c === "/" && /[(,=:\[!&|?{};\n]/.test(previous || "\n") && /^\/(?:\\.|\[(?:\\.|[^\]\n])*\]|[^\/\\\n])+\/[a-z]*/.test(text.slice(i, i + 500))) {
      var literal = /^\/(?:\\.|\[(?:\\.|[^\]\n])*\]|[^\/\\\n])+\/[a-z]*/.exec(text.slice(i, i + 500))[0].length;
      blank(i, i + literal);
      i += literal;
      previous = '"';
    } else if (ext === "rs" && c === "'" && !/^'(\\.[^']*|[^\\'\n])'/.test(text.slice(i, i + 12))) {
      i++;
    } else if (c === '"' || c === "'" || c === "`") {
      var triple = text.substr(i, 3) === c + c + c, quote = triple ? c + c + c : c, j = i + quote.length;
      while (j < n) {
        if (text[j] === "\\") { j += 2; continue; }
        if (text.substr(j, quote.length) === quote) break;
        if (text[j] === "\n" && !triple && c !== "`") break;
        j++;
      }
      j = Math.min(j + quote.length, n);
      blank(i + 1, j);
      i = j;
      previous = '"';
    } else {
      if (" \t\r\n".indexOf(c) < 0) previous = c;
      i++;
    }
  }
  return out.join("");
}

function braces(text, ext) {
  var masked = mask(text, ext), lines = masked.split("\n"), stack = [], found = {}, line = 1;
  for (var i = 0; i < masked.length; i++) {
    var c = masked[i];
    if (c === "\n") line++;
    else if (c === "{" || c === "[" || c === "(") stack.push(line);
    else if ((c === "}" || c === "]" || c === ")") && stack.length) {
      var start = stack.pop(), end = line;
      var rest = lines[end - 1], before = rest.slice(0, rest.indexOf(c) + 1).trim();
      if (before === c && /[{\[(]\s*$/.test(rest)) end--;
      if (end > start && (!found[start] || found[start] < end)) found[start] = end;
    }
  }
  return Object.keys(found).map(function (key) { return [Number(key), found[key]]; });
}

function indents(text, ext) {
  var source = text.split("\n"), lines = mask(text, ext).split("\n"), stack = [], result = [], last = 0;
  function close(indent) {
    while (stack.length && stack[stack.length - 1].indent >= indent) {
      var top = stack.pop();
      if (last > top.line) result.push([top.line, last]);
    }
  }
  for (var i = 0; i < lines.length; i++) {
    var body = lines[i];
    if (!body.trim()) {
      var original = source[i].trim();
      if (original && original[0] !== "#") last = i + 1;
      continue;
    }
    var indent = body.length - body.replace(/^[ \t]+/, "").length;
    close(indent);
    stack.push({ indent: indent, line: i + 1 });
    last = i + 1;
  }
  close(0);
  return result;
}

function tags(text) {
  var pattern = /<!--[\s\S]*?-->|<(\/?)([A-Za-z][\w:.-]*)(?:"[^"]*"|'[^']*'|[^>"'])*?(\/?)>/g, stack = [], result = [], match;
  var line = 1, cursor = 0;
  while ((match = pattern.exec(text))) {
    for (; cursor < match.index; cursor++) if (text[cursor] === "\n") line++;
    if (!match[2]) continue;
    var name = match[2].toLowerCase();
    if (match[1]) {
      for (var k = stack.length - 1; k >= 0; k--) {
        if (stack[k].name === name) {
          var end = line;
          for (var p = match.index; p < match.index + match[0].length; p++) if (text[p] === "\n") end++;
          if (end > stack[k].line) result.push([stack[k].line, end]);
          stack.length = k;
          break;
        }
      }
    } else if (!match[3] && !VOID[name]) {
      stack.push({ name: name, line: line });
    }
  }
  return result;
}

function headings(text) {
  var lines = text.split("\n"), open = [], result = [], fence = null;
  function close(level, before) {
    while (open.length && open[open.length - 1].level >= level) {
      var top = open.pop(), end = before;
      while (end > top.line && !lines[end - 1].trim()) end--;
      if (end > top.line) result.push([top.line, end]);
    }
  }
  for (var i = 0; i < lines.length; i++) {
    var mark = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(lines[i]);
    if (fence) {
      if (mark && mark[1][0] === fence[0] && mark[1].length >= fence.length && !mark[2].trim()) fence = null;
      continue;
    }
    if (mark) { fence = mark[1]; continue; }
    var match = /^(#{1,6})\s/.exec(lines[i]);
    if (!match) continue;
    close(match[1].length, i);
    open.push({ level: match[1].length, line: i + 1 });
  }
  close(1, lines.length);
  return result;
}

function regions(text, ext, name) {
  var result = INDENT[ext] ? indents(text, ext) : TAGS[ext] ? tags(text) : HEADINGS[ext] ? headings(text) : braces(text, ext);
  return result.sort(function (a, b) { return a[0] - b[0]; });
}
