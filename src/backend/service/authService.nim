import mummy
import json
import options
import os
import strutils
import times
import norm/[pool, sqlite]
import std/sha1

import ../database/db
import ../utils/jwtUtils

proc getJwtSecret(): string =
  result = os.getEnv("JWT_SECRET")
  if result == "":
    raise newException(Exception, "JWT_SECRET environment variable not set")

let JWT_SECRET = getJwtSecret()

proc generateToken*(userId: int, email: string): string =
  let payload = %* {
    "userId": userId,
    "email": email,
    "exp": (epochTime().int + 3600 * 24).BiggestInt
  }
  result = encodeJwt(payload, JWT_SECRET)

proc verifyToken*(token: string): bool =
  try:
    let payload = decodeJwt(token, JWT_SECRET)
    let exp = payload["exp"].getBiggestInt()
    result = epochTime().int < exp
  except CatchableError:
    result = false

proc getUserIdFromToken*(token: string): int =
  try:
    let payload = decodeJwt(token, JWT_SECRET)
    result = payload["userId"].getBiggestInt().int
  except CatchableError:
    result = -1

proc hashPassword*(password: string): string =
  result = $secureHash(password & JWT_SECRET)

proc verifyPassword*(password, hash: string): bool =
  result = hashPassword(password) == hash

proc verifyJwtToken(token: string): Option[int] =
  try:
    let payload = decodeJwt(token, JWT_SECRET)
    let exp = payload["exp"].getBiggestInt()
    if epochTime().int >= exp:
      return none[int]()
    let uid = payload["userId"].getBiggestInt().int
    return some(uid)
  except CatchableError:
    return none[int]()

proc getUser*(request: Request): Option[User] =
  let authHeader =
    if "Authorization" in request.headers: request.headers["Authorization"] else: ""

  if not authHeader.startsWith("Bearer "):
    return none[User]()

  let token = authHeader[7..^1]
  let maybeUserId = verifyJwtToken(token)
  if maybeUserId.isNone:
    return none[User]()

  var dbUser = User()
  withDb dbPool:
    db.select(dbUser, "id = ?", maybeUserId.get)

  if dbUser == nil:
    return none[User]()

  return some(dbUser)

proc getUserFromToken*(token: string): Option[User] =
  let maybeUserId = verifyJwtToken(token)
  if maybeUserId.isNone:
    return none[User]()

  var dbUser = User()
  withDb dbPool:
    db.select(dbUser, "id = ?", maybeUserId.get)

  if dbUser == nil:
    return none[User]()

  some(dbUser)
