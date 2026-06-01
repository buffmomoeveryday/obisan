import std/[dynlib, strutils]

type RuntimeDependency* = object
  label*: string
  installHint*: string
  libraryNames*: seq[string]
  symbol*: string

proc findLoadableLibrary(dep: RuntimeDependency): bool =
  for name in dep.libraryNames:
    let handle = loadLib(name)
    if handle != nil:
      let hasSymbol = dep.symbol.len == 0 or symAddr(handle, cstring(dep.symbol)) != nil
      unloadLib(handle)
      if hasSymbol:
        return true
  false

proc dependencyMessage(dep: RuntimeDependency): string =
  "Missing runtime dependency: " & dep.label & ". Install it with: " &
    dep.installHint & ". Tried: " & dep.libraryNames.join(", ")

proc requireRuntimeDependencies*() =
  let deps =
    when defined(windows):
      @[
        RuntimeDependency(
          label: "SQLite",
          installHint: "install sqlite3.dll and make it available on PATH",
          libraryNames: @["sqlite3.dll", "sqlite3_64.dll", "sqlite3_32.dll"],
          symbol: "sqlite3_open"
        ),
        RuntimeDependency(
          label: "LMDB",
          installHint: "install liblmdb.dll and make it available on PATH",
          libraryNames: @["liblmdb.dll"],
          symbol: "mdb_env_create"
        )
      ]
    elif defined(macosx):
      @[
        RuntimeDependency(
          label: "SQLite",
          installHint: "brew install sqlite",
          libraryNames: @["libsqlite3.dylib", "libsqlite3.0.dylib"],
          symbol: "sqlite3_open"
        ),
        RuntimeDependency(
          label: "LMDB",
          installHint: "brew install lmdb",
          libraryNames: @["liblmdb.dylib"],
          symbol: "mdb_env_create"
        )
      ]
    else:
      @[
        RuntimeDependency(
          label: "SQLite",
          installHint: "sudo apt install libsqlite3-0",
          libraryNames: @["libsqlite3.so.0", "libsqlite3.so"],
          symbol: "sqlite3_open"
        ),
        RuntimeDependency(
          label: "LMDB",
          installHint: "sudo apt install liblmdb0",
          libraryNames: @["liblmdb.so.0", "liblmdb.so", "liblmdb.so.0.0.0"],
          symbol: "mdb_env_create"
        )
      ]

  var missing: seq[string] = @[]
  for dep in deps:
    if not findLoadableLibrary(dep):
      missing.add dependencyMessage(dep)

  if missing.len > 0:
    raise newException(Exception, missing.join("\n"))
