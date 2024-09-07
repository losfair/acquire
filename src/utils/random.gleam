import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import utils/utils

// 16 GiB
const reseed_interval = 17_179_869_184

type Cipher {
  Chacha20
}

type CryptoOpt {
  Encrypt(Bool)
}

type CryptoState

@external(erlang, "crypto", "crypto_init")
fn crypto_init_4(
  cipher: Cipher,
  key: BitArray,
  iv: BitArray,
  opts: List(CryptoOpt),
) -> CryptoState

@external(erlang, "crypto", "crypto_update")
fn crypto_update(st: CryptoState, data: BitArray) -> BitArray

@external(erlang, "crypto", "strong_rand_bytes")
fn strong_rand_bytes(n: Int) -> BitArray

pub opaque type Chacha20Rng {
  Chacha20Rng(tx: Subject(Req))
}

type Req {
  Generate(n: Int, ret: Subject(BitArray))
}

pub fn new_chacha20_rng() -> Result(Chacha20Rng, Dynamic) {
  use tx <- result.try(
    actor.start(new_state(), worker)
    |> utils.annotate_result("failed to start rng worker"),
  )
  Ok(Chacha20Rng(tx: tx))
}

pub fn generate(rng: Chacha20Rng, n: Int) -> BitArray {
  process.call(rng.tx, Generate(n: n, ret: _), 5000)
}

fn new_state() -> #(CryptoState, Int) {
  #(
    crypto_init_4(Chacha20, strong_rand_bytes(32), <<0:size(128)>>, [
      Encrypt(True),
    ]),
    0,
  )
}

fn worker(
  req: Req,
  st: #(CryptoState, Int),
) -> actor.Next(Req, #(CryptoState, Int)) {
  case req {
    Generate(n, ret) -> {
      let #(st, counter) = st
      let counter = counter + n
      let #(st, counter) = case counter >= reseed_interval {
        True -> new_state()
        False -> #(st, counter)
      }
      let data = crypto_update(st, <<0:size({ 8 * n })>>)
      case bit_array.byte_size(data) == n {
        True -> Nil
        False -> panic as "crypto_update failed to generate enough bytes"
      }
      process.send(ret, data)
      actor.continue(#(st, counter))
    }
  }
}
