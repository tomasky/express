///|
/// Content negotiation that mirrors the `accepts`/`negotiator` packages
/// Express relies on: quality values, wildcards, specificity ranking and the
/// per-kind defaults for `Accept`, `Accept-Charset`, `Accept-Encoding` and
/// `Accept-Language`.

///|
/// One parsed media range / charset / encoding / language from an accept
/// header, in header order.
priv struct AcceptSpec {
  value : String
  q : Double
  order : Int32
  params : Array[(String, String)]
}

///|
priv enum AcceptKind {
  Media
  Charset
  Encoding
  Language
}

///|
priv struct AcceptCandidate {
  q : Double
  specificity : Int32
  spec_order : Int32
}

///|
/// Parses a q parameter such as `0.8` or `1`. Anything unparsable is `1.0`.
fn parse_q(value : String) -> Double {
  let text = value.trim()
  let mut integer : Double = 0.0
  let mut seen_dot = false
  let mut scale : Double = 0.1
  let mut fraction : Double = 0.0
  for ch in text {
    let digit = ch.to_int() - 48
    if digit >= 0 && digit <= 9 {
      if seen_dot {
        fraction = fraction + digit.to_double() * scale
        scale = scale * 0.1
      } else {
        integer = integer * 10.0 + digit.to_double()
      }
    } else if ch == '.' {
      if seen_dot {
        break
      }
      seen_dot = true
    } else {
      break
    }
  }
  integer + fraction
}

///|
fn strip_quotes(value : String) -> String {
  if value.length() >= 2 && value.has_prefix("\"") && value.has_suffix("\"") {
    value[1:value.length() - 1].to_owned()
  } else {
    value
  }
}

///|
fn parse_accept_specs(header : String) -> Array[AcceptSpec] {
  let specs : Array[AcceptSpec] = []
  let mut order = 0
  for raw in header.split(",") {
    let item = raw.to_owned().trim().to_owned()
    if item == "" {
      continue
    }
    let segments = item.split(";")
    let mut value = ""
    let params : Array[(String, String)] = []
    let mut q = 1.0
    let mut index = 0
    for part in segments {
      let part = part.to_owned().trim().to_owned()
      if index == 0 {
        value = part.to_lower()
      } else {
        match part.split_once("=") {
          Some((key, raw_value)) => {
            let key = key.to_owned().trim().to_lower().to_owned()
            let raw_value = strip_quotes(raw_value.to_owned().trim().to_owned())
            if key == "q" {
              q = parse_q(raw_value)
            } else {
              params.push((key, raw_value.to_lower()))
            }
          }
          None => ()
        }
      }
      index = index + 1
    }
    if value != "" {
      specs.push({ value, q, order, params, })
    }
    order = order + 1
  }
  specs
}

///|
/// Splits `type/subtype` into its two parts (`*` yields `("*", "*")`).
fn split_media(value : String) -> (String, String) {
  match value.split_once("/") {
    Some((major, minor)) => (major.to_owned(), minor.to_owned())
    None => (value, "*")
  }
}

///|
/// The specificity of `provided` against one spec, following each negotiator
/// kind's `specify()`: `None` when the spec rejects the value.
fn spec_specificity(
  spec : AcceptSpec,
  provided : String,
  kind : AcceptKind,
) -> Int32? {
  let provided_lower = provided.to_lower()
  match kind {
    Charset | Encoding =>
      if spec.value == provided_lower {
        Some(1)
      } else if spec.value == "*" {
        Some(0)
      } else {
        None
      }
    Media => {
      let (spec_type, spec_subtype) = split_media(spec.value)
      let (provided_type, provided_subtype) = split_media(provided_lower)
      let mut score = 0
      if spec_type == provided_type {
        score = score | 4
      } else if spec_type != "*" {
        return None
      }
      if spec_subtype == provided_subtype {
        score = score | 2
      } else if spec_subtype != "*" {
        return None
      }
      if spec.params.length() > 0 {
        let params = media_params(provided_lower)
        for pair in spec.params {
          let mut matched = false
          for candidate in params {
            if candidate.0 == pair.0 && (pair.1 == "*" || candidate.1 == pair.1) {
              matched = true
            }
          }
          if !matched {
            return None
          }
        }
        score = score | 1
      }
      Some(score)
    }
    Language => {
      let (spec_full, spec_prefix) = language_parts(spec.value)
      let (provided_full, provided_prefix) = language_parts(provided_lower)
      if spec_full == provided_full {
        Some(4)
      } else if spec_prefix == provided_full {
        Some(2)
      } else if spec_full == provided_prefix {
        Some(1)
      } else if spec_full == "*" {
        Some(0)
      } else {
        None
      }
    }
  }
}

///|
/// The parameters of a media type such as `text/html;level=1`, `q` excluded.
fn media_params(value : String) -> Array[(String, String)] {
  let params : Array[(String, String)] = []
  let segments = value.split(";")
  let mut index = 0
  for raw in segments {
    if index > 0 {
      let part = raw.to_owned().trim().to_owned()
      match part.split_once("=") {
        Some((key, raw_value)) => {
          let key = key.to_owned().trim().to_lower().to_owned()
          if key != "q" {
            params.push(
              (key, strip_quotes(raw_value.to_owned().trim().to_owned())),
            )
          }
        }
        None => ()
      }
    }
    index = index + 1
  }
  params
}

///|
/// `en-US` becomes `("en-us", "en")`.
fn language_parts(value : String) -> (String, String) {
  match value.split_once("-") {
    Some((prefix, _)) => (value, prefix.to_owned())
    None => (value, value)
  }
}

///|
/// The best-matching spec for one provided value, ranked like negotiator's
/// `getPriority`: specificity first, then q, then header order.
fn candidate_priority(
  specs : Array[AcceptSpec],
  provided : String,
  kind : AcceptKind,
) -> AcceptCandidate {
  let mut best : AcceptCandidate = { q: 0.0, specificity: 0, spec_order: -1, }
  for spec in specs {
    match spec_specificity(spec, provided, kind) {
      Some(specificity) =>
        if specificity > best.specificity ||
          (
            specificity == best.specificity &&
            (
              spec.q > best.q ||
              (spec.q == best.q && spec.order > best.spec_order)
            )
          ) {
          best = { q: spec.q, specificity, spec_order: spec.order, }
        }
      None => ()
    }
  }
  best
}

///|
/// Index of the winning provided value, or `-1`. Ordering follows
/// negotiator's `compareSpecs`: q desc, specificity desc, spec order asc,
/// provided order asc.
fn pick_best(
  specs : Array[AcceptSpec],
  provided : Array[String],
  kind : AcceptKind,
) -> Int32 {
  let mut best_index = -1
  let mut best_q = 0.0
  let mut best_specificity = 0
  let mut best_spec_order = 0
  let mut index = 0
  while index < provided.length() {
    let candidate = candidate_priority(specs, provided[index], kind)
    if candidate.q > 0.0 {
      let better = if best_index == -1 {
        true
      } else {
        candidate.q > best_q ||
        (candidate.q == best_q && candidate.specificity > best_specificity) ||
        (
          candidate.q == best_q &&
          candidate.specificity == best_specificity &&
          candidate.spec_order < best_spec_order
        )
      }
      if better {
        best_index = index
        best_q = candidate.q
        best_specificity = candidate.specificity
        best_spec_order = candidate.spec_order
      }
    }
    index = index + 1
  }
  best_index
}

///|
/// `req.accepts` for media types. Extensions such as `html` are mapped to
/// their media type before matching, and the caller's original string is
/// returned. An empty `accept` means "no header".
pub fn negotiate_media(accept : String, provided : Array[String]) -> String {
  if accept.trim() == "" {
    return if provided.length() > 0 { provided[0] } else { "" }
  }
  let mimes : Array[String] = []
  let originals : Array[String] = []
  for type_ in provided {
    let mime = mime_for_type_name(type_)
    if mime != "" {
      mimes.push(mime)
      originals.push(type_)
    }
  }
  if mimes.length() == 0 {
    return ""
  }
  let specs = parse_accept_specs(accept)
  let index = pick_best(specs, mimes, Media)
  if index == -1 {
    return ""
  }
  originals[index]
}

///|
/// `req.acceptsCharsets`. With no header every charset is acceptable, so the
/// first provided one wins.
pub fn negotiate_charsets(header : String, provided : Array[String]) -> String {
  let specs = if header == "" {
    parse_accept_specs("*")
  } else {
    parse_accept_specs(header)
  }
  let index = pick_best(specs, provided, Charset)
  if index == -1 {
    ""
  } else {
    provided[index]
  }
}

///|
/// `req.acceptsEncodings`. With no header `identity` is the only acceptable
/// encoding, like negotiator's implicit `identity` entry.
pub fn negotiate_encodings(header : String, provided : Array[String]) -> String {
  let specs = parse_accept_specs(header)
  let mut has_identity = false
  let mut min_quality = 1.0
  for spec in specs {
    if spec.value == "identity" || spec.value == "*" {
      has_identity = true
    }
    let quality = if spec.q == 0.0 { 1.0 } else { spec.q }
    if quality < min_quality {
      min_quality = quality
    }
  }
  if !has_identity {
    specs.push({
      value: "identity",
      q: min_quality,
      order: specs.length(),
      params: [],
    })
  }
  let index = pick_best(specs, provided, Encoding)
  if index == -1 {
    ""
  } else {
    provided[index]
  }
}

///|
/// `req.acceptsLanguages`. With no header every language is acceptable.
pub fn negotiate_languages(header : String, provided : Array[String]) -> String {
  let specs = if header == "" {
    parse_accept_specs("*")
  } else {
    parse_accept_specs(header)
  }
  let index = pick_best(specs, provided, Language)
  if index == -1 {
    ""
  } else {
    provided[index]
  }
}
