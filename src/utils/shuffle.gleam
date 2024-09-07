// https://github.com/gleam-lang/stdlib/blob/v0.38.0/src/gleam/list.gleam
import gleam/float
import gleam/int
import gleam/list
import gleam/order.{type Order}
import utils/binary
import utils/random

// 2 ** 24
const two_24 = 33_554_432

fn do_shuffle_pair_unwrap(list: List(#(Float, a)), acc: List(a)) -> List(a) {
  case list {
    [] -> acc
    [elem_pair, ..enumerable] ->
      do_shuffle_pair_unwrap(enumerable, [elem_pair.1, ..acc])
  }
}

fn do_shuffle_by_pair_indexes(
  list_of_pairs: List(#(Float, a)),
) -> List(#(Float, a)) {
  list.sort(
    list_of_pairs,
    fn(a_pair: #(Float, a), b_pair: #(Float, a)) -> Order {
      float.compare(a_pair.0, b_pair.0)
    },
  )
}

/// Takes a list, randomly sorts all items and returns the shuffled list.
///
/// This function uses `float.random` to decide the order of the elements.
///
/// ## Example
///
/// ```gleam
/// range(1, 10) |> shuffle()
/// // -> [1, 6, 9, 10, 3, 8, 4, 2, 7, 5]
/// ```
///
pub fn shuffle(list: List(a), rng: random.Chacha20Rng) -> List(a) {
  list
  |> list.fold(from: [], with: fn(acc, a) { [#(random_float(rng), a), ..acc] })
  |> do_shuffle_by_pair_indexes()
  |> do_shuffle_pair_unwrap([])
}

fn random_float(rng: random.Chacha20Rng) -> Float {
  let val = random.generate(rng, 3) |> binary.decode_unsigned |> int.to_float
  let max = int.to_float(two_24)
  let assert Ok(ret) = float.divide(val, max)
  ret
}
