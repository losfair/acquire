import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub type RegistryRequest(a, b) {
  Lookup(key: a, ret: Subject(Result(b, Nil)))
  Register(key: a, value: b)
}

pub fn start() -> actor.StartResult(RegistryRequest(a, b)) {
  actor.start_spec(actor.Spec(
    init: init,
    init_timeout: 5000,
    loop: handle_message,
  ))
}

fn init() -> actor.InitResult(Dict(a, b), RegistryRequest(a, b)) {
  actor.Ready(state: dict.new(), selector: process.new_selector())
}

fn handle_message(
  m: RegistryRequest(a, b),
  st: Dict(a, b),
) -> actor.Next(RegistryRequest(a, b), Dict(a, b)) {
  case m {
    Lookup(key, ret) -> {
      process.send(ret, dict.get(st, key))
      actor.continue(st)
    }
    Register(key, value) -> {
      dict.insert(st, key, value) |> actor.continue
    }
  }
}
