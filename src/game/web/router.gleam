import game/room/manager.{type ManagerRequest}
import game/room/room
import game/room/types as room_types
import gleam/bytes_builder
import gleam/dynamic
import gleam/erlang
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_builder
import mist
import utils/mac
import utils/watch
import wisp.{type Request, type Response}

pub fn create_handler(
  m: Subject(ManagerRequest),
  secret_key_base: String,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  let wisp_handler = wisp.mist_handler(handle_request(m, _), secret_key_base)
  let h =
    mac.create_poly1305_hasher(
      secret_key_base: secret_key_base,
      ctx: "room-events",
    )
  fn(req: request.Request(mist.Connection)) -> response.Response(
    mist.ResponseData,
  ) {
    case request.path_segments(req) {
      ["rooms", room_id, "events"] -> room_watch(req, h, m, room_id)
      _ -> wisp_handler(req)
    }
  }
}

fn handle_request(m: Subject(ManagerRequest), req: Request) -> Response {
  use req <- middleware(req)
  let assert Ok(priv) = erlang.priv_directory("acquire")

  let uri = request.to_uri(req)
  let req = case string.last(uri.path) {
    Ok("/") -> request.set_path(req, uri.path <> "index.html")
    _ -> req
  }
  use <- wisp.serve_static(req, under: "/", from: priv <> "/frontend")

  case wisp.path_segments(req) {
    [] -> home_page(req)
    ["rooms"] -> create_room(m, req)
    ["rooms", room_id] -> with_room(m, req, room_id, room_info)
    ["rooms", room_id, "join"] -> with_room(m, req, room_id, do_join)
    ["rooms", room_id, "start_game"] -> with_room(m, req, room_id, do_start)
    ["rooms", room_id, "end_game"] -> with_room(m, req, room_id, do_end)
    ["rooms", room_id, "place_card"] ->
      with_room(m, req, room_id, do_place_card)
    ["rooms", room_id, "drop_card"] -> with_room(m, req, room_id, do_drop_card)
    ["rooms", room_id, "sell_stock"] ->
      with_room(m, req, room_id, do_sell_stock)
    ["rooms", room_id, "buy_stock"] -> with_room(m, req, room_id, do_buy_stock)
    _ -> wisp.not_found()
  }
}

fn home_page(_req: Request) -> Response {
  wisp.html_response(string_builder.from_string("Hello from Acquire"), 200)
}

fn create_room(m: Subject(ManagerRequest), req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)
  use config <- wisp.require_string_body(req)
  let query = wisp.get_query(req)
  let nonce = list.key_find(query, "nonce") |> result.unwrap("")
  let timestamp =
    list.key_find(query, "timestamp")
    |> result.unwrap("")
    |> int.parse
    |> result.unwrap(0)
  case process.call(m, manager.CreateRoom(config, timestamp, nonce, _), 5000) {
    Ok(room) -> {
      let summary = manager.call(room, room.Summarize(_))
      wisp.json_response(
        room_types.encode_room_summary(summary) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

fn room_info(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Get)
  let summary = manager.call(room, room.Summarize(_))
  wisp.json_response(
    room_types.encode_room_summary(summary) |> json.to_string_builder,
    200,
  )
}

fn room_watch(
  req: request.Request(mist.Connection),
  h: mac.Poly1305Hasher,
  m: Subject(ManagerRequest),
  room_id: String,
) -> response.Response(mist.ResponseData) {
  let last_event_id =
    request.get_header(req, "last-event-id") |> result.unwrap("")
  case process.call(m, manager.GetRoom(room_id, _), 5000) {
    Ok(option.Some(room)) -> {
      let w = manager.call(room, room.GetSummaryWatcher(_))
      mist.server_sent_events(
        req,
        response.new(200)
          |> response.map(fn(_) { mist.Bytes(bytes_builder.new()) })
          |> add_cors_headers,
        fn() {
          let subject = process.new_subject()
          let mon = process.monitor_process(watch.pid(w))
          watch.wait_ext(
            w,
            fn(x) {
              mac.poly1305_authenticate_data(h, erlang.term_to_binary(x))
              != last_event_id
            },
            subject,
          )
          actor.Ready(
            state: subject,
            selector: process.new_selector()
              |> process.selecting(subject, Ok)
              |> process.selecting_process_down(mon, Error),
          )
        },
        fn(m, sse, subject) {
          let m = case m {
            Ok(x) -> x
            Error(error) ->
              panic as { "room is down: " <> string.inspect(error) }
          }

          let last_event_id =
            mac.poly1305_authenticate_data(h, erlang.term_to_binary(m))
          let sent =
            mist.event(
              room_types.encode_room_summary(m) |> json.to_string_builder,
            )
            |> mist.event_id(last_event_id)
            |> mist.send_event(sse, _)
          case sent {
            Ok(Nil) -> {
              watch.wait_ext(
                w,
                fn(x) {
                  mac.poly1305_authenticate_data(h, erlang.term_to_binary(x))
                  != last_event_id
                },
                subject,
              )
              actor.continue(subject)
            }
            Error(Nil) -> actor.Stop(process.Normal)
          }
        },
      )
    }
    Ok(option.None) ->
      response.new(404)
      |> response.map(fn(_) { mist.Bytes(bytes_builder.new()) })
    Error(reason) ->
      response.new(500)
      |> response.map(fn(_) {
        bytes_builder.new()
        |> bytes_builder.append_string(
          json.object([#("error", json.string(reason))])
          |> json.to_string,
        )
        |> mist.Bytes
      })
  }
}

type JoinMove {
  JoinMove(player: String)
}

fn do_join(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Post)
  use move <- wisp.require_json(req)
  let result = {
    let decoder =
      dynamic.decode1(JoinMove, dynamic.field("player", dynamic.string))
    use move <- result.try(
      decoder(move) |> result.map_error(fn(_) { "failed to decode move" }),
    )
    manager.call(room, room.Join(player: move.player, ret: _))
  }
  case result {
    Ok(_) -> {
      let summary = manager.call(room, room.Summarize(_))
      wisp.json_response(
        room_types.encode_room_summary(summary) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

fn do_start(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Post)
  let result = manager.call(room, room.StartGame(ret: _))

  case result {
    Ok(_) -> {
      let summary = manager.call(room, room.Summarize(_))
      wisp.json_response(
        room_types.encode_room_summary(summary) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

type EndGameMove {
  EndGameMove(player: String)
}

fn do_end(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Post)
  use move <- wisp.require_json(req)
  let result = {
    let decoder =
      dynamic.decode1(EndGameMove, dynamic.field("player", dynamic.string))
    use move <- result.try(
      decoder(move) |> result.map_error(fn(_) { "failed to decode move" }),
    )
    manager.call(room, room.EndGame(player: move.player, ret: _))
  }

  case result {
    Ok(_) -> {
      let summary = manager.call(room, room.Summarize(_))
      wisp.json_response(
        room_types.encode_room_summary(summary) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

type PlaceCardMove {
  PlaceCardMove(player: String, card: String, company: String)
}

fn do_place_card(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Post)
  use move <- wisp.require_json(req)
  let result = {
    let decoder =
      dynamic.decode3(
        PlaceCardMove,
        dynamic.field("player", dynamic.string),
        dynamic.field("card", dynamic.string),
        dynamic.field("company", dynamic.string),
      )
    use move <- result.try(
      decoder(move) |> result.map_error(fn(_) { "failed to decode move" }),
    )
    use block <- result.try(
      room_types.parse_block(move.card)
      |> result.map_error(fn(_) { "invalid card" }),
    )
    manager.call(room, room.PlaceCard(
      player: move.player,
      position: block,
      company: move.company,
      ret: _,
    ))
  }
  case result {
    Ok(placement) -> {
      wisp.json_response(
        room.encode_card_placement(placement) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

type DropCardMove {
  DropCardMove(player: String, card: String)
}

fn do_drop_card(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Post)
  use move <- wisp.require_json(req)
  let result = {
    let decoder =
      dynamic.decode2(
        DropCardMove,
        dynamic.field("player", dynamic.string),
        dynamic.field("card", dynamic.string),
      )
    use move <- result.try(
      decoder(move) |> result.map_error(fn(_) { "failed to decode move" }),
    )
    use block <- result.try(
      room_types.parse_block(move.card)
      |> result.map_error(fn(_) { "invalid card" }),
    )
    manager.call(room, room.DropCard(
      player: move.player,
      position: block,
      ret: _,
    ))
  }
  case result {
    Ok(_) -> {
      let summary = manager.call(room, room.Summarize(_))
      wisp.json_response(
        room_types.encode_room_summary(summary) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

type SellStockMove {
  SellStockMove(player: String, sell: room_types.Sell)
}

fn do_sell_stock(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Post)
  use move <- wisp.require_json(req)
  let result = {
    let decoder =
      dynamic.decode2(
        SellStockMove,
        dynamic.field("player", dynamic.string),
        dynamic.field("sell", room_types.decode_sell),
      )
    use move <- result.try(
      decoder(move) |> result.map_error(fn(_) { "failed to decode move" }),
    )
    manager.call(room, room.SellStock(
      player: move.player,
      sell: move.sell,
      ret: _,
    ))
  }
  case result {
    Ok(_) -> {
      let summary = manager.call(room, room.Summarize(_))
      wisp.json_response(
        room_types.encode_room_summary(summary) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

type BuyStockMove {
  BuyStockMove(player: String, buy: List(room_types.Buy))
}

fn do_buy_stock(req: Request, _room_id: String, room: manager.Room) -> Response {
  use <- wisp.require_method(req, http.Post)
  use move <- wisp.require_json(req)
  let result = {
    let decoder =
      dynamic.decode2(
        BuyStockMove,
        dynamic.field("player", dynamic.string),
        dynamic.field("buy", dynamic.list(room_types.decode_buy)),
      )
    use move <- result.try(
      decoder(move) |> result.map_error(fn(_) { "failed to decode move" }),
    )
    manager.call(room, room.BuyStock(player: move.player, buy: move.buy, ret: _))
  }
  case result {
    Ok(_) -> {
      let summary = manager.call(room, room.Summarize(_))
      wisp.json_response(
        room_types.encode_room_summary(summary) |> json.to_string_builder,
        200,
      )
    }
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        400,
      )
  }
}

fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- handle_options(req)
  use req <- wisp.handle_head(req)

  handle_request(req)
  |> add_cors_headers
}

fn handle_options(
  req: Request,
  next handler: fn(Request) -> Response,
) -> Response {
  case req.method {
    http.Options ->
      response.new(200) |> response.set_body(wisp.Empty) |> add_cors_headers
    _ -> handler(req)
  }
}

fn add_cors_headers(resp: response.Response(a)) -> response.Response(a) {
  resp
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_header("access-control-allow-methods", "POST, GET, OPTIONS")
  |> response.set_header(
    "access-control-allow-headers",
    "last-event-id, content-type",
  )
}

fn with_room(
  m: Subject(ManagerRequest),
  req: a,
  room_id: String,
  f: fn(a, String, manager.Room) -> wisp.Response,
) -> wisp.Response {
  case process.call(m, manager.GetRoom(room_id, _), 5000) {
    Ok(option.Some(room)) -> {
      f(req, room_id, room)
    }
    Ok(option.None) ->
      wisp.json_response(
        json.object([#("error", json.string("room not found"))])
          |> json.to_string_builder,
        404,
      )
    Error(reason) ->
      wisp.json_response(
        json.object([#("error", json.string(reason))])
          |> json.to_string_builder,
        500,
      )
  }
}
