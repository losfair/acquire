import gleam/dynamic
import gleam/erlang
import gleam/string

@external(erlang, "binary", "decode_hex")
fn unsafe_decode_hex(input: String) -> BitArray

@external(erlang, "binary", "encode_hex")
fn unsafe_encode_hex(bin: BitArray) -> String

pub type BadHex {
  BadHex
}

type Badarg {
  Badarg
}

pub fn decode_hex(input: String) -> Result(BitArray, BadHex) {
  case erlang.rescue(fn() { unsafe_decode_hex(input) }) {
    Ok(value) -> Ok(value)
    Error(x) ->
      case x == erlang.Errored(dynamic.from(Badarg)) {
        True -> Error(BadHex)
        False -> panic as string.inspect(x)
      }
  }
}

pub fn encode_hex(input: BitArray) -> String {
  unsafe_encode_hex(input) |> string.lowercase
}
