import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub const alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ":utf8>>

pub type Block {
  Block(row: Int, col: Int)
}

pub type Player {
  Player(id: String, balance: Int, cards: List(Block), stocks: Dict(Int, Int))
}

pub type GameStatus {
  Initializing
  Placing
  Buying
  Distributing
  Finished
}

pub type RoomSummary {
  RoomSummary(
    room_id: String,
    board: Dict(Block, Int),
    players: List(Player),
    companies: List(#(Int, Company)),
    distributing: List(String),
    acquired_companies: List(Int),
    status: GameStatus,
  )
}

pub type Company {
  Company(name: String, cliff: Int, color: Option(String))
}

pub type SavedState {
  SavedState(
    board: Dict(Block, Int),
    players: List(Player),
    distributing: List(String),
    acquired_companies: List(#(Int, Int)),
    companies: List(#(Int, Company)),
    card_queue: List(Block),
    status: GameStatus,
  )
}

pub type Sell {
  Sell(
    for_money: Dict(String, Int),
    for_other_stocks: Dict(String, Dict(String, Int)),
  )
}

pub type Buy {
  Buy(company: String, amount: Int)
}

pub fn encode_room_summary(s: RoomSummary) -> json.Json {
  json.object([
    #("room_id", json.string(s.room_id)),
    #("board", encode_board(s.board)),
    #("players", json.array(s.players, encode_player)),
    #(
      "companies",
      json.object(
        s.companies
        |> list.map(fn(x) {
          let #(id, company) = x
          #(int.to_string(id), encode_company(company))
        }),
      ),
    ),
    #("distributing", json.array(s.distributing, json.string)),
    #("acquired_companies", json.array(s.acquired_companies, json.int)),
    #("status", encode_game_status(s.status)),
  ])
}

pub fn fmt_block(block: Block) -> String {
  let row =
    bit_array.slice(alphabet, block.row, 1)
    |> result.map(fn(x) {
      let assert Ok(x) = bit_array.to_string(x)
      x
    })
    |> result.lazy_unwrap(fn() {
      string.concat(["<", int.to_string(block.row), ">"])
    })
  let col = int.to_string(block.col)
  col <> row
}

pub fn parse_block(block: String) -> Result(Block, Nil) {
  use row <- result.try(
    string.last(block)
    |> result.unwrap("")
    |> string.to_utf_codepoints
    |> list.first,
  )
  // 'A'
  use row <- result.try(case string.utf_codepoint_to_int(row) - 65 {
    x if x >= 0 && x < 26 -> Ok(x)
    _ -> Error(Nil)
  })
  use col <- result.try(string.drop_right(block, 1) |> int.parse)
  Ok(Block(row: row, col: col))
}

pub fn parse_block_dynamic(
  x: dynamic.Dynamic,
) -> Result(Block, List(dynamic.DecodeError)) {
  use s <- result.try(dynamic.string(x))
  parse_block(s)
  |> result.map_error(fn(_: Nil) {
    [
      dynamic.DecodeError(
        expected: "Some block",
        found: "Other string: " <> s,
        path: [],
      ),
    ]
  })
}

pub fn encode_game_status(status: GameStatus) -> json.Json {
  json.string(case status {
    Initializing -> "initializing"
    Placing -> "placing"
    Buying -> "buying"
    Distributing -> "distributing"
    Finished -> "finished"
  })
}

pub fn decode_game_status(
  x: dynamic.Dynamic,
) -> Result(GameStatus, List(dynamic.DecodeError)) {
  use s <- result.try(dynamic.string(x))
  case s {
    "initializing" -> Ok(Initializing)
    "placing" -> Ok(Placing)
    "buying" -> Ok(Buying)
    "distributing" -> Ok(Distributing)
    "finished" -> Ok(Finished)
    _ ->
      Error([
        dynamic.DecodeError(
          expected: "Some game status",
          found: "Other string: " <> s,
          path: [],
        ),
      ])
  }
}

pub fn encode_company(company: Company) -> json.Json {
  let fields = [
    #("name", json.string(company.name)),
    #("cliff", json.int(company.cliff)),
  ]
  let fields = case company.color {
    option.Some(x) -> [#("color", json.string(x)), ..fields]
    option.None -> fields
  }
  json.object(fields)
}

pub fn decode_company(
  x: dynamic.Dynamic,
) -> Result(Company, List(dynamic.DecodeError)) {
  dynamic.decode3(
    Company,
    dynamic.field("name", dynamic.string),
    dynamic.field("cliff", dynamic.int),
    dynamic.optional_field("color", dynamic.string),
  )(x)
}

pub fn encode_player(p: Player) -> json.Json {
  json.object([
    #("id", json.string(p.id)),
    #("balance", json.int(p.balance)),
    #("cards", json.array(p.cards, fn(c) { json.string(fmt_block(c)) })),
    #(
      "stocks",
      json.object(
        p.stocks
        |> dict.to_list
        |> list.map(fn(x) {
          let #(company, amount) = x
          #(int.to_string(company), json.int(amount))
        }),
      ),
    ),
  ])
}

pub fn decode_player(
  x: dynamic.Dynamic,
) -> Result(Player, List(dynamic.DecodeError)) {
  dynamic.decode4(
    Player,
    dynamic.field("id", dynamic.string),
    dynamic.field("balance", dynamic.int),
    dynamic.field("cards", dynamic.list(parse_block_dynamic)),
    dynamic.field("stocks", fn(x) {
      case dynamic.dict(dynamic.string, dynamic.int)(x) {
        Ok(x) ->
          list.try_map(dict.to_list(x), fn(x) {
            let #(k, v) = x
            use k <- result.try(
              int.parse(k)
              |> result.map_error(fn(_: Nil) {
                [
                  dynamic.DecodeError(
                    expected: "Some string-encoded integer",
                    found: "Other string",
                    path: [],
                  ),
                ]
              }),
            )
            Ok(#(k, v))
          })
          |> result.map(dict.from_list)
        Error(e) -> Error(e)
      }
    }),
  )(x)
}

pub fn encode_board(x: Dict(Block, Int)) -> json.Json {
  json.object(
    x
    |> dict.to_list
    |> list.map(fn(x) {
      let #(k, v) = x
      #(fmt_block(k), json.int(v))
    }),
  )
}

pub fn decode_board(
  x: dynamic.Dynamic,
) -> Result(Dict(Block, Int), List(dynamic.DecodeError)) {
  dynamic.dict(parse_block_dynamic, dynamic.int)(x)
}

pub fn decode_string_encoded_integer(
  x: dynamic.Dynamic,
) -> Result(Int, List(dynamic.DecodeError)) {
  use x <- result.try(dynamic.string(x))
  int.parse(x)
  |> result.map_error(fn(_: Nil) {
    [
      dynamic.DecodeError(
        expected: "Some string-encoded integer",
        found: "Other string",
        path: [],
      ),
    ]
  })
}

pub fn decode_sell(
  x: dynamic.Dynamic,
) -> Result(Sell, List(dynamic.DecodeError)) {
  dynamic.decode2(
    Sell,
    dynamic.field("for_money", dynamic.dict(dynamic.string, non_negative_int)),
    dynamic.field(
      "for_other_stocks",
      dynamic.dict(
        dynamic.string,
        dynamic.dict(dynamic.string, non_negative_int),
      ),
    ),
  )(x)
}

pub fn decode_buy(x: dynamic.Dynamic) -> Result(Buy, List(dynamic.DecodeError)) {
  dynamic.decode2(
    Buy,
    dynamic.field("company", dynamic.string),
    dynamic.field("amount", non_negative_int),
  )(x)
}

pub fn non_negative_int(
  x: dynamic.Dynamic,
) -> Result(Int, List(dynamic.DecodeError)) {
  case dynamic.int(x) {
    Ok(x) if x >= 0 -> Ok(x)
    Ok(_) ->
      Error([
        dynamic.DecodeError(
          expected: "Non-negative integer",
          found: "Negative integer",
          path: [],
        ),
      ])
    Error(e) -> Error(e)
  }
}
