import mummy
import json
import jsony
import chronicles
import strutils
import norm/[pool, sqlite]

import ../database/db
import ../utils/http
import ../service/authService
from ../../shared/types/users import LoginRequest, RegisterRequest

proc getSetupStatus*(request: Request) =
  var user = User()
  try:
    withDb dbPool:
      db.select(user, "id > ?", 0)
    request.respond(200, newJsonHeaders(), (%* {"needsSetup": false}).pretty)
  except NotFoundError:
    request.respond(200, newJsonHeaders(), (%* {"needsSetup": true}).pretty)
  except CatchableError as e:
    error "Setup status failed", error = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Setup status failed"}).pretty)

proc registerUser*(request: Request) =
  try:
    let body = request.body
    let data = body.fromJson(RegisterRequest)

    var user = newUser(data.name, data.email, hashPassword(data.password))

    withDb dbPool:
      db.insert(user)

    info "User registered", email = data.email
    let token = generateToken(user.id, data.email)
    request.respond(201, newJsonHeaders(), (%* {"token": token}).pretty)
  except CatchableError as e:
    error "Registration failed", error = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Registration failed"}).pretty)

proc loginUser*(request: Request) =
  try:
    let body = request.body
    let data = body.fromJson(LoginRequest)

    var user = User()
    withDb dbPool:
      db.select(user, "email = ?", data.email)

    if user != nil and verifyPassword(data.password, user.passwordHash):
      let token = generateToken(user.id, data.email)
      info "User logged in", email = data.email
      request.respond(200, newJsonHeaders(), (%* {"token": token}).pretty)
    else:
      request.respond(401, newJsonHeaders(), (%* {"error": "Invalid credentials"}).pretty)
  except NotFoundError:
    request.respond(401, newJsonHeaders(), (%* {"error": "Invalid credentials"}).pretty)
  except CatchableError as e:
    error "Login failed", error = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Login failed"}).pretty)

proc getProfile*(request: Request) =
  let authHeader =
    if "Authorization" in request.headers: request.headers["Authorization"] else: ""
  if authHeader.startsWith("Bearer "):
    let token = authHeader[7..^1]
    let userId = getUserIdFromToken(token)

    if userId > 0:
      var user = User()
      withDb dbPool:
        db.select(user, "id = ?", userId)

      if user != nil:
        request.respond(200, newJsonHeaders(), (%* {
          "id": user.id,
          "name": user.name,
          "email": user.email
        }).pretty)
        return

  request.respond(401, newJsonHeaders(), (%* {"error": "Unauthorized"}).pretty)
