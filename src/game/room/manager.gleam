import game/room/checkpointer
import game/room/room
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang
import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/int
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import glog
import glog/arg
import glog/field
import registry
import utils/binary
import utils/hexcodec
import utils/utils

pub type ManagerRequest {
  CreateRoom(
    config: String,
    timestamp: Int,
    nonce: String,
    ret: Subject(Result(Room, String)),
  )
  GetRoom(room_id: String, ret: Subject(Result(Option(Room), String)))
  Crash(process.ExitMessage)
}

type St {
  St(
    logger: glog.Glog,
    ckpt_registry: checkpointer.Registry,
    rooms: Dict(String, Room),
    pid2room: Dict(Pid, String),
  )
}

pub type Room {
  Room(tx: Subject(room.Msg))
}

pub fn call(room: Room, req: fn(Subject(a)) -> room.RoomRequest) -> a {
  process.call(room.tx, fn(x) { room.msg(req(x)) }, 5000)
}

pub fn start(
  logger: glog.Glog,
  ckpt_registry: checkpointer.Registry,
) -> actor.StartResult(ManagerRequest) {
  actor.start_spec(actor.Spec(
    init: fn() {
      process.trap_exits(True)

      actor.Ready(
        state: St(
          logger: logger,
          ckpt_registry: ckpt_registry,
          rooms: dict.new(),
          pid2room: dict.new(),
        ),
        selector: process.new_selector()
          |> process.selecting_trapped_exits(Crash),
      )
    },
    init_timeout: 5000,
    loop: handle_message,
  ))
}

fn handle_message(m: ManagerRequest, st: St) -> actor.Next(ManagerRequest, St) {
  case m {
    CreateRoom(config, timestamp, nonce, ret) -> {
      let now = float.round(utils.current_time_millis())
      let hash =
        crypto.hash(
          crypto.Sha256,
          erlang.term_to_binary(#("v1", config, timestamp, nonce)),
        )
      let time_prefix = binary.encode_unsigned(timestamp)
      let time_prefix = <<
        0:size({ int.max(6 - bit_array.byte_size(time_prefix), 0) * 8 }),
        time_prefix:bits,
      >>
      let time_prefix = hexcodec.encode_hex(time_prefix)
      let room_id =
        string.concat([
          time_prefix,
          "-",
          hexcodec.encode_hex(
            bit_array.slice(hash, 12, 20) |> result.unwrap(<<>>),
          ),
        ])
      let result = case dict.get(st.rooms, room_id) {
        Ok(room) -> Ok(#(room, st))
        Error(Nil) -> {
          let time_within_bounds = int.absolute_value(now - timestamp) < 300_000
          case time_within_bounds {
            False ->
              Error(
                string.concat([
                  "timestamp out of bounds: ",
                  int.to_string(now),
                  ", ",
                  int.to_string(timestamp),
                ]),
              )
            True -> {
              use saved <- result.try(boot_saved(st, room_id))
              use room <- result.try(case saved {
                option.Some(x) -> Ok(x)
                option.None ->
                  room.start(
                    room_id,
                    st.logger
                      |> glog.add_field(field.new("module", "room"))
                      |> glog.add_field(field.new("room", room_id)),
                    config,
                    st.ckpt_registry,
                  )
                  |> result.map(Room)
                  |> result.map_error(fn(e) {
                    glog.warningf(st.logger, "failed to start new room: ~s", [
                      arg.new(string.inspect(e)),
                    ])
                    "failed to start room"
                  })
              })
              Ok(#(room, put_room(st, room_id, room)))
            }
          }
        }
      }
      let st = case result {
        Ok(#(room, st)) -> {
          process.send(ret, Ok(room))
          st
        }
        Error(msg) -> {
          process.send(ret, Error(msg))
          st
        }
      }
      actor.continue(st)
    }
    GetRoom(room_id, ret) -> {
      case dict.get(st.rooms, room_id) {
        Ok(room) -> {
          process.send(ret, Ok(option.Some(room)))
          actor.continue(st)
        }
        Error(Nil) ->
          case boot_saved(st, room_id) {
            Ok(option.Some(room)) -> {
              let st = put_room(st, room_id, room)
              process.send(ret, Ok(option.Some(room)))
              actor.continue(st)
            }
            Ok(option.None) -> {
              process.send(ret, Ok(option.None))
              actor.continue(st)
            }
            Error(e) -> {
              process.send(ret, Error(e))
              actor.continue(st)
            }
          }
      }
    }
    Crash(msg) -> {
      let st = case dict.get(st.pid2room, msg.pid) {
        Ok(room_id) -> {
          glog.warningf(st.logger, "room crashed: ~w/~s", [
            arg.new(msg.pid),
            arg.new(room_id),
          ])
          St(
            ..st,
            rooms: dict.delete(st.rooms, room_id),
            pid2room: dict.delete(st.pid2room, msg.pid),
          )
        }
        Error(Nil) -> st
      }
      actor.continue(st)
    }
  }
}

fn boot_saved(st: St, room_id: String) -> Result(Option(Room), String) {
  use ckpt <- result.try(
    process.try_call(st.ckpt_registry, registry.Lookup(Nil, _), 5000)
    |> result.map_error(fn(_) { "failed to get checkpointer" }),
  )
  case ckpt {
    Ok(ckpt) -> {
      use ckpt <- result.try(
        process.try_call(ckpt, checkpointer.LoadCkpt(room_id, _), 5000)
        |> result.map_error(fn(_) { "failed to load checkpoint" }),
      )
      case ckpt {
        Ok(ckpt) -> {
          room.start_saved(
            room_id,
            st.logger
              |> glog.add_field(field.new("module", "room"))
              |> glog.add_field(field.new("room", room_id)),
            ckpt,
            st.ckpt_registry,
          )
          |> result.map(fn(x) { option.Some(Room(x)) })
          |> result.map_error(fn(e) {
            glog.warningf(
              st.logger,
              "failed to start room from saved state: ~s",
              [arg.new(string.inspect(e))],
            )
            "failed to start room"
          })
        }
        Error(Nil) -> Ok(option.None)
      }
    }
    Error(Nil) -> Ok(option.None)
  }
}

fn put_room(st: St, room_id: String, room: Room) -> St {
  St(
    ..st,
    rooms: dict.insert(st.rooms, room_id, room),
    pid2room: dict.insert(st.pid2room, process.subject_owner(room.tx), room_id),
  )
}
