import mummy, mummy/routers
import jwt,jsony, chronicles
import options

import ../../shared/types/users
import ../../backend/database/db
import ./http

proc verifyJwtToken(token: string): Option[int] =
  try:
    let payload = decode(token, "your-secret-key-change-in-production")
    let exp = payload["exp"].getInt(BiggestInt)
    if epochTime().int >= exp:
      return none[int]()
    let uid = payload["userId"].getInt(BiggestInt).int
    return some(uid)
  except CatchableError:
    return none[int]()


proc getUser*(request: Request): Option[User] =
  let authHeader = request.headers.getOrDefault("Authorization", "")

  if not authHeader.startsWith("Bearer "):
    return none[User]()

  let token = authHeader[7..^1]
  let maybeUserId = verifyJwtToken(token)
  if maybeUserId.isNone:
    return none[User]()

  var dbUser = User()
  withDb dbPool:
    databaseConnection.select(dbUser, "id = ?", maybeUserId.get)

  if dbUser == nil:
    return none[User]()

  return some(dbUser)
