const K = {
  comment: 0, string: 1, number: 2, keyword: 3, type: 4, func: 5, tag: 6, attr: 7, heading: 8,
  emphasis: 9, link: 10, code: 11, meta: 12, variable: 13, constant: 14, property: 15, marker: 16,
};

function palette(dark) {
  return dark
    ? ["#8B949E", "#A5D6FF", "#79C0FF", "#FF7B72", "#FFA657", "#D2A8FF", "#7EE787", "#79C0FF", "#79C0FF",
       "#FFA657", "#58A6FF", "#A5D6FF", "#D2A8FF", "#FFA657", "#79C0FF", "#79C0FF", "#FF7B72"]
    : ["#6E7781", "#0A3069", "#0550AE", "#CF222E", "#953800", "#8250DF", "#116329", "#0550AE", "#0550AE",
       "#953800", "#0969DA", "#0A3069", "#8250DF", "#953800", "#0550AE", "#0550AE", "#CF222E"];
}

const words = (s) => new Set(s.split(/\s+/).filter(Boolean));
const END = "(?![\\s\\S])";
const BLOCK = "\\/\\*[\\s\\S]*?(?:\\*\\/|" + END + ")";
const DQ = '"(?:[^"\\\\\\n]|\\\\.)*"';
const SQ = "'(?:[^'\\\\\\n]|\\\\.)*'";
const BQ = "`(?:[^`\\\\]|\\\\[\\s\\S])*`";
const DQ_ML = '"(?:[^"\\\\]|\\\\[\\s\\S])*"';
const TRIPLE_DQ = '"""[\\s\\S]*?(?:"""|' + END + ")";
const TRIPLE_SQ = "'''[\\s\\S]*?(?:'''|" + END + ")";
const NUMBER = "\\b(?:0[xX][\\da-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)[a-zA-Z]*\\b";
const IDENT = "[A-Za-z_$][\\w$]*";

function nextChar(text, i) {
  while (text[i] === " " || text[i] === "\t") i++;
  return text[i];
}

function identifier(d) {
  return (word, at, text, out, base) => {
    const w = d.caseInsensitive ? word.toLowerCase() : word;
    let kind = -1;
    if (d.keywords.has(w)) kind = K.keyword;
    else if (d.constants && d.constants.has(w)) kind = K.constant;
    else if (d.types && d.types.has(w)) kind = K.type;
    else if (d.variables && d.variables.has(w)) kind = K.variable;
    else if (d.builtins && d.builtins.has(w)) kind = K.func;
    else {
      const next = nextChar(text, at + word.length);
      if (next === "(" || (d.macros && next === "!")) kind = K.func;
      else if (d.capitalTypes !== false && /^[A-Z][A-Z0-9_]+$/.test(word)) kind = K.constant;
      else if (d.capitalTypes !== false && /^[A-Z]/.test(word)) kind = K.type;
    }
    if (kind >= 0) out.push(base + at, word.length, kind);
  };
}

function compile(rules) {
  const starts = [];
  let next = 1;
  const sources = rules.map((r) => {
    const start = next;
    starts.push(start);
    next += new RegExp(r[0] + "|").exec("").length;
    return "(" + r[0].replace(/\\(\d)/g, (_, n) => "\\" + (start + Number(n))) + ")";
  });
  return { re: new RegExp(sources.join("|"), "gm"), starts, actions: rules.map((r) => r[1]) };
}

function run(lex, text, out, base) {
  const re = lex.re;
  const state = { depth: 0 };
  re.lastIndex = 0;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (m[0].length === 0) { re.lastIndex++; continue; }
    let r = 0;
    while (m[lex.starts[r]] === undefined) r++;
    const action = lex.actions[r];
    if (typeof action === "number") out.push(base + m.index, m[0].length, action);
    else action(m[0], m.index, text, out, base, state, re);
  }
}

function withVariables(pattern) {
  const re = new RegExp(pattern, "g");
  return (s, at, text, out, base) => {
    out.push(base + at, s.length, K.string);
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(s)) !== null) out.push(base + at + m.index, m[0].length, K.variable);
  };
}

function clike(d) {
  const rules = [];
  if (d.pre) rules.push(...d.pre);
  if (d.block !== false) rules.push([d.block || BLOCK, K.comment]);
  if (d.line) rules.push([d.line + ".*", K.comment]);
  if (d.preproc) rules.push(["^[ \\t]*#[ \\t]*[A-Za-z]+", K.meta]);
  for (const s of d.strings || [DQ, SQ]) rules.push([s, K.string]);
  if (d.decorator) rules.push(["@[A-Za-z_][\\w.]*", K.meta]);
  if (d.extra) rules.push(...d.extra);
  rules.push([NUMBER, K.number]);
  rules.push([d.ident || IDENT, identifier(d)]);
  return compile(rules);
}

const JS_KEYWORDS = "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return super switch this throw try typeof var void while with yield async await static get set from as";
const JS = {
  keywords: words(JS_KEYWORDS),
  constants: words("true false null undefined NaN Infinity"),
  line: "\\/\\/",
  strings: [BQ, DQ, SQ],
  extra: [["\\/(?![*/])(?:[^\\/\\\\\\n\\[]|\\\\.|\\[(?:[^\\]\\\\\\n]|\\\\.)*\\])+\\/[gimsuyd]*(?=\\s*[;,.)\\]}]|\\s*$)", K.string]],
};
const TS = Object.assign({}, JS, {
  keywords: words(JS_KEYWORDS + " interface type enum implements namespace declare abstract private protected public readonly keyof infer is satisfies module override"),
  types: words("any unknown never string number boolean void object bigint symbol"),
  decorator: true,
});

const LANGS = {
  javascript: () => clike(JS),
  typescript: () => clike(TS),
  json: () => compile([
    ["\\/\\/.*", K.comment],
    [BLOCK, K.comment],
    [DQ, (s, at, text, out, base) => out.push(base + at, s.length, nextChar(text, at + s.length) === ":" ? K.property : K.string)],
    ["-?" + NUMBER, K.number],
    ["\\b(?:true|false|null)\\b", K.constant],
  ]),
  python: () => clike({
    keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
    constants: words("True False None NotImplemented Ellipsis"),
    variables: words("self cls"),
    line: "#",
    block: false,
    strings: ["[rRbBuUfF]{0,2}(?:" + TRIPLE_DQ + "|" + TRIPLE_SQ + ")", "[rRbBuUfF]{0,2}(?:" + DQ + "|" + SQ + ")"],
    decorator: true,
  }),
  java: () => clike({
    keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while var record sealed permits yield non-sealed"),
    types: words("boolean byte char short int long float double void"),
    constants: words("true false null"),
    line: "\\/\\/",
    strings: ['"""[\\s\\S]*?(?:"""|' + END + ")", DQ, SQ],
    decorator: true,
  }),
  kotlin: () => clike({
    keywords: words("as break class continue do else for fun if in interface is object package return super this throw try typealias typeof val var when while by catch constructor finally get import init set where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg value"),
    constants: words("true false null"),
    line: "\\/\\/",
    strings: [TRIPLE_DQ, DQ, SQ],
    decorator: true,
  }),
  swift: () => clike({
    keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws some any super mutating nonmutating override final lazy weak unowned required convenience dynamic optional get set willSet didSet indirect actor nonisolated isolated consume borrowing consuming macro"),
    constants: words("true false nil"),
    variables: words("self Self"),
    line: "\\/\\/",
    strings: [TRIPLE_DQ, DQ],
    decorator: true,
    extra: [["#[A-Za-z]+", K.meta]],
  }),
  c: () => clike(C),
  cpp: () => clike(CPP),
  objc: () => clike(Object.assign({}, C, { decorator: true, strings: ['@?' + DQ, SQ], keywords: words([...C.keywords].join(" ") + " id self super nil YES NO BOOL instancetype") })),
  csharp: () => clike({
    keywords: words("abstract as base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual volatile while var async await dynamic get set value yield record init where nameof required"),
    types: words("bool byte char decimal double float int long object sbyte short string uint ulong ushort void"),
    constants: words("true false null"),
    line: "\\/\\/",
    preproc: true,
    strings: ['@"(?:[^"]|"")*"', "\\$?" + DQ, SQ],
  }),
  go: () => clike({
    keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
    types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any"),
    constants: words("true false nil iota"),
    line: "\\/\\/",
    strings: ["`[^`]*`", DQ, SQ],
  }),
  rust: () => clike({
    keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while macro_rules"),
    types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
    constants: words("true false None Some Ok Err"),
    variables: words("self Self"),
    macros: true,
    line: "\\/\\/",
    strings: ['b?r#*"[\\s\\S]*?"#*', "b?'(?:[^'\\\\\\n]|\\\\.){1,10}'"],
    extra: [["'[A-Za-z_]\\w*", K.variable], ["#!?\\[[^\\]\\n]*\\]", K.meta]],
  }),
  dart: () => clike({
    keywords: words("abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield"),
    constants: words("true false null"),
    line: "\\/\\/",
    strings: [TRIPLE_DQ, TRIPLE_SQ, DQ, SQ],
    decorator: true,
  }),
  ruby: () => clike({
    keywords: words("BEGIN END alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private protected public raise lambda proc puts"),
    constants: words("true false nil"),
    variables: words("self"),
    line: "#",
    block: "^=begin[\\s\\S]*?(?:^=end|" + END + ")",
    strings: [DQ_ML, "'(?:[^'\\\\]|\\\\[\\s\\S])*'"],
    extra: [["(?:@@?|\\$)[A-Za-z_]\\w*", K.variable], [":[A-Za-z_]\\w*[?!]?", K.constant]],
  }),
  php: () => clike({
    keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield enum"),
    constants: words("true false null TRUE FALSE NULL"),
    pre: [["<\\?(?:php|=)?|\\?>", K.meta]],
    line: "(?:\\/\\/|#(?!\\[))",
    strings: [DQ_ML, "'(?:[^'\\\\]|\\\\[\\s\\S])*'"],
    extra: [["\\$[A-Za-z_]\\w*", K.variable], ["#\\[[^\\]\\n]*\\]", K.meta]],
  }),
  lua: () => clike({
    keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
    constants: words("true false nil"),
    pre: [["--\\[(=*)\\[[\\s\\S]*?(?:\\]\\1\\]|" + END + ")", K.comment]],
    block: false,
    line: "--",
    strings: ["\\[(=*)\\[[\\s\\S]*?(?:\\]\\1\\]|" + END + ")", DQ, SQ],
  }),
  shell: () => compile([
    ["^#!.*", K.meta],
    ["(?:^|[ \\t])#.*", K.comment],
    [DQ_ML, withVariables("\\$(?:\\{[^}\\n]*\\}|[A-Za-z_]\\w*|[0-9#?@*$!-])")],
    ["'[^']*'", K.string],
    ["\\$(?:\\{[^}\\n]*\\}|\\(\\(?|[A-Za-z_]\\w*|[0-9#?@*$!-])", K.variable],
    ["\\B--?[A-Za-z][\\w-]*", K.attr],
    [NUMBER, K.number],
    ["[A-Za-z_][\\w-]*", identifier({
      keywords: words("if then else elif fi for while until do done case esac in function select return local export readonly declare unset break continue time"),
      constants: words("true false"),
      builtins: words("echo printf cd ls cat grep sed awk find mkdir rm cp mv chmod chown source exit set test read eval exec trap shift wait kill sudo git npm curl"),
      capitalTypes: false,
    })],
  ]),
  sql: () => clike({
    keywords: words("select from where insert into values update set delete create table drop alter add column primary key foreign references index view join inner left right outer full on as and or not is in between like ilike order by group having limit offset union all distinct case when then else end exists default unique check constraint database schema if begin commit rollback transaction grant revoke with returning asc desc cross natural using replace truncate procedure function trigger declare return returns language"),
    types: words("int integer smallint bigint varchar char text boolean bool date time timestamp timestamptz float real double decimal numeric serial bigserial json jsonb uuid blob"),
    constants: words("true false null"),
    caseInsensitive: true,
    capitalTypes: false,
    line: "--",
    strings: ["'(?:[^']|'')*'", '"(?:[^"]|"")*"', "`[^`]*`"],
  }),
  yaml: () => compile([
    ["(?:^|[ \\t])#.*", K.comment],
    ["^(?:---|\\.\\.\\.)[ \\t]*$", K.marker],
    ["^[ \\t]*(?:-[ \\t]+)*[^\\s#:'\"\\-][^#:\\n]*?(?=:(?:[ \\t]|$))", (s, at, text, out, base) => {
      const lead = s.match(/^[\s-]*/)[0].length;
      out.push(base + at + lead, s.length - lead, K.property);
    }],
    ['"(?:[^"\\\\]|\\\\[\\s\\S])*"', K.string],
    ["'(?:[^']|'')*'", K.string],
    ["[&*][\\w-]+", K.variable],
    ["!!?[\\w/]+", K.meta],
    ["-?" + NUMBER, K.number],
    ["\\b(?:true|false|null|yes|no|on|off|True|False|Null|~)\\b", K.constant],
    ["^[ \\t]*-(?=[ \\t])|[|>][-+]?(?=[ \\t]*$)", K.marker],
  ]),
  toml: () => compile([
    ["#.*", K.comment],
    ["^[ \\t]*\\[\\[?[^\\]\\n]*\\]\\]?", K.type],
    ["^[ \\t]*[\\w.\\-\"']+(?=[ \\t]*=)", K.property],
    [TRIPLE_DQ, K.string], [TRIPLE_SQ, K.string], [DQ, K.string], ["'[^'\\n]*'", K.string],
    ["\\d{4}-\\d{2}-\\d{2}(?:[T ][\\d:.]+(?:Z|[+-]\\d{2}:\\d{2})?)?", K.number],
    ["[+-]?" + NUMBER, K.number],
    ["\\b(?:true|false|inf|nan)\\b", K.constant],
  ]),
  ini: () => compile([
    ["^[ \\t]*[#;].*", K.comment],
    ["^[ \\t]*\\[[^\\]\\n]*\\]", K.type],
    ["^[ \\t]*(?:export[ \\t]+)?[\\w.\\-]+(?=[ \\t]*[=:])", K.property],
    [DQ, K.string], ["'[^'\\n]*'", K.string],
    ["\\$\\{?\\w+\\}?", K.variable],
    ["\\b(?:true|false|yes|no|on|off)\\b", K.constant],
    [NUMBER, K.number],
  ]),
  dockerfile: () => compile([
    ["^[ \\t]*#.*", K.comment],
    ["^[ \\t]*[A-Za-z]+\\b", (s, at, text, out, base) => {
      const word = s.trim();
      if (/^(from|run|cmd|label|maintainer|expose|env|add|copy|entrypoint|volume|user|workdir|arg|onbuild|stopsignal|healthcheck|shell)$/i.test(word)) {
        out.push(base + at + s.indexOf(word), word.length, K.keyword);
      }
    }],
    ["\\b[Aa][Ss]\\b", K.keyword],
    [DQ, K.string], [SQ, K.string],
    ["\\$\\{?\\w+\\}?", K.variable],
    ["\\B--[\\w-]+", K.attr],
    [NUMBER, K.number],
  ]),
  makefile: () => compile([
    ["#.*", K.comment],
    ["^[ \\t]*(?:ifeq|ifneq|ifdef|ifndef|else|endif|include|-include|define|endef|export|override)\\b", K.keyword],
    ["^[\\w.\\-]+(?=[ \\t]*(?:[:+?!]?=))", K.variable],
    ["^[^\\s:#=][^:#=\\n]*(?=:(?!=))", K.func],
    ["\\$(?:\\([^)\\n]*\\)|\\{[^}\\n]*\\}|[@<^+?*%])", K.variable],
    [DQ, K.string], [SQ, K.string],
  ]),
  css: () => css(false),
  scss: () => css(true),
};

const C = {
  keywords: words("auto break case const continue default do else enum extern for goto if inline register restrict return signed sizeof static struct switch typedef union unsigned volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local"),
  types: words("char double float int long short void bool _Bool size_t ssize_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t FILE"),
  constants: words("NULL true false"),
  line: "\\/\\/",
  preproc: true,
  extra: [["<[\\w./]+\\.h>", K.string]],
};
const CPP = Object.assign({}, C, {
  keywords: words([...C.keywords].join(" ") + " alignas alignof and asm catch class constexpr consteval constinit const_cast decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not nullptr operator or private protected public reinterpret_cast static_assert static_cast template this thread_local throw try typeid typename using virtual override final co_await co_return co_yield concept requires"),
  types: words([...C.types].join(" ") + " wchar_t char8_t char16_t char32_t std string vector map auto"),
  constants: words("NULL true false nullptr"),
  extra: [["<[\\w./]+>", K.string]],
  strings: ['R"([^(\\s]*)\\([\\s\\S]*?\\)\\1"', DQ, SQ],
});

function css(scss) {
  const rules = [];
  rules.push([BLOCK, K.comment]);
  if (scss) rules.push(["\\/\\/.*", K.comment]);
  rules.push([DQ, K.string], [SQ, K.string]);
  rules.push(["[{}]", (s, at, text, out, base, state) => { state.depth = Math.max(0, state.depth + (s === "{" ? 1 : -1)); }]);
  rules.push(["@[\\w-]+", K.meta]);
  rules.push(["!important", K.keyword]);
  if (scss) rules.push(["\\$[\\w-]+", K.variable]);
  rules.push(["--[\\w-]+", K.variable]);
  rules.push(["#[\\w-]+", (s, at, text, out, base, state) => {
    const value = /^#[\da-fA-F]{3,8}$/.test(s) && /:\s*$/.test(text.slice(Math.max(0, at - 30), at));
    out.push(base + at, s.length, value || !selector(text, at, state) ? K.number : K.attr);
  }]);
  rules.push(["-?(?:\\d*\\.)?\\d+(?:%|[a-zA-Z]+)?", K.number]);
  rules.push(["\\.[A-Za-z_-][\\w-]*", (s, at, text, out, base, state) => { if (selector(text, at, state)) out.push(base + at, s.length, K.type); }]);
  rules.push(["::?[A-Za-z-]+", (s, at, text, out, base, state) => { if (selector(text, at, state)) out.push(base + at, s.length, K.keyword); }]);
  rules.push(["-?[A-Za-z_][\\w-]*", (s, at, text, out, base, state) => {
    if (selector(text, at, state)) out.push(base + at, s.length, K.tag);
    else if (nextChar(text, at + s.length) === "(") out.push(base + at, s.length, K.func);
    else if (nextChar(text, at + s.length) === ":") out.push(base + at, s.length, K.property);
  }]);
  return compile(rules);
}

function selector(text, at, state) {
  if (state.depth === 0) return true;
  const end = Math.min(text.length, at + 400);
  for (let i = at; i < end; i++) {
    const c = text[i];
    if (c === "{") return true;
    if (c === ";" || c === "}") return false;
  }
  return false;
}

function markup(text, out, base, html) {
  const re = /<!--[\s\S]*?(?:-->|(?![\s\S]))|<!\[CDATA\[[\s\S]*?(?:\]\]>|(?![\s\S]))|<![A-Za-z][^>]*>?|<\?[\s\S]*?(?:\?>|(?![\s\S]))|<\/?[A-Za-z][\w:.-]*(?:[^>"']|"[^"]*"|'[^']*')*>?|&#?\w+;/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const s = m[0], at = m.index;
    if (s.startsWith("<!--")) { out.push(base + at, s.length, K.comment); continue; }
    if (s.startsWith("<![CDATA[")) { out.push(base + at, s.length, K.string); continue; }
    if (s.startsWith("<!") || s.startsWith("<?")) { out.push(base + at, s.length, K.meta); continue; }
    if (s.startsWith("&")) { out.push(base + at, s.length, K.constant); continue; }
    const name = tag(s, at, out, base);
    if (!html || s[1] === "/" || s.endsWith("/>")) continue;
    const lower = name.toLowerCase();
    if (lower !== "script" && lower !== "style") continue;
    const close = text.toLowerCase().indexOf("</" + lower, re.lastIndex);
    const end = close < 0 ? text.length : close;
    let lang = lower === "style" ? "css" : "javascript";
    if (lower === "script" && /type\s*=\s*["']?(?:text\/(?:template|html)|module\/html)/i.test(s)) lang = "html";
    if (lower === "script" && /lang\s*=\s*["']?ts/i.test(s)) lang = "typescript";
    tokenize(lang, text.slice(re.lastIndex, end), out, base + re.lastIndex);
    re.lastIndex = end;
  }
}

function tag(s, at, out, base) {
  const head = /^<\/?([\w:.-]+)/.exec(s);
  const start = s[1] === "/" ? 2 : 1;
  out.push(base + at, start, K.marker);
  out.push(base + at + start, head[1].length, K.tag);
  const attrs = /([^\s=>\/"']+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?/g;
  attrs.lastIndex = start + head[1].length;
  let a;
  while ((a = attrs.exec(s)) !== null) {
    out.push(base + at + a.index, a[1].length, K.attr);
    if (a[2]) out.push(base + at + a.index + a[0].length - a[2].length, a[2].length, K.string);
  }
  if (s.endsWith(">")) out.push(base + at + s.length - (s.endsWith("/>") ? 2 : 1), s.endsWith("/>") ? 2 : 1, K.marker);
  return head[1];
}

const MD_INLINE = compile([
  ["(`+)[^`\\n][\\s\\S]*?\\1", K.code],
  ["!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)|!?\\[[^\\]\\n]*\\]\\[[^\\]\\n]*\\]", K.link],
  ["<https?:[^>\\s]+>|\\bhttps?:\\/\\/[^\\s)<>]+", K.link],
  ["\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__|\\*[^*\\s][^*\\n]*\\*|~~[^~\\n]+~~", K.emphasis],
  ["<\\/?[A-Za-z][^>\\n]*>", K.tag],
]);

function markdown(text, out, base) {
  let pos = 0, fence = null, first = true;
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], at = pos;
    pos += line.length + 1;
    if (first && line === "---") {
      const close = lines.indexOf("---", i + 1);
      if (close > 0) {
        let end = at;
        for (let j = i; j <= close; j++) end += lines[j].length + 1;
        out.push(base + at, end - at - 1, K.meta);
        pos = end;
        i = close;
        first = false;
        continue;
      }
    }
    first = false;
    const open = /^\s*(`{3,}|~{3,})\s*([\w+#.-]*)/.exec(line);
    if (fence) {
      if (open && open[1][0] === fence.mark[0] && open[1].length >= fence.mark.length && !open[2]) {
        const body = text.slice(fence.start, at);
        const lang = detect(fence.lang, fence.lang);
        if (lang) tokenize(lang, body, out, base + fence.start);
        else out.push(base + fence.start, body.length, K.code);
        out.push(base + at, line.length, K.marker);
        fence = null;
      }
      continue;
    }
    if (open) {
      fence = { mark: open[1], lang: open[2].toLowerCase(), start: pos };
      out.push(base + at, line.length, K.marker);
      continue;
    }
    if (/^ {0,3}#{1,6}(\s|$)/.test(line)) { out.push(base + at, line.length, K.heading); continue; }
    if (/^ {0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) { out.push(base + at, line.length, K.marker); continue; }
    if (/^ {0,3}(=+|-+)\s*$/.test(line) && i > 0 && lines[i - 1].trim()) { out.push(base + at, line.length, K.heading); continue; }
    let rest = 0;
    const quote = /^ {0,3}>+\s?/.exec(line);
    if (quote) {
      out.push(base + at, line.length, K.comment);
      out.push(base + at, quote[0].length, K.marker);
      rest = quote[0].length;
    }
    const list = /^(\s*)([-*+]|\d+[.)])(\s+)(\[[ xX]\]\s)?/.exec(line.slice(rest));
    if (list) {
      out.push(base + at + rest + list[1].length, list[2].length, K.marker);
      if (list[4]) out.push(base + at + rest + list[1].length + list[2].length + list[3].length, 3, K.keyword);
      rest += list[0].length;
    }
    if (/^\s*\|/.test(line)) {
      const pipes = /\|/g;
      let p;
      while ((p = pipes.exec(line)) !== null) out.push(base + at + p.index, 1, K.marker);
    }
    run(MD_INLINE, line.slice(rest), out, base + at + rest);
  }
  if (fence) out.push(base + fence.start, text.length - fence.start, K.code);
}

const CUSTOM = {
  html: (text, out, base) => markup(text, out, base, true),
  xml: (text, out, base) => markup(text, out, base, false),
  markdown,
};

const EXTENSIONS = {
  html: "html", htm: "html", xhtml: "html", vue: "html", svelte: "html",
  xml: "xml", svg: "xml", plist: "xml", xsd: "xml", xsl: "xml", rss: "xml", atom: "xml", storyboard: "xml", xib: "xml",
  css: "css", scss: "scss", less: "scss", sass: "scss",
  js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "javascript", javascript: "javascript",
  ts: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript", typescript: "typescript",
  json: "json", jsonc: "json", json5: "json", geojson: "json", ".babelrc": "json", ".prettierrc": "json", ".eslintrc": "json",
  py: "python", pyw: "python", pyi: "python", python: "python",
  java: "java", kt: "kotlin", kts: "kotlin", kotlin: "kotlin", swift: "swift",
  c: "c", h: "c", cpp: "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp", hxx: "cpp", ino: "cpp", "c++": "cpp",
  m: "objc", mm: "objc", objc: "objc", "objective-c": "objc",
  cs: "csharp", csharp: "csharp", go: "go", golang: "go", rs: "rust", rust: "rust", dart: "dart",
  rb: "ruby", rake: "ruby", gemspec: "ruby", ruby: "ruby", gemfile: "ruby", rakefile: "ruby", podfile: "ruby",
  php: "php", lua: "lua",
  sh: "shell", bash: "shell", zsh: "shell", ksh: "shell", shell: "shell", console: "shell",
  ".bashrc": "shell", ".zshrc": "shell", ".profile": "shell", ".bash_profile": "shell", ".zprofile": "shell",
  sql: "sql", yaml: "yaml", yml: "yaml", toml: "toml",
  ini: "ini", cfg: "ini", conf: "ini", properties: "ini", env: "ini", ".env": "ini", ".gitconfig": "ini", ".editorconfig": "ini",
  md: "markdown", markdown: "markdown", mdown: "markdown", mkd: "markdown",
  dockerfile: "dockerfile", docker: "dockerfile", makefile: "makefile", mk: "makefile", make: "makefile",
};

function detect(ext, name) {
  return EXTENSIONS[name] || EXTENSIONS[ext] || (name && name.startsWith("dockerfile") ? "dockerfile" : null);
}

const compiled = {};

function tokenize(lang, text, out, base) {
  if (CUSTOM[lang]) return CUSTOM[lang](text, out, base);
  if (!compiled[lang]) compiled[lang] = LANGS[lang]();
  run(compiled[lang], text, out, base);
}

function highlight(text, ext, name) {
  const lang = detect(ext, name);
  if (!lang) return [];
  const out = [];
  tokenize(lang, text, out, 0);
  return out;
}
