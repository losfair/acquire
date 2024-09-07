import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang
import utils/hexcodec

type MacType {
  Poly1305
}

@external(erlang, "crypto", "mac")
fn mac_3(ty: MacType, key: BitArray, data: BitArray) -> Dynamic

pub opaque type Poly1305Hasher {
  H(key: BitArray)
}

pub fn create_poly1305_hasher(
  secret_key_base secret_key_base: String,
  ctx ctx: String,
) -> Poly1305Hasher {
  let key =
    crypto.hash(crypto.Sha256, erlang.term_to_binary(#(secret_key_base, ctx)))
  H(key)
}

pub fn poly1305_authenticate_data(h: Poly1305Hasher, data: BitArray) -> String {
  let mac = mac_3(Poly1305, h.key, data)
  let assert Ok(mac) = dynamic.bit_array(mac)
  hexcodec.encode_hex(mac)
}
