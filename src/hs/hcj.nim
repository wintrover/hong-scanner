## HCJ (Hong Canonical JSON) — strict scanner + canonical encoder.
##
## Domain rules (docs/research/json-canonicalization.md §3):
##   - allowed types: object, array, string, integer, true, false, null
##   - forbidden: float literals (`.`, `e`, `E`), `+` sign, leading zeros,
##     |integer| > 2^53-1 (9007199254740991), duplicate keys, lone
##     surrogates, U+007F (DEL), invalid UTF-8, raw control chars in strings
##   - keys (strict mode): exactly [A-Za-z0-9_-]
##   - canonical object key order: codepoint ascending == UTF-8 byte order
##   - string escaping: \b \t \n \f \r \" \\ shortcuts; other U+0000-U+001F
##     as lowercase `\u00xx`; everything else raw (no unicode normalization)
##
## Line discipline for `.hcj.jsonl` files (input/signals/bars):
##   one record per line, each line is the canonical serialization + LF;
##   the last line also ends with LF; BOM, CRLF and empty lines are rejected.
## Fixture files (meta.json, calendars/*.json, legacy events.jsonl) are read
## as whitespace-tolerant JSON documents; the canonical writer is the only
## producer of line discipline files.
import std/[algorithm, strutils, options]

type
  HcjKind* = enum hkNull, hkBool, hkInt, hkStr, hkArr, hkObj
  HcjPair* = tuple[k: string, v: HcjValue]
  HcjValue* = ref object
    case kind*: HcjKind
    of hkNull: nil
    of hkBool: bval*: bool
    of hkInt: ival*: int64
    of hkStr: strVal*: string
    of hkArr: items*: seq[HcjValue]
    of hkObj: pairs*: seq[HcjPair]

  HcjError* = object of CatchableError

const
  maxIntSafe* = 9007199254740991'i64
  minIntSafe* = -9007199254740991'i64
  maxDepth = 128

proc newHcjError*(msg: string): ref HcjError =
  result = newException(HcjError, msg)

proc kindName*(v: HcjValue): string =
  case v.kind
  of hkNull: "null"
  of hkBool: "bool"
  of hkInt: "int"
  of hkStr: "string"
  of hkArr: "array"
  of hkObj: "object"

# ---------------------------------------------------------------- constructors

proc hNull*(): HcjValue = HcjValue(kind: hkNull)

proc hBool*(b: bool): HcjValue = HcjValue(kind: hkBool, bval: b)

proc hInt*(i: int64): HcjValue =
  if i < minIntSafe or i > maxIntSafe:
    raise newHcjError("integer out of HCJ safe range: " & $i)
  result = HcjValue(kind: hkInt, ival: i)

proc hInt*(i: int): HcjValue = hInt(i.int64)

proc validateHcjString(s: string, what: string) =
  var i = 0
  while i < s.len:
    let b = byte(s[i])
    if b < 0x20'u8:
      raise newHcjError("raw control char in " & what)
    if b == 0x7f'u8:
      raise newHcjError("DEL (U+007F) in " & what)
    if b < 0x80'u8:
      inc i
    else:
      let n = if b >= 0xf0'u8: 4 elif b >= 0xe0'u8: 3 else: 2
      if i + n > s.len:
        raise newHcjError("truncated UTF-8 in " & what)
      case b
      of 0xc2'u8 .. 0xdf'u8: discard
      of 0xe0'u8:
        if not (byte(s[i + 1]) >= 0xa0'u8 and byte(s[i + 1]) <= 0xbf'u8):
          raise newHcjError("invalid UTF-8 in " & what)
      of 0xe1'u8 .. 0xec'u8, 0xee'u8 .. 0xef'u8:
        discard
      of 0xed'u8:
        if not (byte(s[i + 1]) >= 0x80'u8 and byte(s[i + 1]) <= 0x9f'u8):
          raise newHcjError("UTF-8 surrogate in " & what)
      of 0xf0'u8:
        if not (byte(s[i + 1]) >= 0x90'u8 and byte(s[i + 1]) <= 0xbf'u8):
          raise newHcjError("invalid UTF-8 in " & what)
      of 0xf1'u8 .. 0xf3'u8:
        discard
      of 0xf4'u8:
        if not (byte(s[i + 1]) >= 0x80'u8 and byte(s[i + 1]) <= 0x8f'u8):
          raise newHcjError("invalid UTF-8 in " & what)
      else:
        raise newHcjError("invalid UTF-8 lead byte in " & what)
      for j in 1 ..< n:
        if (byte(s[i + j]) and 0xc0'u8) != 0x80'u8:
          raise newHcjError("invalid UTF-8 continuation in " & what)
      inc i, n

proc hStr*(s: string): HcjValue =
  validateHcjString(s, "string value")
  result = HcjValue(kind: hkStr, strVal: s)

proc hArr*(items: varargs[HcjValue]): HcjValue =
  var xs: seq[HcjValue] = @[]
  for x in items: xs.add(x)
  result = HcjValue(kind: hkArr, items: xs)

proc hArrSeq*(items: seq[HcjValue]): HcjValue =
  result = HcjValue(kind: hkArr, items: items)

proc hObj*(pairs: varargs[HcjPair]): HcjValue =
  for i in 0 ..< pairs.len:
    if pairs[i][0].len == 0:
      raise newHcjError("empty key in object")
    for b in pairs[i][0].items:
      let c = byte(b)
      let okKey = (c >= 'a'.byte and c <= 'z'.byte) or
                  (c >= 'A'.byte and c <= 'Z'.byte) or
                  (c >= '0'.byte and c <= '9'.byte) or c == '_'.byte or c == '-'.byte
      if not okKey:
        raise newHcjError("key not [A-Za-z0-9_-]: " & pairs[i][0])
    for j in 0 ..< i:
      if pairs[j][0] == pairs[i][0]:
        raise newHcjError("duplicate key: " & pairs[i][0])
  result = HcjValue(kind: hkObj, pairs: @pairs)

# ---------------------------------------------------------------- accessors

proc getOpt*(v: HcjValue, key: string): Option[HcjValue] =
  if v.kind != hkObj:
    raise newHcjError("expected object, got " & v.kindName)
  for p in v.pairs:
    if p.k == key: return some(p.v)
  result = none(HcjValue)

proc get*(v: HcjValue, key: string): HcjValue =
  let o = v.getOpt(key)
  if o.isNone:
    raise newHcjError("missing key: " & key)
  result = o.get

proc has*(v: HcjValue, key: string): bool =
  v.kind == hkObj and v.getOpt(key).isSome

proc asStr*(v: HcjValue): string =
  if v.kind != hkStr: raise newHcjError("expected string, got " & v.kindName)
  result = v.strVal

proc asInt*(v: HcjValue): int64 =
  if v.kind != hkInt: raise newHcjError("expected int, got " & v.kindName)
  result = v.ival

proc asBool*(v: HcjValue): bool =
  if v.kind != hkBool: raise newHcjError("expected bool, got " & v.kindName)
  result = v.bval

proc isNull*(v: HcjValue): bool = v.kind == hkNull

# ---------------------------------------------------------------- encoder

proc writeString(s: string, outp: var string) =
  outp.add('"')
  const hexDigits = "0123456789abcdef"
  for i in 0 ..< s.len:
    let b = byte(s[i])
    case b
    of 0x08'u8: outp.add("\\b")
    of 0x09'u8: outp.add("\\t")
    of 0x0a'u8: outp.add("\\n")
    of 0x0c'u8: outp.add("\\f")
    of 0x0d'u8: outp.add("\\r")
    of 0x22'u8: outp.add("\\\"")
    of 0x5c'u8: outp.add("\\\\")
    else:
      if b < 0x20'u8:
        outp.add("\\u00")
        outp.add(hexDigits[int(b shr 4)])
        outp.add(hexDigits[int(b and 0x0f'u8)])
      else:
        outp.add(char(b))
  outp.add('"')

proc pairKeyCmp(x, y: HcjPair): int = cmp(x[0], y[0])

proc writeValue*(v: HcjValue, outp: var string) =
  case v.kind
  of hkNull: outp.add("null")
  of hkBool:
    if v.bval: outp.add("true") else: outp.add("false")
  of hkInt: outp.add($v.ival)
  of hkStr: writeString(v.strVal, outp)
  of hkArr:
    outp.add('[')
    for i, x in v.items:
      if i > 0: outp.add(',')
      writeValue(x, outp)
    outp.add(']')
  of hkObj:
    var ps = v.pairs
    ps.sort(pairKeyCmp)
    outp.add('{')
    for i, p in ps:
      if i > 0: outp.add(',')
      writeString(p.k, outp)
      outp.add(':')
      writeValue(p.v, outp)
    outp.add('}')

proc canonical*(v: HcjValue): string =
  result = ""
  writeValue(v, result)

proc canonicalFileBytes*(lines: seq[string]): string =
  ## Canonical bytes of a line-per-record file: each line + LF.
  result = ""
  for l in lines:
    result.add(l)
    result.add('\n')

# ---------------------------------------------------------------- parser

type
  Parser = object
    s: string
    pos: int
    depth: int

proc perr(p: Parser, msg: string): ref HcjError =
  newHcjError(msg & " at offset " & $p.pos)

proc skipWs(p: var Parser) =
  while p.pos < p.s.len:
    case p.s[p.pos]
    of ' ', '\t', '\n', '\r': inc p.pos
    else: break

proc peekChar(p: Parser): char =
  if p.pos < p.s.len: p.s[p.pos] else: '\0'

proc expect(p: var Parser, c: char) =
  if p.pos >= p.s.len or p.s[p.pos] != c:
    raise perr(p, "expected '" & c & "'")
  inc p.pos

proc addUtf8(outp: var string, cp: int) =
  if cp < 0x80:
    outp.add(char(cp))
  elif cp < 0x800:
    outp.add(char(0xc0 or (cp shr 6)))
    outp.add(char(0x80 or (cp and 0x3f)))
  elif cp < 0x10000:
    outp.add(char(0xe0 or (cp shr 12)))
    outp.add(char(0x80 or ((cp shr 6) and 0x3f)))
    outp.add(char(0x80 or (cp and 0x3f)))
  else:
    outp.add(char(0xf0 or (cp shr 18)))
    outp.add(char(0x80 or ((cp shr 12) and 0x3f)))
    outp.add(char(0x80 or ((cp shr 6) and 0x3f)))
    outp.add(char(0x80 or (cp and 0x3f)))

proc hexVal(c: char): int =
  case c
  of '0' .. '9': result = ord(c) - ord('0')
  of 'a' .. 'f': result = ord(c) - ord('a') + 10
  of 'A' .. 'F': result = ord(c) - ord('A') + 10
  else: raise newHcjError("invalid hex digit in \\u escape: " & $c)

proc parseHex4(p: var Parser): int =
  if p.pos + 4 > p.s.len:
    raise perr(p, "truncated \\u escape")
  result = hexVal(p.s[p.pos]) shl 12 or hexVal(p.s[p.pos + 1]) shl 8 or
           hexVal(p.s[p.pos + 2]) shl 4 or hexVal(p.s[p.pos + 3])
  inc p.pos, 4

proc parseStringRaw(p: var Parser): string =
  expect(p, '"')
  result = newStringOfCap(16)
  while true:
    if p.pos >= p.s.len:
      raise perr(p, "unterminated string")
    let c = p.s[p.pos]
    if c == '"':
      inc p.pos
      break
    if c == '\\':
      inc p.pos
      if p.pos >= p.s.len:
        raise perr(p, "unterminated escape")
      let e = p.s[p.pos]
      inc p.pos
      case e
      of '"': result.add('"')
      of '\\': result.add('\\')
      of '/': result.add('/')
      of 'b': result.add(chr(8))
      of 'f': result.add(chr(12))
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      of 'u':
        let cp = parseHex4(p)
        if cp >= 0xd800 and cp <= 0xdbff:
          if p.pos + 2 > p.s.len or p.s[p.pos] != '\\' or p.s[p.pos + 1] != 'u':
            raise perr(p, "lone high surrogate")
          inc p.pos, 2
          let cp2 = parseHex4(p)
          if cp2 < 0xdc00 or cp2 > 0xdfff:
            raise perr(p, "invalid surrogate pair")
          let code = 0x10000 + ((cp - 0xd800) shl 10) + (cp2 - 0xdc00)
          addUtf8(result, code)
        elif cp >= 0xdc00 and cp <= 0xdfff:
          raise perr(p, "lone low surrogate")
        else:
          addUtf8(result, cp)
      else:
        raise perr(p, "invalid escape: \\" & $e)
    else:
      let b = byte(c)
      if b < 0x20'u8:
        raise perr(p, "raw control char in string")
      if b == 0x7f'u8:
        raise perr(p, "DEL (U+007F) in string")
      if b < 0x80'u8:
        result.add(c)
        inc p.pos
      else:
        let n = if b >= 0xf0'u8: 4 elif b >= 0xe0'u8: 3 else: 2
        if p.pos + n > p.s.len:
          raise perr(p, "truncated UTF-8 sequence")
        if b == 0xc0'u8 or b == 0xc1'u8 or b >= 0xf5'u8:
          raise perr(p, "invalid UTF-8 lead byte")
        if b == 0xed'u8 and byte(p.s[p.pos + 1]) >= 0xa0'u8:
          raise perr(p, "UTF-8 encoded surrogate")
        for j in 1 ..< n:
          if (byte(p.s[p.pos + j]) and 0xc0'u8) != 0x80'u8:
            raise perr(p, "invalid UTF-8 continuation")
        for j in 0 ..< n:
          result.add(p.s[p.pos + j])
        inc p.pos, n
  validateHcjString(result, "parsed string")

proc parseNumber(p: var Parser): int64 =
  let start = p.pos
  var neg = false
  if p.peekChar() == '-':
    neg = true
    inc p.pos
  if p.pos >= p.s.len:
    raise perr(p, "truncated number")
  if p.s[p.pos] == '0':
    inc p.pos
    if p.pos < p.s.len and p.s[p.pos] in '0' .. '9':
      raise perr(p, "leading zero in number")
  elif p.s[p.pos] in '1' .. '9':
    while p.pos < p.s.len and p.s[p.pos] in '0' .. '9':
      inc p.pos
  else:
    raise perr(p, "invalid number start")
  if p.pos < p.s.len and p.s[p.pos] in {'.', 'e', 'E'}:
    raise perr(p, "float literal forbidden")
  var v: int64 = 0
  for i in (start + (if neg: 1 else: 0)) ..< p.pos:
    let d = int64(ord(p.s[i]) - ord('0'))
    if v > (high(int64) - d) div 10:
      raise perr(p, "integer overflow")
    v = v * 10 + d
  result = if neg: -v else: v
  if result < minIntSafe or result > maxIntSafe:
    raise perr(p, "integer exceeds 2^53-1")

proc parseValue(p: var Parser): HcjValue

proc parseObject(p: var Parser): HcjValue =
  expect(p, '{')
  var pairs: seq[HcjPair] = @[]
  p.skipWs()
  if p.peekChar() == '}':
    inc p.pos
    return HcjValue(kind: hkObj, pairs: pairs)
  while true:
    p.skipWs()
    if p.peekChar() != '"':
      raise perr(p, "expected object key string")
    let key = p.parseStringRaw()
    for b in key.items:
      let c = byte(b)
      let okKey = (c >= 'a'.byte and c <= 'z'.byte) or
                  (c >= 'A'.byte and c <= 'Z'.byte) or
                  (c >= '0'.byte and c <= '9'.byte) or c == '_'.byte or c == '-'.byte
      if not okKey:
        raise perr(p, "key not [A-Za-z0-9_-]: " & key)
    for pr in pairs:
      if pr.k == key:
        raise perr(p, "duplicate key: " & key)
    p.skipWs()
    expect(p, ':')
    let v = p.parseValue()
    pairs.add((key, v))
    p.skipWs()
    if p.peekChar() == ',':
      inc p.pos
    elif p.peekChar() == '}':
      inc p.pos
      break
    else:
      raise perr(p, "expected ',' or '}' in object")
  result = HcjValue(kind: hkObj, pairs: pairs)

proc parseArray(p: var Parser): HcjValue =
  expect(p, '[')
  var xs: seq[HcjValue] = @[]
  p.skipWs()
  if p.peekChar() == ']':
    inc p.pos
    return HcjValue(kind: hkArr, items: xs)
  while true:
    let v = p.parseValue()
    xs.add(v)
    p.skipWs()
    if p.peekChar() == ',':
      inc p.pos
    elif p.peekChar() == ']':
      inc p.pos
      break
    else:
      raise perr(p, "expected ',' or ']' in array")
  result = HcjValue(kind: hkArr, items: xs)

proc parseValue(p: var Parser): HcjValue =
  inc p.depth
  if p.depth > maxDepth:
    raise perr(p, "nesting depth limit exceeded")
  defer: dec p.depth
  p.skipWs()
  if p.pos >= p.s.len:
    raise perr(p, "unexpected end of input")
  case p.s[p.pos]
  of '{': result = p.parseObject()
  of '[': result = p.parseArray()
  of '"':
    result = HcjValue(kind: hkStr, strVal: p.parseStringRaw())
  of 't':
    if p.s.substr(p.pos, p.pos + 3) != "true":
      raise perr(p, "invalid literal")
    inc p.pos, 4
    result = HcjValue(kind: hkBool, bval: true)
  of 'f':
    if p.s.substr(p.pos, p.pos + 4) != "false":
      raise perr(p, "invalid literal")
    inc p.pos, 5
    result = HcjValue(kind: hkBool, bval: false)
  of 'n':
    if p.s.substr(p.pos, p.pos + 3) != "null":
      raise perr(p, "invalid literal")
    inc p.pos, 4
    result = HcjValue(kind: hkNull)
  of '-', '0' .. '9':
    result = HcjValue(kind: hkInt, ival: p.parseNumber())
  else:
    raise perr(p, "unexpected character: " & $p.s[p.pos])

proc parseDoc*(s: string): HcjValue =
  ## Parse one whitespace-tolerant JSON document (strict HCJ domain rules).
  var p = Parser(s: s, pos: 0, depth: 0)
  result = p.parseValue()
  p.skipWs()
  if p.pos != p.s.len:
    raise perr(p, "trailing content after document")

proc parseLine*(line: string): HcjValue =
  ## Parse one line as a single HCJ document (trailing whitespace allowed).
  result = parseDoc(line)

proc readHcjTextLines*(path: string): seq[string] =
  ## Read a canonical line-per-record file, enforcing line discipline and
  ## returning the raw lines (byte-exact, LF not included).
  let content = readFile(path)
  if content.len == 0:
    return @[]
  if content.len >= 3 and content[0] == '\xef' and content[1] == '\xbb' and content[2] == '\xbf':
    raise newHcjError("BOM not allowed: " & path)
  if not content.endsWith("\n"):
    raise newHcjError("last line must end with LF: " & path)
  let parts = content.split('\n')
  # content ends with '\n' so the final split element is the empty terminator
  for i in 0 ..< parts.len - 1:
    let line = parts[i]
    if line.len == 0 or line.strip().len == 0:
      raise newHcjError("empty line at " & $i & ": " & path)
    if '\r' in line:
      raise newHcjError("CR (CRLF?) in line " & $i & ": " & path)
    result.add(line)

proc readHcjLines*(path: string): seq[HcjValue] =
  ## Read a canonical line-per-record file, enforcing line discipline.
  for line in readHcjTextLines(path):
    result.add(parseLine(line))

proc readDocFile*(path: string): HcjValue =
  ## Read a whole file as one whitespace-tolerant JSON document (fixtures).
  let content = readFile(path)
  if content.len >= 3 and content[0] == '\xef' and content[1] == '\xbb' and content[2] == '\xbf':
    raise newHcjError("BOM not allowed: " & path)
  result = parseDoc(content)

proc readJsonlLenient*(path: string): seq[HcjValue] =
  ## Read a legacy JSONL file (e.g. the G3a smoke events log): one JSON
  ## document per line; a missing final LF is tolerated (the G3a fixture
  ## predates the LF-terminated discipline).
  let content = readFile(path)
  if content.len == 0:
    return @[]
  let parts = content.split('\n')
  for i in 0 ..< parts.len:
    let line = parts[i]
    if line.strip().len == 0:
      if i == parts.len - 1 and not content.endsWith("\n\n"):
        continue # terminator element after a file ending with a single LF
      if i == parts.len - 1:
        continue
      raise newHcjError("empty line at " & $i & ": " & path)
    result.add(parseDoc(line))
