import game/room/types
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glog
import glog/arg
import radish
import radish/error
import registry
import utils/utils

const redis_timeout_ms = 5000

const ping_interval_ms = 3000

const room_prefix = "acquire:room:"

pub type Registry =
  Subject(registry.RegistryRequest(Nil, Subject(CheckpointRequest)))

pub type CheckpointRequest {
  StoreCkpt(room_id: String, state: types.SavedState)
  LoadCkpt(room_id: String, ret: Subject(Result(types.SavedState, Nil)))
}

type St {
  St(
    logger: glog.Glog,
    internal: Subject(M),
    redis: Option(Subject(radish.Message)),
    redis_host: String,
    redis_port: Int,
    redis_options: List(radish.StartOption),
  )
}

pub opaque type M {
  External(CheckpointRequest)
  Boot
  Ping
}

pub fn start(
  logger: glog.Glog,
  registry: Registry,
  redis_host redis_host: String,
  redis_port redis_port: Int,
  redis_options redis_options: List(radish.StartOption),
) -> actor.StartResult(M) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let incoming = process.new_subject()
      let internal = process.new_subject()
      let sel =
        process.new_selector()
        |> process.selecting(incoming, External)
        |> process.selecting(internal, fn(x) { x })
      process.send(internal, Boot)
      process.send(registry, registry.Register(Nil, incoming))
      actor.Ready(
        state: St(
          logger: logger,
          internal: internal,
          redis: None,
          redis_host: redis_host,
          redis_port: redis_port,
          redis_options: redis_options,
        ),
        selector: sel,
      )
    },
    init_timeout: 5000,
    loop: handle_message,
  ))
}

fn handle_message(m: M, st: St) -> actor.Next(M, St) {
  case m {
    Boot -> {
      case radish.start(st.redis_host, st.redis_port, st.redis_options) {
        Ok(redis) -> {
          glog.noticef(st.logger, "checkpointer connected to redis", [])
          process.send(st.internal, Ping)
          actor.continue(St(..st, redis: Some(redis)))
        }
        Error(x) -> panic as { "failed to start redis: " <> string.inspect(x) }
      }
    }
    Ping -> {
      let assert Some(redis) = st.redis
      let start_time = utils.current_time_millis()
      let assert Ok(_) = radish.ping(redis, redis_timeout_ms)
      let dur = float.subtract(utils.current_time_millis(), start_time)
      glog.infof(st.logger, "redis latency: ~sms", [
        arg.new(float.to_string(dur)),
      ])
      process.send_after(st.internal, ping_interval_ms, Ping)
      actor.continue(st)
    }
    External(LoadCkpt(room_id, ret)) -> {
      let assert Some(redis) = st.redis
      let assert Ok(result) =
        radish.get(redis, room_prefix <> room_id, redis_timeout_ms)
        |> result.map(Some)
        |> result.try_recover(fn(e) {
          case e {
            error.NotFound -> Ok(None)
            _ -> Error(e)
          }
        })
      let result = case result {
        Some(x) ->
          json.decode(x, decode_saved_state)
          |> result.map_error(fn(e) {
            glog.warningf(
              st.logger,
              "failed to decode saved state for room ~s, returning None: ~s",
              [arg.new(room_id), arg.new(string.inspect(e))],
            )
            Nil
          })
          |> result.map(fn(x) {
            glog.noticef(st.logger, "loaded ckpt: ~s", [arg.new(room_id)])
            x
          })
        None -> Error(Nil)
      }
      process.send(ret, result)
      actor.continue(st)
    }
    External(StoreCkpt(room_id, ckpt)) -> {
      let assert Some(redis) = st.redis
      let ckpt = encode_saved_state(ckpt) |> json.to_string
      let assert Ok(_) =
        radish.set(redis, room_prefix <> room_id, ckpt, redis_timeout_ms)
      glog.noticef(st.logger, "stored ckpt: ~s", [arg.new(room_id)])
      actor.continue(st)
    }
  }
}

fn encode_saved_state(x: types.SavedState) -> json.Json {
  json.object([
    #("board", types.encode_board(x.board)),
    #("players", json.array(x.players, types.encode_player)),
    #("distributing", json.array(x.distributing, json.string)),
    #(
      "acquired_companies",
      json.object(
        x.acquired_companies
        |> list.map(fn(x) {
          let #(k, v) = x
          #(int.to_string(k), json.int(v))
        }),
      ),
    ),
    #(
      "companies",
      json.object(
        x.companies
        |> list.map(fn(x) {
          let #(k, v) = x
          #(int.to_string(k), types.encode_company(v))
        }),
      ),
    ),
    #(
      "card_queue",
      json.array(x.card_queue, fn(x) { json.string(types.fmt_block(x)) }),
    ),
    #("status", types.encode_game_status(x.status)),
  ])
}

fn decode_saved_state(
  x: Dynamic,
) -> Result(types.SavedState, List(dynamic.DecodeError)) {
  dynamic.decode7(
    types.SavedState,
    dynamic.field("board", types.decode_board),
    dynamic.field("players", dynamic.list(types.decode_player)),
    fn(x) {
      dynamic.optional_field("distributing", dynamic.list(dynamic.string))(x)
      |> result.map(option.unwrap(_, list.new()))
    },
    fn(x) {
      dynamic.optional_field("acquired_companies", fn(x) {
        dynamic.dict(types.decode_string_encoded_integer, dynamic.int)(x)
        |> result.map(dict.to_list)
      })(x)
      |> result.map(option.unwrap(_, list.new()))
    },
    dynamic.field("companies", fn(x) {
      dynamic.dict(types.decode_string_encoded_integer, types.decode_company)(x)
      |> result.map(dict.to_list)
    }),
    dynamic.field("card_queue", dynamic.list(types.parse_block_dynamic)),
    dynamic.field("status", types.decode_game_status),
  )(x)
}
