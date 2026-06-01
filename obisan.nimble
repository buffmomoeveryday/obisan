# Package

version       = "0.1.0"
author        = "Siddhartha Khanal"
description   = "A new awesome nimble package"
license       = "MIT"
skipDirs      = @["src"]


# Dependencies
requires "nim >= 2.0.8"

requires "cligen >= 1.9.6"
requires "jsony >= 1.1.6"
requires "chronicles >= 0.12.0"
requires "norm >= 2.8.7"
requires "mummy >= 0.4.7"
requires "zippy >= 0.10.9"
requires "uuid4"
requires "quickjwt >= 0.2.1"
requires "https://github.com/buffmomoeveryday/quee.git"

# frontend
requires "karax >= 0.10.0"
requires "https://github.com/nitely/nim-kxrouter.git"


task build_backend, "Builds the backend production binary":
  mkDir("bin")
  exec "nim c -d:release -d:ssl --threads:on --outdir:bin src/backend/obisan.nim"


task build_frontend, "Builds the frontend production binary":
  mkDir("bin")
  exec "nim js -d:release --outdir:bin src/frontend/app.nim"


task prod, "Builds everything":
  exec "nimble build_frontend"
  exec "nimble build_backend"
