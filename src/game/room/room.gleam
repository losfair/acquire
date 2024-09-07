import game/room/checkpointer
import game/room/types.{
  type Block, type Company, type GameStatus, type Player, type RoomSummary,
}
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/iterator
import gleam/json
import gleam/list
import gleam/order
import gleam/otp/actor
import gleam/pair
import gleam/queue.{type Queue}
import gleam/result
import gleam/set
import gleam/string
import glog
import glog/arg
import registry
import utils/random
import utils/shuffle
import utils/watch

pub opaque type Msg {
  External(RoomRequest)
  Save
}

pub type RoomRequest {
  Summarize(ret: Subject(RoomSummary))
  GetSummaryWatcher(ret: Subject(watch.Watch(RoomSummary)))
  Join(player: String, ret: Subject(Result(Nil, String)))
  StartGame(ret: Subject(Result(Nil, String)))
  DropCard(player: String, position: Block, ret: Subject(Result(Nil, String)))
  PlaceCard(
    player: String,
    position: Block,
    company: String,
    ret: Subject(Result(CardPlacement, String)),
  )
  SellStock(player: String, sell: types.Sell, ret: Subject(Result(Nil, String)))
  BuyStock(
    player: String,
    buy: List(types.Buy),
    ret: Subject(Result(Nil, String)),
  )
  EndGame(player: String, ret: Subject(Result(Nil, String)))
}

pub type RoomConfig {
  RoomConfig(rows: Int, cols: Int, companies: List(Company))
}

pub type CardPlacement {
  ValidPlacement(company: Int, merged: List(Block), effect: PlacementEffect)
  NeedCompanyForCreate
  NeedCompanyForMerge(candidates: List(Int))
}

pub type PlacementEffect {
  NoEffect
  CreatedCompany
  ExtendedCompany(acquired: List(Int))
}

pub type Cliff {
  Cliff(stock_price: Int, bonus: #(Int, Int, Int))
}

type St {
  St(
    rng: random.Chacha20Rng,
    logger: glog.Glog,
    ckpt_registry: checkpointer.Registry,
    room_id: String,
    board: Dict(Block, Int),
    players: Queue(Player),
    // A list of player IDs that still need to decide how to deal with their stocks
    // in the current distribution round
    distributing: List(String),
    // id -> size
    acquired_companies: List(#(Int, Int)),
    companies: List(#(Int, Company)),
    card_queue: List(Block),
    status: GameStatus,
    summary: watch.Watch(RoomSummary),
    dirty: Bool,
    internal: Subject(Msg),
  )
}

pub fn msg(x: RoomRequest) -> Msg {
  External(x)
}

pub fn start(
  room_id: String,
  logger: glog.Glog,
  config: String,
  ckpt_registry: checkpointer.Registry,
) -> actor.StartResult(Msg) {
  actor.start_spec(actor.Spec(
    init: fn() { init(room_id, logger, config, ckpt_registry) },
    init_timeout: 5000,
    loop: handle_message,
  ))
}

pub fn start_saved(
  room_id: String,
  logger: glog.Glog,
  saved: types.SavedState,
  ckpt_registry: checkpointer.Registry,
) -> actor.StartResult(Msg) {
  actor.start_spec(actor.Spec(
    init: fn() { init_saved(room_id, logger, saved, ckpt_registry) },
    init_timeout: 5000,
    loop: handle_message,
  ))
}

fn init_try(
  val: Result(a, String),
  then: fn(a) -> actor.InitResult(b, c),
) -> actor.InitResult(b, c) {
  case val {
    Ok(x) -> then(x)
    Error(e) -> actor.Failed(e)
  }
}

fn post_init(st: St) -> actor.InitResult(St, Msg) {
  let sel =
    process.new_selector()
    |> process.selecting(st.internal, fn(x) { x })
  process.send(st.internal, Save)
  actor.Ready(state: st, selector: sel)
}

fn init(
  room_id: String,
  logger: glog.Glog,
  config: String,
  ckpt_registry: checkpointer.Registry,
) -> actor.InitResult(St, Msg) {
  let decoder =
    dynamic.decode3(
      RoomConfig,
      dynamic.field("rows", dynamic.int),
      dynamic.field("cols", dynamic.int),
      dynamic.field("companies", dynamic.list(types.decode_company)),
    )
  use config <- init_try(
    json.decode(config, decoder)
    |> result.map_error(fn(e) {
      "failed to decode config: " <> string.inspect(e)
    }),
  )
  use _ <- init_try(case
    config.rows >= 1
    && config.rows <= 20
    && config.cols >= 1
    && config.cols <= 20
  {
    True -> Ok(Nil)
    False -> Error("invalid rows or cols")
  })
  use _ <- init_try(case list.length(config.companies) {
    x if x >= 1 && x <= 20 -> Ok(Nil)
    _ -> Error("Invalid companies")
  })
  use _ <- init_try(case list.any(config.companies, fn(x) { x.name == "" }) {
    False -> Ok(Nil)
    True -> Error("One or more companies have an empty name")
  })
  let board =
    dict.from_list(
      iterator.range(0, config.rows - 1)
      |> iterator.map(fn(row) {
        iterator.range(1, config.cols)
        |> iterator.map(fn(col) { #(types.Block(row, col), 0) })
      })
      |> iterator.flatten()
      |> iterator.to_list,
    )
  let assert Ok(rng) = random.new_chacha20_rng()
  let companies =
    config.companies
    |> list.index_map(fn(x, index) { #(index + 2, x) })
  let assert Ok(summary) =
    watch.new(types.RoomSummary(
      room_id: room_id,
      board: board,
      players: [],
      companies: companies,
      distributing: [],
      acquired_companies: [],
      status: types.Initializing,
    ))
  post_init(St(
    rng: rng,
    logger: logger,
    ckpt_registry: ckpt_registry,
    room_id: room_id,
    board: board,
    players: queue.new(),
    distributing: list.new(),
    acquired_companies: list.new(),
    companies: companies,
    card_queue: [],
    status: types.Initializing,
    summary: summary,
    dirty: True,
    internal: process.new_subject(),
  ))
}

fn init_saved(
  room_id: String,
  logger: glog.Glog,
  saved: types.SavedState,
  ckpt_registry: checkpointer.Registry,
) -> actor.InitResult(St, Msg) {
  let assert Ok(rng) = random.new_chacha20_rng()
  let assert Ok(summary) =
    watch.new(types.RoomSummary(
      room_id: room_id,
      board: saved.board,
      players: saved.players,
      companies: saved.companies,
      distributing: saved.distributing,
      acquired_companies: saved.acquired_companies |> list.map(pair.first),
      status: saved.status,
    ))
  post_init(St(
    rng: rng,
    logger: logger,
    ckpt_registry: ckpt_registry,
    room_id: room_id,
    board: saved.board,
    players: saved.players |> queue.from_list,
    distributing: saved.distributing,
    acquired_companies: saved.acquired_companies,
    companies: saved.companies,
    card_queue: saved.card_queue,
    status: saved.status,
    summary: summary,
    dirty: False,
    internal: process.new_subject(),
  ))
}

fn handle_message(m: Msg, st: St) -> actor.Next(Msg, St) {
  case m {
    Save -> {
      case st.dirty {
        False -> Nil
        True -> {
          let saved =
            types.SavedState(
              board: st.board,
              players: st.players |> queue.to_list,
              distributing: st.distributing,
              acquired_companies: st.acquired_companies,
              companies: st.companies,
              card_queue: st.card_queue,
              status: st.status,
            )

          let assert Ok(ckpt) =
            process.call(st.ckpt_registry, registry.Lookup(Nil, _), 5000)
          process.send(ckpt, checkpointer.StoreCkpt(st.room_id, saved))
        }
      }

      process.send_after(st.internal, 5000, Save)
      actor.continue(St(..st, dirty: False))
    }
    External(Summarize(ret)) -> {
      process.send(ret, summarize(st))
      actor.continue(st)
    }
    External(GetSummaryWatcher(ret)) -> {
      process.send(ret, st.summary)
      actor.continue(st)
    }
    External(Join(player, ret)) -> {
      case st.status {
        types.Initializing -> {
          case
            queue.to_list(st.players)
            |> list.any(fn(x) { x.id == player })
          {
            True -> {
              process.send(ret, Ok(Nil))
              actor.continue(st)
            }
            False -> {
              let player =
                types.Player(
                  player,
                  6000,
                  cards: list.new(),
                  stocks: st.companies
                    |> list.map(fn(x) { #(pair.first(x), 0) })
                    |> dict.from_list,
                )
              process.send(ret, Ok(Nil))
              save_and_continue(
                St(..st, players: queue.push_back(st.players, player)),
              )
            }
          }
        }
        _ -> {
          process.send(ret, Error("game already started"))
          actor.continue(st)
        }
      }
    }
    External(StartGame(ret)) -> {
      case start_game(st) {
        Ok(st) -> {
          process.send(ret, Ok(Nil))
          save_and_continue(st)
        }
        Error(reason) -> {
          process.send(ret, Error(reason))
          actor.continue(st)
        }
      }
    }
    External(PlaceCard(player, position, company, ret)) ->
      case st.players |> queue.pop_front |> result.map(pair.first) {
        Ok(types.Player(id: id, cards: [], ..)) if id == player -> {
          process.send(
            ret,
            Ok(ValidPlacement(company: 0, merged: [], effect: NoEffect)),
          )
          save_and_continue(St(..st, status: types.Buying))
        }
        _ ->
          case place_card(st, player, company, position) {
            Ok(#(st, x)) -> {
              process.send(ret, Ok(x))
              save_and_continue(st)
            }
            Error(reason) -> {
              process.send(ret, Error(reason))
              actor.continue(st)
            }
          }
      }
    External(DropCard(player, position, ret)) -> {
      case drop_card(st, player, position) {
        Ok(st) -> {
          process.send(ret, Ok(Nil))
          save_and_continue(st)
        }
        Error(reason) -> {
          process.send(ret, Error(reason))
          actor.continue(st)
        }
      }
    }
    External(SellStock(player, sell, ret)) -> {
      case sell_stock(st, player, sell) {
        Ok(st) -> {
          process.send(ret, Ok(Nil))
          save_and_continue(st)
        }
        Error(reason) -> {
          process.send(ret, Error(reason))
          actor.continue(st)
        }
      }
    }
    External(BuyStock(player, buy, ret)) -> {
      case buy_stock(st, player, buy) {
        Ok(st) -> {
          process.send(ret, Ok(Nil))
          save_and_continue(st)
        }
        Error(reason) -> {
          process.send(ret, Error(reason))
          actor.continue(st)
        }
      }
    }
    External(EndGame(player, ret)) -> {
      case end_game(st, player) {
        Ok(st) -> {
          process.send(ret, Ok(Nil))
          save_and_continue(st)
        }
        Error(reason) -> {
          process.send(ret, Error(reason))
          actor.continue(st)
        }
      }
    }
  }
}

fn start_game(st: St) -> Result(St, String) {
  use _ <- result.try(case st.status {
    types.Initializing -> Ok(Nil)
    _ -> Error("game already started")
  })

  let num_players = queue.length(st.players)
  use _ <- result.try(case num_players {
    x if x >= 2 && x <= 6 -> Ok(Nil)
    _ -> Error("number of players must be between 2 and 6")
  })

  let card_queue = dict.keys(st.board) |> shuffle.shuffle(st.rng)
  let preallocated =
    card_queue
    |> iterator.from_list
    |> iterator.take(6 * num_players)
    |> iterator.sized_chunk(6)
  let card_queue = card_queue |> list.drop(6 * num_players)
  let players =
    queue.to_list(st.players) |> shuffle.shuffle(st.rng) |> iterator.from_list
  let players =
    iterator.zip(players, preallocated)
    |> iterator.map(fn(x) {
      let #(p, c) = x
      types.Player(..p, cards: c)
    })
    |> iterator.to_list
    |> queue.from_list

  Ok(St(..st, card_queue: card_queue, players: players, status: types.Placing))
}

fn end_game(st: St, player: String) -> Result(St, String) {
  use _ <- result.try(case st.status {
    types.Placing | types.Finished -> Ok(Nil)
    _ -> Error("game not in placing or finished state")
  })

  let assert Ok(#(current_player, _)) = queue.pop_front(st.players)

  use _ <- result.try(case current_player.id == player {
    True -> Ok(Nil)
    False -> Error("not your turn")
  })

  let empty_positions =
    st.board |> dict.to_list |> list.filter(fn(x) { pair.second(x) == 0 })
  let placeable_positions =
    empty_positions
    |> list.filter_map(fn(x) {
      let #(pos, _) = x
      case check_placement(st.board, pos, "", st.companies) {
        Ok(_) -> Ok(pos)
        Error(_) -> Error(Nil)
      }
    })
  use _ <- result.try(case placeable_positions {
    [] -> Ok(Nil)
    _ ->
      Error(
        "placeable positions: "
        <> string.join(placeable_positions |> list.map(types.fmt_block), ", "),
      )
  })

  let board_it = st.board |> dict.to_list |> iterator.from_list
  let company_sizes: Dict(Int, Int) =
    st.companies
    |> list.map(fn(x) {
      #(
        pair.first(x),
        board_it
          |> iterator.filter(fn(y) { pair.second(y) == pair.first(x) })
          |> iterator.length,
      )
    })
    |> dict.from_list

  let players = queue.to_list(st.players)
  // give bonus
  let players =
    list.fold(st.companies, players, fn(players, company) {
      let #(company_id, company) = company
      let assert Ok(company_size) = dict.get(company_sizes, company_id)
      case company_size {
        x if x >= 2 ->
          give_bonus(cliff(company_size, company.cliff), players, company_id)
        _ -> players
      }
    })
  // sell all stocks for money
  let players =
    players
    |> list.map(fn(player) {
      let money =
        player.stocks
        |> dict.to_list
        |> list.fold(0, fn(money, stock) {
          let #(company_id, stock_count) = stock
          let assert Ok(#(_, company)) =
            list.find(st.companies, fn(x) { pair.first(x) == company_id })
          let assert Ok(company_size) = dict.get(company_sizes, company_id)
          let new_money = case company_size {
            x if x >= 2 -> {
              let cliff = cliff(company_size, company.cliff)
              cliff.stock_price * stock_count
            }
            _ -> 0
          }
          money + new_money
        })
      types.Player(
        ..player,
        stocks: dict.map_values(player.stocks, fn(_, _) { 0 }),
        balance: player.balance + money,
      )
    })

  Ok(St(..st, players: players |> queue.from_list, status: types.Finished))
}

fn buy_stock(st: St, player: String, buy: List(types.Buy)) -> Result(St, String) {
  use _ <- result.try(case st.status {
    types.Buying -> Ok(Nil)
    _ -> Error("game not in buy state")
  })

  use #(player, players) <- result.try(case queue.pop_front(st.players) {
    Ok(#(p, players)) if p.id == player -> Ok(#(p, players))
    _ -> Error("not your turn")
  })

  use _ <- result.try(case list.fold(buy, 0, fn(acc, x) { acc + x.amount }) {
    x if x > 3 -> Error("can't buy more than 3 shares")
    _ -> Ok(Nil)
  })

  let company_sizes: Dict(Int, Int) =
    st.companies
    |> list.map(fn(x) {
      #(
        pair.first(x),
        st.board
          |> dict.to_list
          |> list.filter(fn(y) { pair.second(y) == pair.first(x) })
          |> list.length,
      )
    })
    |> dict.from_list

  let player =
    list.fold(buy, player, fn(player, buy) {
      case
        list.find(st.companies, fn(x) { pair.second(x).name == buy.company })
      {
        Ok(#(company_id, company)) -> {
          let assert Ok(company_size) = dict.get(company_sizes, company_id)
          case company_size {
            x if x >= 2 -> {
              let cliff = cliff(company_size, company.cliff)
              let assert Ok(prev_amount) = dict.get(player.stocks, company_id)
              types.Player(
                ..player,
                balance: player.balance - cliff.stock_price * buy.amount,
                stocks: dict.insert(
                  player.stocks,
                  company_id,
                  prev_amount + buy.amount,
                ),
              )
            }
            _ -> player
          }
        }
        Error(Nil) -> player
      }
    })

  use players <- result.try(case player.balance < 0 {
    True -> Error("insufficient balance")
    False -> Ok(queue.push_back(players, player))
  })

  // per-company stocks are capped at 25
  let affected_companies =
    buy
    |> list.filter(fn(x) { x.amount != 0 })
    |> list.filter_map(fn(x) {
      st.companies
      |> list.find(fn(y) { pair.second(y).name == x.company })
      |> result.map(pair.first)
    })
  let affected_company_stock_count =
    affected_companies
    |> list.map(fn(company_id) {
      let stocks =
        list.fold(queue.to_list(players), 0, fn(acc, player) {
          let assert Ok(stock_count) = dict.get(player.stocks, company_id)
          acc + stock_count
        })
      #(company_id, stocks)
    })
  use _ <- result.try(case
    affected_company_stock_count
    |> list.any(fn(x) { pair.second(x) > 25 })
  {
    True -> Error("stock count exceeds 25")
    False -> Ok(Nil)
  })

  Ok(St(..st, players: players, status: types.Placing))
}

fn sell_stock(st: St, player: String, sell: types.Sell) -> Result(St, String) {
  use _ <- result.try(case st.status {
    types.Distributing -> Ok(Nil)
    _ -> Error("game not in distributing state")
  })

  use st <- result.try(case st.distributing {
    [first, ..rem] if first == player -> Ok(St(..st, distributing: rem))
    _ -> Error("not your turn")
  })

  let player_id = player
  let alive_companies =
    st.board |> dict.values |> list.filter(fn(x) { x >= 2 }) |> set.from_list

  let players =
    st.players
    |> queue.to_list
    |> list.map(fn(player) {
      case player.id == player_id {
        False -> player
        True -> {
          st.acquired_companies
          |> list.fold(player, fn(player, x) {
            let #(id, company_size) = x
            let assert Ok(#(_, company)) =
              list.find(st.companies, fn(x) { pair.first(x) == id })
            let owned =
              player.stocks
              |> dict.get(id)
              |> result.unwrap(0)
            let for_money =
              int.min(
                owned,
                sell.for_money |> dict.get(company.name) |> result.unwrap(0),
              )
            let money =
              cliff(company_size, company.cliff).stock_price * for_money
            let owned = owned - for_money
            let #(owned, stocks) =
              list.fold(
                sell.for_other_stocks
                  |> dict.get(company.name)
                  |> result.unwrap(dict.new())
                  |> dict.to_list,
                #(owned, player.stocks),
                fn(prev, target_company) {
                  let #(owned, stocks) = prev
                  let #(target_company_name, target_company_stocks) =
                    target_company
                  let needed_owned_stocks = target_company_stocks * 2
                  case
                    st.companies
                    |> list.find(fn(x) {
                      pair.second(x).name == target_company_name
                    })
                  {
                    Ok(#(target_id, _)) -> {
                      case
                        needed_owned_stocks <= owned
                        && set.contains(alive_companies, target_id)
                      {
                        True -> #(
                          owned - needed_owned_stocks,
                          stocks
                            |> dict.insert(
                              target_id,
                              {
                                dict.get(stocks, target_id) |> result.unwrap(0)
                              }
                                + target_company_stocks,
                            ),
                        )
                        False -> #(owned, player.stocks)
                      }
                    }
                    _ -> #(owned, player.stocks)
                  }
                },
              )
            types.Player(
              ..player,
              stocks: stocks |> dict.insert(id, owned),
              balance: player.balance + money,
            )
          })
        }
      }
    })
    |> queue.from_list

  let st = St(..st, players: players)
  let st = case st.distributing {
    [] -> St(..st, acquired_companies: [], status: types.Buying)
    _ -> st
  }

  Ok(st)
}

fn drop_card(st: St, player: String, pos: Block) -> Result(St, String) {
  use _ <- result.try(case st.status {
    types.Placing -> Ok(Nil)
    _ -> Error("game not in placing state")
  })

  case check_placement(st.board, pos, "", st.companies) {
    Ok(_) -> Error("this card can still be placed")
    Error(_) -> {
      let assert Ok(#(current_player, q)) = queue.pop_front(st.players)

      use _ <- result.try(case current_player.id == player {
        True -> Ok(Nil)
        False -> Error("not your turn")
      })
      use _ <- result.try(case list.contains(current_player.cards, pos) {
        True -> Ok(Nil)
        False -> Error("you don't have this card")
      })
      let current_player =
        types.Player(
          ..current_player,
          cards: current_player.cards
            |> list.filter(fn(x) { x != pos }),
        )
      Ok(St(..st, players: queue.push_front(q, current_player)))
    }
  }
}

fn place_card(
  st: St,
  player: String,
  company: String,
  pos: Block,
) -> Result(#(St, CardPlacement), String) {
  use _ <- result.try(case st.status {
    types.Placing -> Ok(Nil)
    _ -> Error("game not in placing state")
  })

  use placement <- result.try(check_placement(
    st.board,
    pos,
    company,
    st.companies,
  ))

  use st <- result.try(case placement {
    ValidPlacement(company, merged, effect) -> {
      let assert Ok(#(current_player, q)) = queue.pop_front(st.players)

      use _ <- result.try(case current_player.id == player {
        True -> Ok(Nil)
        False -> Error("not your turn")
      })
      use _ <- result.try(case list.contains(current_player.cards, pos) {
        True -> Ok(Nil)
        False -> Error("you don't have this card")
      })
      let current_player =
        types.Player(
          ..current_player,
          cards: current_player.cards
            |> list.filter(fn(x) { x != pos }),
        )

      let refill_count = int.max(0, 6 - list.length(current_player.cards))
      let cq = list.drop(st.card_queue, refill_count)
      let current_player =
        types.Player(
          ..current_player,
          cards: list.concat([
            list.take(st.card_queue, refill_count),
            current_player.cards,
          ]),
        )

      let old_board = st.board |> dict.to_list |> iterator.from_list
      let board = dict.insert(st.board, pos, company)
      let board =
        merged
        |> list.fold(board, fn(board, x) { dict.insert(board, x, company) })
      let q = queue.push_front(q, current_player)
      let st =
        St(..st, board: board, players: q, card_queue: cq, status: types.Buying)

      let st = case effect {
        NoEffect -> st
        CreatedCompany -> {
          glog.noticef(st.logger, "created company: ~s, merged: ~s", [
            arg.new(int.to_string(company)),
            arg.new(string.inspect(merged)),
          ])
          let assert Ok(#(player, q)) = queue.pop_front(st.players)
          let assert Ok(current_stocks) = dict.get(player.stocks, company)
          let player =
            types.Player(
              ..player,
              stocks: dict.insert(player.stocks, company, current_stocks + 1),
            )
          let q = queue.push_front(q, player)
          St(..st, players: q)
        }
        ExtendedCompany(acquired) -> {
          glog.noticef(st.logger, "extended company: ~s/~s, merged: ~s", [
            arg.new(int.to_string(company)),
            arg.new(string.inspect(acquired)),
            arg.new(string.inspect(merged)),
          ])
          // Distribute to top 3 players by stock holding
          let players = st.players |> queue.to_list
          let company_sizes: Dict(Int, Int) =
            st.companies
            |> list.filter(fn(x) {
              case list.find(acquired, fn(y) { pair.first(x) == y }) {
                Ok(_) -> True
                Error(Nil) -> False
              }
            })
            |> list.map(fn(x) {
              #(
                pair.first(x),
                old_board
                  |> iterator.filter(fn(y) { pair.second(y) == pair.first(x) })
                  |> iterator.length,
              )
            })
            |> dict.from_list
          let players =
            list.fold(acquired, players, fn(players, company) {
              let assert Ok(company_info) =
                st.companies |> list.find(fn(x) { pair.first(x) == company })
              let assert Ok(company_size) = dict.get(company_sizes, company)
              give_bonus(
                cliff(company_size, pair.second(company_info).cliff),
                players,
                company,
              )
            })
          let st = St(..st, players: queue.from_list(players))
          case acquired {
            [] -> st
            _ ->
              St(
                ..st,
                distributing: players
                  |> list.map(fn(x) { x.id }),
                acquired_companies: company_sizes |> dict.to_list,
                status: types.Distributing,
              )
          }
        }
      }

      Ok(st)
    }
    NeedCompanyForCreate | NeedCompanyForMerge(_) -> Ok(st)
  })

  Ok(#(st, placement))
}

fn check_placement(
  board: Dict(Block, Int),
  pos: Block,
  company: String,
  companies: List(#(Int, Company)),
) -> Result(CardPlacement, String) {
  // position must be within bounds and not occupied
  use _ <- result.try(case dict.get(board, pos) {
    Ok(x) if x == 0 -> Ok(Nil)
    Ok(_) -> Error("position is occupied")
    Error(Nil) -> Error("position not on board")
  })

  // company if specified must exist
  use company <- result.try(case company {
    "" -> Ok(0)
    _ ->
      case list.find(companies, fn(x) { pair.second(x).name == company }) {
        Ok(#(i, _)) -> Ok(i)
        Error(Nil) -> Error("company not found")
      }
  })

  // if more than one neighboring block are part of a safe company
  // and they are not the same safe company, fail
  let all_neighbors = neighbors(board, pos) |> iterator.map(pair.swap)
  let distinct_neighbor_companies: Dict(Int, Block) =
    all_neighbors
    |> iterator.filter(fn(x) { pair.first(x) >= 2 })
    |> iterator.to_list
    |> dict.from_list
  let distinct_neighbor_blocks =
    distinct_neighbor_companies
    |> dict.map_values(fn(company, cur) {
      dfs(board, dict.insert(dict.new(), cur, Nil), cur, company)
    })
    |> dict.to_list
    |> iterator.from_list
    |> iterator.append(
      all_neighbors
      |> iterator.filter(fn(x) { pair.first(x) == 1 })
      |> iterator.map(fn(x) { #(1, dict.from_list([#(pair.second(x), Nil)])) }),
    )
  use _ <- result.try(case
    distinct_neighbor_blocks
    |> iterator.filter(fn(x) { dict.size(pair.second(x)) >= 11 })
    |> iterator.to_list
  {
    [] | [_] -> Ok(Nil)
    _ -> Error("more than one safe neighbors")
  })

  let largest_neighbor_size =
    distinct_neighbor_blocks
    |> iterator.fold(0, fn(a, b) { int.max(a, dict.size(pair.second(b))) })
  let largest_neighbors =
    distinct_neighbor_blocks
    |> iterator.filter_map(fn(x) {
      let #(company, blocks) = x
      case dict.size(blocks) == largest_neighbor_size {
        True -> Ok(company)
        False -> Error(Nil)
      }
    })
    |> iterator.to_list
  let get_merged_blocks = fn() {
    distinct_neighbor_blocks
    |> iterator.map(pair.second)
    |> iterator.fold(dict.new(), dict.merge)
    |> dict.keys
  }
  let get_merged_companies = fn(merger: Int) {
    distinct_neighbor_blocks
    |> iterator.map(pair.first)
    |> iterator.filter(fn(x) { x >= 2 && x != merger })
    |> iterator.to_list
  }
  case largest_neighbors {
    // if we don't have neighbors, this is a new standalone block
    [] -> Ok(ValidPlacement(1, [], NoEffect))
    // if we have neighbors but none of them are companies, we created a new company
    _ if largest_neighbor_size == 1 ->
      case company {
        x if x >= 2 -> {
          case
            board
            |> dict.values
            |> list.any(fn(x) { x == company })
          {
            True -> Error("company already exists")
            False ->
              Ok(ValidPlacement(company, get_merged_blocks(), CreatedCompany))
          }
        }
        _ -> {
          let num_distinct_companies =
            board
            |> dict.values
            |> list.filter(fn(x) { x >= 2 })
            |> set.from_list
            |> set.size
          case num_distinct_companies == list.length(companies) {
            True -> Error("all companies have been placed")
            False -> Ok(NeedCompanyForCreate)
          }
        }
      }
    // if at least one of our neighbors is a company, it is extended
    // - if there is a single largest neighbor company, extend it
    [x] -> {
      Ok(ValidPlacement(
        x,
        get_merged_blocks(),
        ExtendedCompany(get_merged_companies(x)),
      ))
    }
    // - otherwise, require player input
    _ -> {
      case largest_neighbors |> list.find(fn(x) { x == company }) {
        Ok(_) ->
          Ok(ValidPlacement(
            company,
            get_merged_blocks(),
            ExtendedCompany(get_merged_companies(company)),
          ))
        Error(Nil) ->
          Ok(NeedCompanyForMerge(
            candidates: largest_neighbors |> list.filter(fn(x) { x >= 2 }),
          ))
      }
    }
  }
}

fn dfs(
  board: Dict(Block, Int),
  seen: Dict(Block, Nil),
  cur: Block,
  company: Int,
) -> Dict(Block, Nil) {
  neighbors(board, cur)
  |> iterator.filter(fn(x) { pair.second(x) == company })
  |> iterator.fold(seen, fn(seen, cur) {
    let #(cur, company) = cur
    case dict.has_key(seen, cur) {
      True -> seen
      False -> dfs(board, dict.insert(seen, cur, Nil), cur, company)
    }
  })
}

fn neighbors(
  board: Dict(Block, Int),
  x: Block,
) -> iterator.Iterator(#(Block, Int)) {
  [
    types.Block(row: x.row - 1, col: x.col),
    types.Block(row: x.row + 1, col: x.col),
    types.Block(row: x.row, col: x.col - 1),
    types.Block(row: x.row, col: x.col + 1),
  ]
  |> iterator.from_list
  |> iterator.filter_map(fn(x) {
    dict.get(board, x) |> result.map(fn(y) { #(x, y) })
  })
  |> iterator.filter(fn(x) { pair.second(x) >= 1 })
}

pub fn cliff(size: Int, offset: Int) -> Cliff {
  let level = case size {
    2 -> 2
    3 -> 3
    4 -> 4
    5 -> 5
    x if x >= 6 && x <= 10 -> 6
    x if x >= 11 && x <= 20 -> 7
    x if x >= 21 && x <= 30 -> 8
    x if x >= 31 && x <= 40 -> 9
    x if x >= 41 -> 10
    _ -> panic as { "cliff: unexpected size: " <> int.to_string(size) }
  }
  let level = level + offset
  Cliff(stock_price: 100 * level, bonus: #(
    1000 * level,
    case int.is_odd(level) {
      True -> level * 750 - 50
      False -> level * 750
    },
    500 * level,
  ))
}

fn save_and_continue(st: St) -> actor.Next(Msg, St) {
  watch.modify(st.summary, summarize(st))
  actor.continue(St(..st, dirty: True))
}

fn summarize(st: St) -> RoomSummary {
  types.RoomSummary(
    room_id: st.room_id,
    board: st.board,
    players: st.players |> queue.to_list,
    companies: st.companies,
    distributing: st.distributing,
    acquired_companies: st.acquired_companies |> list.map(pair.first),
    status: st.status,
  )
}

pub fn encode_card_placement(p: CardPlacement) -> json.Json {
  case p {
    ValidPlacement(company, merged, effect) -> {
      json.object([
        #("status", json.string("valid_placement")),
        #("company", json.int(company)),
        #(
          "merged",
          json.array(merged, fn(x) { json.string(types.fmt_block(x)) }),
        ),
        #("effect", encode_placement_effect(effect)),
      ])
    }
    NeedCompanyForCreate ->
      json.object([#("status", json.string("need_company_for_create"))])
    NeedCompanyForMerge(candidates) ->
      json.object([
        #("status", json.string("need_company_for_merge")),
        #("candidates", json.array(candidates, json.int)),
      ])
  }
}

pub fn encode_placement_effect(x: PlacementEffect) -> json.Json {
  case x {
    NoEffect -> json.object([#("kind", json.string("no_effect"))])
    CreatedCompany -> json.object([#("kind", json.string("created_company"))])
    ExtendedCompany(acquired) -> {
      json.object([
        #("kind", json.string("extended_company")),
        #("acquired", json.array(acquired, fn(x) { json.int(x) })),
      ])
    }
  }
}

fn top3_holdings_desc(
  players: List(types.Player),
  company: Int,
) -> List(#(String, Int)) {
  players
  |> list.map(fn(x) {
    let assert Ok(stocks) = x.stocks |> dict.get(company)
    #(x.id, stocks)
  })
  |> list.sort(fn(a, b) {
    int.compare(pair.second(a), pair.second(b))
    |> order.negate
  })
  |> list.take(3)
  |> list.filter(fn(x) { pair.second(x) != 0 })
}

fn give_bonus(
  cliff: Cliff,
  players: List(types.Player),
  company: Int,
) -> List(types.Player) {
  let top3 = top3_holdings_desc(players, company)
  let #(div1, div2, div3) = cliff.bonus
  let #(div1, div2, div3) = case top3 {
    [#(_, hold1), #(_, hold2), #(_, hold3)] if hold1 == hold2 && hold2 == hold3 -> {
      let x = round_up_to_100({ div1 + div2 + div3 } / 3)
      #(x, x, x)
    }
    [#(_, hold1), #(_, hold2), ..] if hold1 == hold2 -> {
      let x = round_up_to_100({ div1 + div2 } / 2)
      #(x, x, div3)
    }
    [_, #(_, hold2), #(_, hold3)] if hold2 == hold3 -> {
      let x = round_up_to_100({ div2 + div3 } / 2)
      #(div1, x, x)
    }
    _ -> #(div1, div2, div3)
  }
  players
  |> list.map(fn(player) {
    case top3 {
      [#(x, _), ..] if x == player.id ->
        types.Player(..player, balance: player.balance + div1)
      [_, #(x, _), ..] if x == player.id ->
        types.Player(..player, balance: player.balance + div2)
      [_, _, #(x, _), ..] if x == player.id ->
        types.Player(..player, balance: player.balance + div3)
      _ -> player
    }
  })
}

fn round_up_to_100(x: Int) -> Int {
  case x % 100 {
    0 -> x
    y -> x + 100 - y
  }
}
