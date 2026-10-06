//// json2dir: create the directory tree a JSON document describes, in the current directory.
//// Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).

import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import json2dir/fs
import json2dir/json.{type Json, JArray, JBool, JNull, JNumber, JObject, JString}
import json2dir/status

pub fn main() -> Nil {
  case fs.arguments() {
    [] ->
      case run() {
        Ok(Nil) -> fs.halt(0)
        Error(message) -> {
          io.println_error("json2dir: " <> message)
          fs.halt(1)
        }
      }
    _ -> {
      io.println_error("usage: json2dir < document.json")
      fs.halt(2)
    }
  }
}

fn run() -> Result(Nil, String) {
  use input <- result.try(
    fs.read_file("/dev/stdin")
    |> result.map_error(fn(e) { "cannot read stdin: " <> string.inspect(e) }),
  )
  use document <- result.try(
    json.parse(input)
    |> result.map_error(fn(e) { "input is not valid JSON: " <> e }),
  )
  case document {
    JObject(_) -> {
      // Section 6: validate the whole document before touching the file system.
      use tree <- result.try(validate(document, "."))
      apply(".", tree)
    }
    _ -> Error("the root of the document must be an object")
  }
}

/// A validated entry. Duplicate member names keep the last value.
type Entry {
  Dir(members: List(#(String, Entry)))
  File(content: String, executable: Bool)
  Link(target: String)
}

fn validate(value: Json, where: String) -> Result(Entry, String) {
  case value {
    JString(s) -> Ok(File(s, False))
    JArray([JString("link"), JString(target)]) ->
      case string.contains(target, "\u{0}") {
        True -> Error(where <> ": a link target cannot contain NUL")
        False -> Ok(Link(target))
      }
    JArray([JString("script"), JString(content)]) -> Ok(File(content, True))
    JArray([JString(kind), JString(_)]) ->
      Error(where <> ": unknown array kind " <> string.inspect(kind))
    JArray(_) ->
      Error(
        where
        <> ": an array must be [\"link\", target] or [\"script\", content]",
      )
    JObject(members) -> {
      use entries <- result.try(
        list.try_map(members, fn(member) {
          let #(name, child) = member
          let path = case where {
            "." -> name
            _ -> where <> "/" <> name
          }
          use _ <- result.try(check_name(name, path))
          use entry <- result.try(validate(child, path))
          Ok(#(name, entry))
        }),
      )
      // Last occurrence wins; process in ascending byte order of names.
      let entries =
        dict.from_list(entries)
        |> dict.to_list
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      Ok(Dir(entries))
    }
    JNumber -> Error(where <> ": number values are not allowed")
    JBool -> Error(where <> ": boolean values are not allowed")
    JNull -> Error(where <> ": null values are not allowed")
  }
}

fn check_name(name: String, where: String) -> Result(Nil, String) {
  case
    name == ""
    || name == "."
    || name == ".."
    || string.contains(name, "/")
    || string.contains(name, "\u{0}")
  {
    True -> Error(where <> ": invalid name " <> string.inspect(name))
    False -> Ok(Nil)
  }
}

fn check(s: status.Status, path: String) -> Result(Nil, String) {
  case s {
    status.Ok -> Ok(Nil)
    status.Error(reason) -> Error(path <> ": " <> string.inspect(reason))
  }
}

/// lstat; `Ok(Error(Nil))` means the entry does not exist.
fn lstat(path: String) -> Result(Result(fs.FileType, Nil), String) {
  case fs.read_link_info(path) {
    Ok(info) -> Ok(Ok(fs.file_type(info)))
    Error(fs.Enoent) -> Ok(Error(Nil))
    Error(reason) -> Error(path <> ": " <> string.inspect(reason))
  }
}

/// Sections 5.2-5.4: remove an existing non-directory (a symlink itself, never its target);
/// a directory in the way is an error.
fn clear(path: String) -> Result(Nil, String) {
  use existing <- result.try(lstat(path))
  case existing {
    Error(Nil) -> Ok(Nil)
    Ok(fs.Directory) -> Error(path <> ": a directory is in the way")
    Ok(_) -> check(fs.delete(path), path)
  }
}

fn write_file(
  path: String,
  content: String,
  executable: Bool,
) -> Result(Nil, String) {
  // exclusive = O_CREAT | O_EXCL, created with mode 0666 & ~umask.
  use fd <- result.try(
    fs.open(path, [fs.Write, fs.Exclusive, fs.Raw, fs.Binary])
    |> result.map_error(fn(e) { path <> ": " <> string.inspect(e) }),
  )
  let written = check(fs.write(fd, bit_array.from_string(content)), path)
  use _ <- result.try(written)
  use _ <- result.try(check(fs.close(fd), path))
  case executable {
    False -> Ok(Nil)
    True ->
      case fs.read_link_info(path) {
        Ok(info) ->
          check(
            fs.change_mode(path, int.bitwise_or(fs.file_mode(info), 0o111)),
            path,
          )
        Error(e) -> Error(path <> ": " <> string.inspect(e))
      }
  }
}

fn apply(dir: String, entry: Entry) -> Result(Nil, String) {
  case entry {
    Dir(members) ->
      list.try_each(members, fn(member) {
        let #(name, child) = member
        let path = dir <> "/" <> name
        case child {
          File(content, executable) -> {
            use _ <- result.try(clear(path))
            write_file(path, content, executable)
          }
          Link(target) -> {
            use _ <- result.try(clear(path))
            check(fs.make_symlink(target, path), path)
          }
          Dir(_) -> {
            use existing <- result.try(lstat(path))
            use _ <- result.try(case existing {
              Ok(fs.Directory) -> Ok(Nil)
              Error(Nil) -> check(fs.make_dir(path), path)
              Ok(_) -> {
                use _ <- result.try(check(fs.delete(path), path))
                check(fs.make_dir(path), path)
              }
            })
            apply(path, child)
          }
        }
      })
    _ -> Ok(Nil)
  }
}
