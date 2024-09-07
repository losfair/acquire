import gleam/dynamic.{type Dynamic}
import gleam/erlang
import gleam/float
import gleam/int
import gleam/result

pub fn annotate_result(r: Result(a, b), msg: c) -> Result(a, Dynamic) {
  result.map_error(r, fn(x) { dynamic.from(#(msg, x)) })
}

pub fn current_time_millis() -> Float {
  let #(megas, secs, micros) = erlang.erlang_timestamp()
  let assert Ok(millis) = float.divide(int.to_float(micros), 1000.0)
  float.add(int.to_float(megas * 1_000_000_000 + secs * 1000), millis)
}
