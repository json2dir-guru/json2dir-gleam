//// Thin declarations of the Erlang `file` / `erlang` functions json2dir needs.

import gleam/dynamic.{type Dynamic}
import json2dir/status.{type Status}

/// The atoms in the `type` field of a `#file_info{}` record.
pub type FileType {
  Directory
  Regular
  Symlink
  Device
  Other
}

/// Atoms used as file:open/2 modes.
pub type Mode {
  Write
  Exclusive
  Raw
  Binary
}

pub type Fd

/// A POSIX error atom; only `enoent` is matched, any other atom falls through.
pub type Reason {
  Enoent
  OtherReason
}

/// lstat: returns a `#file_info{}` record, never follows a symlink.
@external(erlang, "file", "read_link_info")
pub fn read_link_info(path: String) -> Result(Dynamic, Reason)

/// Element 3 of `#file_info{}` is `type`.
pub fn file_type(info: Dynamic) -> FileType {
  element(3, info)
}

/// Element 8 of `#file_info{}` is `mode`.
pub fn file_mode(info: Dynamic) -> Int {
  element(8, info)
}

@external(erlang, "erlang", "element")
fn element(index: Int, tuple: Dynamic) -> a

@external(erlang, "file", "make_dir")
pub fn make_dir(path: String) -> Status

@external(erlang, "file", "make_symlink")
pub fn make_symlink(target: String, path: String) -> Status

@external(erlang, "file", "delete")
pub fn delete(path: String) -> Status

@external(erlang, "file", "open")
pub fn open(path: String, modes: List(Mode)) -> Result(Fd, Dynamic)

@external(erlang, "file", "write")
pub fn write(fd: Fd, bytes: BitArray) -> Status

@external(erlang, "file", "close")
pub fn close(fd: Fd) -> Status

@external(erlang, "file", "change_mode")
pub fn change_mode(path: String, mode: Int) -> Status

@external(erlang, "file", "read_file")
pub fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "init", "get_plain_arguments")
pub fn arguments() -> List(Dynamic)

@external(erlang, "erlang", "halt")
pub fn halt(code: Int) -> Nil
