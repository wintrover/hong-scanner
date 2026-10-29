## Pure-Nim SHA-256 (FIPS 180-4).
##
## No external package is used so that `nimble test` and CI need no package
## downloads (hermetic). Correctness is pinned by NIST test vectors in
## tests/tdigest.nim, cross-checked against coreutils `sha256sum`.
import std/[algorithm, strutils]

type
  Sha256* = object
    h: array[8, uint32]
    buf: array[64, byte]
    bufLen: int
    byteLen: uint64

const k256: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32,
]

proc initSha256*(s: var Sha256) =
  s.h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
         0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  s.bufLen = 0
  s.byteLen = 0'u64

proc rotr(x: uint32, n: uint32): uint32 {.inline.} =
  (x shr n) or (x shl (32'u32 - n))

{.push overflowChecks: off.}
proc compress(s: var Sha256, chunk: openArray[byte]) =
  var w: array[64, uint32]
  for i in 0 ..< 16:
    let j = i * 4
    w[i] = (chunk[j].uint32 shl 24) or (chunk[j + 1].uint32 shl 16) or
           (chunk[j + 2].uint32 shl 8) or chunk[j + 3].uint32
  for i in 16 ..< 64:
    let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
    let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  var a = s.h[0]
  var b = s.h[1]
  var c = s.h[2]
  var d = s.h[3]
  var e = s.h[4]
  var f = s.h[5]
  var g = s.h[6]
  var h = s.h[7]
  for i in 0 ..< 64:
    let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let t1 = h + s1 + ch + k256[i] + w[i]
    let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
    let maj = (a and b) xor (a and c) xor (b and c)
    let t2 = s0 + maj
    h = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  s.h[0] += a
  s.h[1] += b
  s.h[2] += c
  s.h[3] += d
  s.h[4] += e
  s.h[5] += f
  s.h[6] += g
  s.h[7] += h
{.pop.}

proc update*(s: var Sha256, data: openArray[byte]) =
  s.byteLen += uint64(len(data))
  var i = 0
  if s.bufLen > 0:
    while i < len(data) and s.bufLen < 64:
      s.buf[s.bufLen] = data[i]
      inc s.bufLen
      inc i
    if s.bufLen == 64:
      compress(s, s.buf)
      s.bufLen = 0
  while i + 64 <= len(data):
    compress(s, data.toOpenArray(i, i + 63))
    i += 64
  while i < len(data):
    s.buf[s.bufLen] = data[i]
    inc s.bufLen
    inc i

proc finish*(s: var Sha256): array[32, byte] =
  let bitLen = s.byteLen * 8'u64
  s.buf[s.bufLen] = 0x80'u8
  inc s.bufLen
  if s.bufLen > 56:
    while s.bufLen < 64:
      s.buf[s.bufLen] = 0'u8
      inc s.bufLen
    compress(s, s.buf)
    s.bufLen = 0
  while s.bufLen < 56:
    s.buf[s.bufLen] = 0'u8
    inc s.bufLen
  var bigLen: array[8, byte]
  var v = bitLen
  for i in countdown(7, 0):
    bigLen[i] = byte(v and 0xff'u64)
    v = v shr 8
  for i in 0 ..< 8:
    s.buf[56 + i] = bigLen[i]
  compress(s, s.buf)
  for i in 0 ..< 8:
    let x = s.h[i]
    result[i * 4] = byte(x shr 24)
    result[i * 4 + 1] = byte(x shr 16)
    result[i * 4 + 2] = byte(x shr 8)
    result[i * 4 + 3] = byte(x)

proc sha256*(data: openArray[byte]): array[32, byte] =
  var s: Sha256
  initSha256(s)
  update(s, data)
  result = finish(s)

proc toHexLower*(b: openArray[byte]): string =
  const hexDigits = "0123456789abcdef"
  result = newString(len(b) * 2)
  for i in 0 ..< len(b):
    result[i * 2] = hexDigits[int(b[i] shr 4)]
    result[i * 2 + 1] = hexDigits[int(b[i] and 0x0f'u8)]

proc sha256Hex*(data: openArray[byte]): string {.inline.} =
  toHexLower(sha256(data))

proc sha256Hex*(s: string): string =
  if s.len == 0:
    var empty: seq[byte] = @[]
    result = sha256Hex(empty)
  else:
    result = sha256Hex(s.toOpenArrayByte(0, s.len - 1))
