import mummy
import mummy/routers
import jwt
import jsony
import chronicles
import times

import ../database/db
import ../utils/http
import std/sha1
import ../../shared/types/users

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
  result = encode(payload, JWT_SECRET)

proc verifyToken*(token: string): bool =
  try:
    let payload = decode(token, JWT_SECRET)
    let exp = payload["exp"].getInt(BiggestInt)
    result = epochTime().int < exp
  except CatchableError:
    result = false

proc getUserIdFromToken*(token: string): int =
  try:
    let payload = decode(token, JWT_SECRET)
    result = payload["userId"].getInt(BiggestInt).int
  except CatchableError:
    result = -1


# handlers
proc registerUser*(request: Request) =
  try:
    let body = request.body
    let data = body.fromJson(RegisterRequest)

    var user = newUser(data.name, data.email, hashPassword(data.password))

    withDb dbPool:
      databaseConnection.insert(user)

    info "User registered", email = data.email
    let token = generateToken(user.id, data.email)
    request.respond(201, newJsonHeaders(), %* {"token": token}.pretty)
  except CatchableError as e:
    error "Registration failed", error = e.msg
    request.respond(500, newJsonHeaders(), %* {"error": "Registration failed"}.pretty)

proc loginUser*(request: Request) =
  try:
    let body = request.body
    let data = body.fromJson(LoginRequest)

    var user = User()
    withDb dbPool:
      databaseConnection.select(user, "email = ?", data.email)

    if user != nil and verifyPassword(data.password, user.passwordHash):
      let token = generateToken(user.id, data.email)
      info "User logged in", email = data.email
      request.respond(200, newJsonHeaders(), %* {"token": token}.pretty)
    else:
      request.respond(401, newJsonHeaders(), %* {"error": "Invalid credentials"}.pretty)
  except NotFoundError:
    request.respond(401, newJsonHeaders(), %* {"error": "Invalid credentials"}.pretty)
  except CatchableError as e:
    error "Login failed", error = e.msg
    request.respond(500, newJsonHeaders(), %* {"error": "Login failed"}.pretty)

proc hashPassword*(password: string): string =
  result = sha1Hex(password & JWT_SECRET)

proc verifyPassword*(password, hash: string): bool =
  result = hashPassword(password) == hash

proc getProfile*(request: Request) =
  let authHeader = request.headers.getOrDefault("Authorization", "")
  if authHeader.startsWith("Bearer "):
    let token = authHeader[7..^1]
    let userId = getUserIdFromToken(token)

    if userId > 0:
      var user = User()
      withDb dbPool:
        databaseConnection.select(user, "id = ?", userId)

      if user != nil:
        request.respond(200, newJsonHeaders(), %* {
          "id": user.id,
          "name": user.name,
          "email": user.email
        }.pretty)
        return

  request.respond(401, newJsonHeaders(), %* {"error": "Unauthorized"}.pretty)
