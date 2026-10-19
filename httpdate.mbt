///|
/// HTTP date helpers (RFC 7231 IMF-fixdate), used by `Last-Modified`,
/// `If-Modified-Since` and `If-Unmodified-Since` handling.

///|
let http_day_names : FixedArray[String] = [
  "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
]

///|
let http_month_names : FixedArray[String] = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

///|
fn floor_div(a : Int64, b : Int64) -> Int64 {
  let quotient = a / b
  if a % b != 0 && (a < 0) != (b < 0) {
    quotient - 1
  } else {
    quotient
  }
}

///|
/// Days since 1970-01-01 to `(year, month, day)`, by Howard Hinnant's
/// `civil_from_days`.
fn civil_from_days(days : Int64) -> (Int64, Int64, Int64) {
  let shifted = days + 719468L
  let era = floor_div(
    if shifted >= 0L {
      shifted
    } else {
      shifted - 146096L
    },
    146097L,
  )
  let doe = shifted - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let year = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = mp + (if mp < 10L { 3L } else { -9L })
  (year + (if month <= 2L { 1L } else { 0L }), month, day)
}

///|
/// `(year, month, day)` to days since 1970-01-01, by Hinnant's
/// `days_from_civil`.
fn days_from_civil(year : Int64, month : Int64, day : Int64) -> Int64 {
  let y = year - (if month <= 2L { 1L } else { 0L })
  let era = floor_div(if y >= 0L { y } else { y - 399L }, 400L)
  let yoe = y - era * 400L
  let mp = if month > 2L { month - 3L } else { month + 9L }
  let doy = (153L * mp + 2L) / 5L + day - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097L + doe - 719468L
}

///|
fn two_digits(value : Int64) -> String {
  if value < 10L {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}

///|
/// Formats seconds since the Unix epoch as an IMF-fixdate, e.g.
/// `Sun, 06 Nov 1994 08:49:37 GMT`.
pub fn format_http_date(epoch_seconds : Int64) -> String {
  let days = floor_div(epoch_seconds, 86400L)
  let seconds = epoch_seconds - days * 86400L
  let (year, month, day) = civil_from_days(days)
  let weekday = ((days + 4L) % 7L + 7L) % 7L
  let hour = seconds / 3600L
  let minute = seconds % 3600L / 60L
  let second = seconds % 60L
  http_day_names[weekday.to_int()] +
  ", " +
  two_digits(day) +
  " " +
  http_month_names[(month - 1).to_int()] +
  " " +
  year.to_string() +
  " " +
  two_digits(hour) +
  ":" +
  two_digits(minute) +
  ":" +
  two_digits(second) +
  " GMT"
}

///|
fn parse_digits(text : String) -> Int64? {
  if text == "" {
    return None
  }
  let mut value : Int64 = 0
  for ch in text {
    let digit = ch.to_int() - 48
    if digit < 0 || digit > 9 {
      return None
    }
    value = value * 10 + digit.to_int64()
  }
  Some(value)
}

///|
/// Parses an IMF-fixdate into seconds since the epoch. `None` for any other
/// format, matching how Express falls back to ignoring the header.
pub fn parse_http_date(value : String) -> Int64? {
  let tokens : Array[String] = []
  for raw in value.split(" ") {
    let token = raw.to_owned().trim().to_owned()
    if token != "" {
      tokens.push(token)
    }
  }
  if tokens.length() < 5 {
    return None
  }
  let day = match parse_digits(tokens[1]) {
    Some(value) => value
    None => return None
  }
  let month = month_index(tokens[2])
  if month == 0 {
    return None
  }
  let year = match parse_digits(tokens[3]) {
    Some(value) => value
    None => return None
  }
  let clock = tokens[4].split(":").to_array()
  if clock.length() < 3 {
    return None
  }
  let hour = match parse_digits(clock[0].to_owned()) {
    Some(value) => value
    None => return None
  }
  let minute = match parse_digits(clock[1].to_owned()) {
    Some(value) => value
    None => return None
  }
  let second = match parse_digits(clock[2].to_owned()) {
    Some(value) => value
    None => return None
  }
  let days = days_from_civil(year, month, day)
  Some(days * 86400L + hour * 3600L + minute * 60L + second)
}

///|
fn month_index(name : String) -> Int64 {
  let mut index = 0
  while index < 12 {
    if http_month_names[index].to_lower() == name.to_lower() {
      return (index + 1).to_int64()
    }
    index = index + 1
  }
  0
}
