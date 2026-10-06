//// Erlang's `ok | {error, Reason}` return shape: Gleam constructors compile to these atoms/tuples.

import gleam/dynamic.{type Dynamic}

pub type Status {
  Ok
  Error(reason: Dynamic)
}
