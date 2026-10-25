///|
/// Small crypto helpers used by ETags, signed cookies and `If-None-Match`
/// handling: SHA-256, HMAC-SHA256 and base64.
///
/// They exist here instead of a native dependency because the package must
/// stay portable across the native backends; the implementations follow
/// FIPS 180-4 and RFC 4231 and are covered by known-answer tests.

///|
let sha256_k : FixedArray[UInt32] = [
  0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
  0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
  0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
  0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
  0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
  0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
  0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
  0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
  0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
  0xc67178f2U,
]

///|
fn sha256_rotr(x : UInt32, n : Int32) -> UInt32 {
  (x >> n) | (x << (32 - n))
}

///|
fn sha256_compress(
  state : Array[UInt32],
  block : Array[Byte],
  offset : Int32,
) -> Unit {
  let w : Array[UInt32] = Array::make(64, (0 : UInt32))
  let mut i = 0
  while i < 16 {
    let j = offset + i * 4
    w[i] = (block[j].to_uint() << 24) |
      (block[j + 1].to_uint() << 16) |
      (block[j + 2].to_uint() << 8) |
      block[j + 3].to_uint()
    i = i + 1
  }
  while i < 64 {
    let x = w[i - 15]
    let y = w[i - 2]
    let s0 = sha256_rotr(x, 7) ^ sha256_rotr(x, 18) ^ (x >> 3)
    let s1 = sha256_rotr(y, 17) ^ sha256_rotr(y, 19) ^ (y >> 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
    i = i + 1
  }
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut e = state[4]
  let mut f = state[5]
  let mut g = state[6]
  let mut h = state[7]
  let mut i = 0
  while i < 64 {
    let s1 = sha256_rotr(e, 6) ^ sha256_rotr(e, 11) ^ sha256_rotr(e, 25)
    let ch = (e & f) ^ ((e ^ 0xffffffffU) & g)
    let temp1 = h + s1 + ch + sha256_k[i] + w[i]
    let s0 = sha256_rotr(a, 2) ^ sha256_rotr(a, 13) ^ sha256_rotr(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let temp2 = s0 + maj
    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2
    i = i + 1
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
  state[4] = state[4] + e
  state[5] = state[5] + f
  state[6] = state[6] + g
  state[7] = state[7] + h
}

///|
/// SHA-256 (FIPS 180-4) over `data`, returning the 32 raw digest bytes.
///
/// The scratch buffers are sized up front (`Array::make`) instead of grown
/// byte by byte: the padding push loop reallocated the array about six times
/// per call, and this runs once per response for the ETag.
pub fn sha256_bytes(data : Bytes) -> Bytes {
  let state : Array[UInt32] = [
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU,
    0x1f83d9abU, 0x5be0cd19U,
  ]
  let data_len = data.length()
  let total = (data_len + 9 + 63) / 64 * 64
  let padded : Array[Byte] = Array::make(total, b'\x00')
  for i = 0; i < data_len; i = i + 1 {
    padded[i] = data[i]
  }
  padded[data_len] = (0x80 : Int32).to_byte()
  let bit_len = data_len.to_int64() * 8L
  for i = 0; i < 8; i = i + 1 {
    padded[total - 8 + i] = (bit_len >> ((7 - i) * 8)).to_byte()
  }
  let mut offset = 0
  while offset < total {
    sha256_compress(state, padded, offset)
    offset = offset + 64
  }
  let out : Array[Byte] = Array::make(32, b'\x00')
  let mut index = 0
  for word in state {
    out[index] = ((word >> 24) & 0xffU).reinterpret_as_int().to_byte()
    out[index + 1] = ((word >> 16) & 0xffU).reinterpret_as_int().to_byte()
    out[index + 2] = ((word >> 8) & 0xffU).reinterpret_as_int().to_byte()
    out[index + 3] = (word & 0xffU).reinterpret_as_int().to_byte()
    index = index + 4
  }
  Bytes::from_array(out)
}

///|
/// Hex digest of `sha256_bytes`, lower case.
pub fn sha256_hex(data : String) -> String {
  bytes_to_hex(sha256_bytes(utf8_bytes(data)))
}

///|
/// Lower-case hex encoding.
pub fn bytes_to_hex(data : Bytes) -> String {
  let sb = StringBuilder()
  for byte in data {
    let value = byte.to_int()
    let hi = value / 16
    let lo = value % 16
    sb.write_char((if hi < 10 { 48 + hi } else { 87 + hi }).unsafe_to_char())
    sb.write_char((if lo < 10 { 48 + lo } else { 87 + lo }).unsafe_to_char())
  }
  sb.to_string()
}

///|
/// HMAC-SHA256 (RFC 2104) with a 64-byte block size.
pub fn hmac_sha256(key : Bytes, message : Bytes) -> Bytes {
  let mut k = key.to_array()
  if k.length() > 64 {
    k = sha256_bytes(key).to_array()
  }
  let inner : Array[Byte] = []
  for i = 0; i < 64; i = i + 1 {
    let byte = if i < k.length() { k[i].to_int() } else { 0 }
    inner.push((byte ^ 54).to_byte())
  }
  for byte in message {
    inner.push(byte)
  }
  let inner_digest = sha256_bytes(Bytes::from_array(inner))
  let outer : Array[Byte] = []
  for i = 0; i < 64; i = i + 1 {
    let byte = if i < k.length() { k[i].to_int() } else { 0 }
    outer.push((byte ^ 92).to_byte())
  }
  for byte in inner_digest {
    outer.push(byte)
  }
  sha256_bytes(Bytes::from_array(outer))
}

///|
/// Standard base64 with padding, as used by `cookie-signature`.
pub fn base64_encode(data : Bytes) -> String {
  @base64.encode(data[:])
}

///|
/// Time-independent byte comparison, for signatures and MACs.
pub fn constant_time_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut diff = 0
  for i = 0; i < a.length(); i = i + 1 {
    diff = diff | (a[i].to_int() ^ b[i].to_int())
  }
  diff == 0
}

///|
/// Signs a cookie value the way the `cookie-signature` package does:
/// `value + "." + base64(hmac_sha256(secret, value))` with the `=` padding
/// stripped.
pub fn sign_cookie(secret : String, value : String) -> String {
  let mac = base64_encode(hmac_sha256(utf8_bytes(secret), utf8_bytes(value)))
  let mac = mac.replace_all(old="=", new="")
  value + "." + mac
}

///|
/// Verifies a value produced by `sign_cookie` and returns the original value,
/// or `None` when the signature does not match.
pub fn unsign_cookie(secret : String, signed : String) -> String? {
  let index = match signed.rev_find(".") {
    Some(index) => index
    None => return None
  }
  let value = signed[:index].to_owned()
  let mac = signed[index + 1:].to_owned()
  let expected = base64_encode(
    hmac_sha256(utf8_bytes(secret), utf8_bytes(value)),
  ).replace_all(old="=", new="")
  if constant_time_equal(utf8_bytes(mac), utf8_bytes(expected)) {
    Some(value)
  } else {
    None
  }
}
