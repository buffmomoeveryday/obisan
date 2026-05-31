# Package

version       = "0.1.0"
author        = "Siddhartha Khanal"
description   = "A new awesome nimble package"
license       = "MIT"


# Dependencies

requires "nim >= 2.2.10"

requires "cligen >= 1.9.6"
requires "jsony >= 1.1.6"
requires "chronicles >= 0.12.0"
requires "norm >= 2.8.7"
requires "https://github.com/gokr/mummyx.git"
requires "https://github.com/buffmomoeveryday/quee.git"
requires "uuid4"
requires "jwt >= 0.3"

# frontend
requires "karax >= 0.10.0"
requires "https://github.com/nitely/nim-kxrouter.git"




task build_backend, "Builds the backend production binary":
  mkDir("bin")
  exec "nim c -d:release --outdir:bin src/backend/obisan.nim"

task devBackend, "Builds the backend with debug symbols":
  exec "nimble path obsisan"
  exec "nim c -d:debug --outdir:bin src/backend/obisan.nim"


task build_frontend, "Builds the frontend production binary":
  exec "nimble path obsisan"
  exec "nim js -d:release --outdir:bin src/frontend/app.nim"


task prod, "Builds everything":
  exec "nimble build_backend"
  exec "nimble build_frontend"
