import game/room/checkpointer
import game/room/manager
import game/web/router
import gleam/dynamic.{type Dynamic}
import gleam/erlang/os
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/supervisor
import gleam/result
import gleam/set
import gleam/string
import glog
import glog/arg
import glog/field
import glog/level
import mist
import radish
import registry
import utils/utils
import wisp

pub fn main() {
  let logger = glog.new()
  glog.set_primary_log_level(level.All)
  glog.set_default_config()

  let ret = entry(logger)

  // give some time for the logger to flush
  process.sleep(10)

  case ret {
    Ok(Nil) -> Nil
    Error(e) -> panic as { "Error: " <> string.inspect(e) }
  }
}

fn entry(logger: glog.Glog) -> Result(Nil, Dynamic) {
  let secret_key_base = wisp.random_string(64)
  let listeners =
    os.get_env("LISTENERS")
    |> result.unwrap("")
    |> string.split(",")
    |> list.filter(fn(x) { x != "" })
    |> set.from_list
    |> set.to_list
  let redis_host = os.get_env("REDIS_HOST") |> result.unwrap("")
  let redis_port =
    os.get_env("REDIS_PORT")
    |> result.unwrap("")
    |> int.parse
    |> result.unwrap(0)
  let redis_user = os.get_env("REDIS_USER") |> result.unwrap("")
  let redis_password = os.get_env("REDIS_PASSWORD") |> result.unwrap("")

  use ckpt_registry <- result.try(
    registry.start() |> utils.annotate_result("failed to start redis registry"),
  )

  use sup <- result.try(
    supervisor.start_spec(
      supervisor.Spec(
        argument: Nil,
        frequency_period: 30,
        max_frequency: 5,
        init: fn(children) {
          case redis_host, redis_port {
            h, p if h != "" && p != 0 ->
              children
              |> supervisor.add(
                supervisor.worker(fn(_: Nil) {
                  process.sleep(1000)
                  checkpointer.start(
                    logger
                      |> glog.add_field(field.new("module", "checkpointer")),
                    ckpt_registry,
                    redis_host: h,
                    redis_port: p,
                    redis_options: case redis_user, redis_password {
                      "", "" -> []
                      u, "" -> [radish.Auth(u)]
                      u, p -> [radish.AuthWithUsername(u, p)]
                    },
                  )
                }),
              )
            _, _ -> children
          }
        },
      ),
    )
    |> result.map_error(fn(x) {
      dynamic.from(#("failed to start supervisor", x))
    }),
  )

  use m <- result.try(
    manager.start(
      logger |> glog.add_field(field.new("module", "room_manager")),
      ckpt_registry,
    )
    |> utils.annotate_result("failed to start room manager"),
  )

  use _ <- result.try(
    list.try_each(listeners, fn(x) {
      case x {
        "http:" <> port -> {
          use port <- result.try(
            int.parse(port) |> utils.annotate_result("http: invalid port"),
          )

          use _ <- result.try(
            router.create_handler(m, secret_key_base)
            |> mist.new
            |> mist.port(port)
            |> mist.start_http
            |> utils.annotate_result("failed to start http server"),
          )

          Ok(Nil)
        }
        _ -> Error(dynamic.from("invalid listener: " <> x))
      }
    }),
  )

  glog.noticef(logger, "all listeners started: ~s", [
    arg.new(listeners |> string.join(", ")),
  ])

  let sup = process.monitor_process(process.subject_owner(sup))
  let down =
    process.new_selector()
    |> process.selecting_process_down(sup, fn(x) { x })
    |> process.select_forever
  Error(dynamic.from(#("supervisor is down", down)))
}
