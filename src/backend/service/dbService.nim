import std/times
import ../database/dbBackend

proc dbText*(value: DbValue): string =
  if value.kind == dvkNull:
    ""
  else:
    value.s

proc formatUnixTime*(unixTs: int64): string =
  fromUnix(unixTs).format("yyyy-MM-dd HH:mm:ss") & " UTC"
