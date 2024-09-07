import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/otp/actor
import gleam/result

pub opaque type Watch(a) {
  Watch(tx: Subject(Req(a)))
}

type Req(a) {
  Wait(until: fn(a) -> Bool, ret: Subject(a))
  Modify(a)
  Close(ret: Subject(Nil))
}

type Waiter(a) {
  Waiter(until: fn(a) -> Bool, ret: Subject(a))
}

pub fn new(initial: a) -> Result(Watch(a), actor.StartError) {
  actor.start(#(initial, []), loop) |> result.map(Watch)
}

pub fn close(sem: Watch(a)) {
  process.call(sem.tx, Close(_), 5000)
}

pub fn wait(sem: Watch(a), until: fn(a) -> Bool) -> a {
  let subject = process.new_subject()
  wait_ext(sem, until, subject)
  let mon = process.monitor_process(process.subject_owner(subject))
  let event =
    process.new_selector()
    |> process.selecting(subject, Ok)
    |> process.selecting_process_down(mon, Error)
    |> process.select_forever()
  process.demonitor_process(mon)
  case event {
    Ok(x) -> x
    Error(_) -> panic as "watch/wait: process down"
  }
}

pub fn wait_ext(sem: Watch(a), until: fn(a) -> Bool, subject: Subject(a)) {
  process.send(sem.tx, Wait(until, subject))
}

pub fn pid(sem: Watch(a)) -> process.Pid {
  process.subject_owner(sem.tx)
}

pub fn modify(sem: Watch(a), x: a) {
  process.send(sem.tx, Modify(x))
}

fn loop(
  req: Req(a),
  st: #(a, List(Waiter(a))),
) -> actor.Next(Req(a), #(a, List(Waiter(a)))) {
  let #(latest, wq) = st
  case req {
    Wait(until, ret) -> {
      case until(latest) {
        True -> {
          process.send(ret, latest)
          actor.continue(#(latest, wq))
        }
        False ->
          actor.continue(
            #(latest, [
              Waiter(until, ret),
              ..wq
              |> list.filter(fn(x) {
                process.is_alive(process.subject_owner(x.ret))
              })
            ]),
          )
      }
    }
    Modify(latest) -> {
      let wq =
        wq
        |> list.filter(fn(x) {
          case x.until(latest) {
            True -> {
              process.send(x.ret, latest)
              False
            }
            False -> process.is_alive(process.subject_owner(x.ret))
          }
        })
      actor.continue(#(latest, wq))
    }
    Close(ret) -> {
      process.send(ret, Nil)
      actor.Stop(process.Normal)
    }
  }
}
