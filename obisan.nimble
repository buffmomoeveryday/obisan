# Package
import os, strutils

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
requires "https://github.com/buffmomoeveryday/quee.git >= 0.0.1"
requires "malebolgia >= 1.3.2"

# frontend
requires "karax >= 0.10.0"
requires "https://github.com/nitely/nim-kxrouter.git"


task build_backend, "Builds the backend production binary":
  mkDir("bin")
  exec "sed -i 's/listenBacklogLen = 128/listenBacklogLen = 4096/' $(nimble path mummy 2>/dev/null | head -1)/mummy.nim"
  exec "nim c --mm:arc -d:release -d:ssl --threads:on --nimcache:bin/nimcache-sqlite --out:bin/obisan src/backend/obisan.nim"

task build_frontend, "Builds the frontend production binary":
  mkDir("bin")
  exec "nim js -d:release --outdir:bin src/frontend/app.nim"


task prod, "Builds everything":
  exec "nimble build_frontend"
  exec "nimble build_backend"

requires "smtp >= 0.1.0"
