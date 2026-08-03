import mummy
import json
import jsony
import chronicles
import strutils
import options

import ../database/db
import ../utils/http
import ../service/authService
from ../../shared/types/users import LoginRequest, RegisterRequest

# helpers
proc normalizeProfileName(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    raise newException(ValueError, "Name required")
  if result.len > 80:
    result = result[0 ..< 80]

proc normalizeProfileEmail(raw: string): string =
  result = raw.strip().toLowerAscii()
  if result.len == 0:
    raise newException(ValueError, "Email required")
  if result.len > 320:
    raise newException(ValueError, "Email too long")
  if result.find('@') < 1:
    raise newException(ValueError, "Valid email required")

proc normalizeProfilePassword(raw: string): string =
  result = raw
  if result.len == 0:
    return
  if result.len < 8:
    raise newException(ValueError, "New password must be at least 8 characters")
  if result.len > 256:
    raise newException(ValueError, "New password too long")

# handlers
proc getSetupStatus*(request: Request) =
  try:
    var user: Option[User]
    withDb dbPool:
      user = findAnyUser(db)
    request.respond(200, newJsonHeaders(), (%*{"needsSetup": user.isNone}).pretty)
  except CatchableError as e:
    error "Setup status failed", error = e.msg
    request.respond(500, newJsonHeaders(), (%*{"error": "Setup status failed"}).pretty)

proc registerUser*(request: Request) =
  try:
    let body = request.body
    let data = body.fromJson(RegisterRequest)

    var user = newUser(data.name, data.email, hashPassword(data.password))
    withDb dbPool:
      db.insert(user)

    info "User registered", email = data.email
    let token = generateToken(user.id, data.email)
    request.respond(201, newJsonHeaders(), (%*{"token": token}).pretty)
  except CatchableError as e:
    error "Registration failed", error = e.msg
    request.respond(500, newJsonHeaders(), (%*{"error": "Registration failed"}).pretty)

proc loginUser*(request: Request) =
  try:
    let body = request.body
    let data = body.fromJson(LoginRequest)

    var user: Option[User]
    withDb dbPool:
      user = findUserByEmail(db, data.email)

    if user.isSome and verifyPassword(data.password, user.get.passwordHash):
      let token = generateToken(user.get.id, data.email)
      info "User logged in", email = data.email
      request.respond(200, newJsonHeaders(), (%*{"token": token}).pretty)
    else:
      request.respond(
        401, newJsonHeaders(), (%*{"error": "Invalid credentials"}).pretty
      )
  except CatchableError as e:
    error "Login failed", error = e.msg
    request.respond(500, newJsonHeaders(), (%*{"error": "Login failed"}).pretty)

proc getProfile*(request: Request) =
  let authHeader =
    if "Authorization" in request.headers:
      request.headers["Authorization"]
    else:
      ""
  if authHeader.startsWith("Bearer "):
    let token = authHeader[7 ..^ 1]
    let userId = getUserIdFromToken(token)

    if userId > 0:
      var user: Option[User]
      withDb dbPool:
        user = findUserById(db, userId)

      if user.isSome:
        request.respond(
          200,
          newJsonHeaders(),
          (%*{"id": user.get.id, "name": user.get.name, "email": user.get.email}).pretty,
        )
        return

  request.respond(401, newJsonHeaders(), (%*{"error": "Unauthorized"}).pretty)

proc updateProfile*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  try:
    let body = parseJson(request.body)
    if body.kind != JObject:
      request.respond(
        400, newJsonHeaders(), (%*{"error": "Invalid request body"}).pretty
      )
      return

    let nextName =
      if "name" in body:
        normalizeProfileName(body["name"].getStr())
      else:
        user.get.name
    let nextEmail =
      if "email" in body:
        normalizeProfileEmail(body["email"].getStr())
      else:
        user.get.email
    let currentPassword =
      if "currentPassword" in body:
        body["currentPassword"].getStr()
      else:
        ""
    let nextPassword =
      if "newPassword" in body:
        normalizeProfilePassword(body["newPassword"].getStr())
      else:
        ""

    if (nextEmail != user.get.email or nextPassword.len > 0) and
        not verifyPassword(currentPassword, user.get.passwordHash):
      request.respond(
        400,
        newJsonHeaders(),
        (%*{"error": "Current password is required to change email or password"}).pretty,
      )
      return

    withDb dbPool:
      if nextEmail != user.get.email:
        let existing = db.getRow(
          dbSql"SELECT id FROM users WHERE lower(email) = lower(?) AND id != ?",
          nextEmail,
          user.get.id,
        )
        if existing.isSome:
          request.respond(
            409, newJsonHeaders(), (%*{"error": "Email is already in use"}).pretty
          )
          return

      if nextPassword.len > 0:
        db.exec(
          dbSql"UPDATE users SET name = ?, email = ?, passwordHash = ? WHERE id = ?",
          nextName,
          nextEmail,
          hashPassword(nextPassword),
          user.get.id,
        )
      else:
        db.exec(
          dbSql"UPDATE users SET name = ?, email = ? WHERE id = ?",
          nextName,
          nextEmail,
          user.get.id,
        )

    let token = generateToken(user.get.id, nextEmail)
    request.respond(
      200,
      newJsonHeaders(),
      (%*{"id": user.get.id, "name": nextName, "email": nextEmail, "token": token}).pretty,
    )
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%*{"error": e.msg}).pretty)
  except CatchableError as e:
    error "Profile update failed", error = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Profile update failed"}).pretty
    )
