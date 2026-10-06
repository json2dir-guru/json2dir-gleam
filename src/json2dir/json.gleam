//// A small strict JSON parser (RFC 8259) working directly on the input bytes.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

pub type Json {
  JObject(members: List(#(String, Json)))
  JArray(items: List(Json))
  JString(value: String)
  JNumber
  JBool
  JNull
}

pub fn parse(input: BitArray) -> Result(Json, String) {
  // A leading byte order mark is ignored, as RFC 8259 permits.
  let input = case input {
    <<0xEF, 0xBB, 0xBF, rest:bytes>> -> rest
    _ -> input
  }
  use #(value, rest) <- result.try(parse_value(skip_ws(input)))
  case skip_ws(rest) {
    <<>> -> Ok(value)
    _ -> Error("unexpected data after the JSON value")
  }
}

fn skip_ws(input: BitArray) -> BitArray {
  case input {
    <<0x20, rest:bytes>>
    | <<0x09, rest:bytes>>
    | <<0x0A, rest:bytes>>
    | <<0x0D, rest:bytes>> -> skip_ws(rest)
    _ -> input
  }
}

fn parse_value(input: BitArray) -> Result(#(Json, BitArray), String) {
  case input {
    <<"{":utf8, rest:bytes>> -> parse_object(skip_ws(rest), [])
    <<"[":utf8, rest:bytes>> -> parse_array(skip_ws(rest), [])
    <<"\"":utf8, rest:bytes>> ->
      parse_string(rest, [])
      |> result.map(fn(p) { #(JString(p.0), p.1) })
    <<"true":utf8, rest:bytes>> -> Ok(#(JBool, rest))
    <<"false":utf8, rest:bytes>> -> Ok(#(JBool, rest))
    <<"null":utf8, rest:bytes>> -> Ok(#(JNull, rest))
    <<"-":utf8, rest:bytes>> -> parse_number(rest)
    <<c, _:bytes>> if c >= 0x30 && c <= 0x39 -> parse_number(input)
    <<>> -> Error("unexpected end of input")
    _ -> Error("unexpected character")
  }
}

fn parse_object(
  input: BitArray,
  acc: List(#(String, Json)),
) -> Result(#(Json, BitArray), String) {
  case input, acc {
    <<"}":utf8, rest:bytes>>, [] -> Ok(#(JObject([]), rest))
    <<"\"":utf8, rest:bytes>>, _ -> {
      use #(name, rest) <- result.try(parse_string(rest, []))
      case skip_ws(rest) {
        <<":":utf8, rest:bytes>> -> {
          use #(value, rest) <- result.try(parse_value(skip_ws(rest)))
          let acc = [#(name, value), ..acc]
          case skip_ws(rest) {
            <<",":utf8, rest:bytes>> -> parse_object(skip_ws(rest), acc)
            <<"}":utf8, rest:bytes>> -> Ok(#(JObject(list.reverse(acc)), rest))
            _ -> Error("expected ',' or '}' in object")
          }
        }
        _ -> Error("expected ':' in object")
      }
    }
    _, _ -> Error("expected a member name in object")
  }
}

fn parse_array(
  input: BitArray,
  acc: List(Json),
) -> Result(#(Json, BitArray), String) {
  case input, acc {
    <<"]":utf8, rest:bytes>>, [] -> Ok(#(JArray([]), rest))
    _, _ -> {
      use #(value, rest) <- result.try(parse_value(input))
      let acc = [value, ..acc]
      case skip_ws(rest) {
        <<",":utf8, rest:bytes>> -> parse_array(skip_ws(rest), acc)
        <<"]":utf8, rest:bytes>> -> Ok(#(JArray(list.reverse(acc)), rest))
        _ -> Error("expected ',' or ']' in array")
      }
    }
  }
}

// Number syntax only: the value itself is never needed.
fn parse_number(input: BitArray) -> Result(#(Json, BitArray), String) {
  let rest = case input {
    <<"0":utf8, rest:bytes>> -> Ok(rest)
    <<c, _:bytes>> if c >= 0x31 && c <= 0x39 -> Ok(digits(input))
    _ -> Error("invalid number")
  }
  use rest <- result.try(rest)
  use rest <- result.try(case rest {
    <<".":utf8, c, _:bytes>> if c >= 0x30 && c <= 0x39 -> {
      let assert <<_, more:bytes>> = rest
      Ok(digits(more))
    }
    <<".":utf8, _:bytes>> -> Error("invalid number")
    _ -> Ok(rest)
  })
  case rest {
    <<e, more:bytes>> if e == 0x65 || e == 0x45 -> {
      let more = case more {
        <<"+":utf8, m:bytes>> | <<"-":utf8, m:bytes>> -> m
        _ -> more
      }
      case more {
        <<c, _:bytes>> if c >= 0x30 && c <= 0x39 -> Ok(#(JNumber, digits(more)))
        _ -> Error("invalid number")
      }
    }
    _ -> Ok(#(JNumber, rest))
  }
}

fn digits(input: BitArray) -> BitArray {
  case input {
    <<c, rest:bytes>> if c >= 0x30 && c <= 0x39 -> digits(rest)
    _ -> input
  }
}

/// Parses the rest of a string after the opening quote; `acc` holds decoded chunks in reverse.
fn parse_string(
  input: BitArray,
  acc: List(BitArray),
) -> Result(#(String, BitArray), String) {
  case input {
    <<"\"":utf8, rest:bytes>> -> {
      let assert Ok(s) =
        bit_array.to_string(bit_array.concat(list.reverse(acc)))
      Ok(#(s, rest))
    }
    <<"\\":utf8, rest:bytes>> -> {
      use #(bytes, rest) <- result.try(parse_escape(rest))
      parse_string(rest, [bytes, ..acc])
    }
    <<c, _:bytes>> if c < 0x20 -> Error("control character in string")
    <<c, rest:bytes>> if c < 0x80 -> parse_string(rest, [<<c>>, ..acc])
    // Erlang's utf8 segment rejects overlong forms, surrogates and values above U+10FFFF.
    <<c:utf8_codepoint, rest:bytes>> ->
      parse_string(rest, [<<c:utf8_codepoint>>, ..acc])
    <<>> -> Error("unterminated string")
    _ -> Error("input is not valid UTF-8")
  }
}

fn parse_escape(input: BitArray) -> Result(#(BitArray, BitArray), String) {
  case input {
    <<"\"":utf8, rest:bytes>> -> Ok(#(<<"\"":utf8>>, rest))
    <<"\\":utf8, rest:bytes>> -> Ok(#(<<"\\":utf8>>, rest))
    <<"/":utf8, rest:bytes>> -> Ok(#(<<"/":utf8>>, rest))
    <<"b":utf8, rest:bytes>> -> Ok(#(<<8>>, rest))
    <<"f":utf8, rest:bytes>> -> Ok(#(<<12>>, rest))
    <<"n":utf8, rest:bytes>> -> Ok(#(<<10>>, rest))
    <<"r":utf8, rest:bytes>> -> Ok(#(<<13>>, rest))
    <<"t":utf8, rest:bytes>> -> Ok(#(<<9>>, rest))
    <<"u":utf8, rest:bytes>> -> {
      use #(hi, rest) <- result.try(hex4(rest))
      case hi {
        _ if hi >= 0xD800 && hi <= 0xDBFF ->
          case rest {
            <<"\\":utf8, "u":utf8, more:bytes>> -> {
              use #(lo, more) <- result.try(hex4(more))
              case lo >= 0xDC00 && lo <= 0xDFFF {
                True -> {
                  let cp = 0x10000 + { hi - 0xD800 } * 0x400 + { lo - 0xDC00 }
                  Ok(#(codepoint(cp), more))
                }
                False -> Error("string contains an unpaired surrogate")
              }
            }
            _ -> Error("string contains an unpaired surrogate")
          }
        _ if hi >= 0xDC00 && hi <= 0xDFFF ->
          Error("string contains an unpaired surrogate")
        _ -> Ok(#(codepoint(hi), rest))
      }
    }
    _ -> Error("invalid escape in string")
  }
}

fn codepoint(cp: Int) -> BitArray {
  let assert Ok(c) = string.utf_codepoint(cp)
  <<c:utf8_codepoint>>
}

fn hex4(input: BitArray) -> Result(#(Int, BitArray), String) {
  case input {
    <<a, b, c, d, rest:bytes>> ->
      case hex(a), hex(b), hex(c), hex(d) {
        Ok(a), Ok(b), Ok(c), Ok(d) ->
          Ok(#(a * 4096 + b * 256 + c * 16 + d, rest))
        _, _, _, _ -> Error("invalid unicode escape")
      }
    _ -> Error("invalid unicode escape")
  }
}

fn hex(c: Int) -> Result(Int, Nil) {
  case c {
    _ if c >= 0x30 && c <= 0x39 -> Ok(c - 0x30)
    _ if c >= 0x61 && c <= 0x66 -> Ok(c - 0x61 + 10)
    _ if c >= 0x41 && c <= 0x46 -> Ok(c - 0x41 + 10)
    _ -> Error(Nil)
  }
}
