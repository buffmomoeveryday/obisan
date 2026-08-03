import mummy
import json
import options
import os
import strutils
import times
import std/sha1

import ../database/db
import ./dbService
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

proc userFromRow(row: seq[DbValue]): User =
  result = User(
    name: dbText(row[0]),
    email: dbText(row[1]),
    passwordHash: dbText(row[2])
  )
  result.id = row[3].i.int

proc findAnyUser*(db: DbConn): Option[User] =
  let row = db.getRow(
    dbSql"SELECT name, email, passwordHash, id FROM users WHERE id > ? LIMIT 1",
    0
  )
  if row.isSome:
    some(userFromRow(row.get))
  else:
    none[User]()

proc findUserById*(db: DbConn, userId: int): Option[User] =
  let row = db.getRow(
    dbSql"SELECT name, email, passwordHash, id FROM users WHERE id = ? LIMIT 1",
    userId
  )
  if row.isSome:
    some(userFromRow(row.get))
  else:
    none[User]()

proc findUserByEmail*(db: DbConn, email: string): Option[User] =
  let row = db.getRow(
    dbSql"SELECT name, email, passwordHash, id FROM users WHERE email = ? LIMIT 1",
    email
  )
  if row.isSome:
    some(userFromRow(row.get))
  else:
    none[User]()

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

  var dbUser: Option[User]
  withDb dbPool:
    dbUser = findUserById(db, maybeUserId.get)

  if dbUser.isNone:
    return none[User]()

  return dbUser

proc getUserFromToken*(token: string): Option[User] =
  let maybeUserId = verifyJwtToken(token)
  if maybeUserId.isNone:
    return none[User]()

  var dbUser: Option[User]
  withDb dbPool:
    dbUser = findUserById(db, maybeUserId.get)

  if dbUser.isNone:
    return none[User]()

  dbUser
