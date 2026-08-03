import mummy
import json
import chronicles
import options

import ../database/db
import ../utils/http
import ../service/authService
import ../service/appSettingsService

proc getSettings*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  try:
    withDb dbPool:
      let settings = loadAppSettings(db)
      request.respond(200, newJsonHeaders(), settingsToJson(settings).pretty)
  except CatchableError as e:
    error "Failed to load app settings", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to load settings"}).pretty)

proc updateSettings*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  if request.body.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Request body required"}).pretty)
    return

  try:
    let body = parseJson(request.body)
    if body.kind != JObject:
      request.respond(400, newJsonHeaders(), (%* {"error": "Invalid request body"}).pretty)
      return

    withDb dbPool:
      let settings = updateAppSettings(db, body)
      request.respond(200, newJsonHeaders(), settingsToJson(settings).pretty)
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%* {"error": e.msg}).pretty)
  except CatchableError as e:
    error "Failed to update app settings", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to update settings"}).pretty)
