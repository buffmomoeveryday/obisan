import mummy, jsony, chronicles
import uuid4

import ../database/db
import ../utils/http
import ../utils/[authUtils]

import ../../shared/types/[sentry,users]

import std/[strutils, times]

proc readNextLine(buffer: string, startPos: var int): string =
  let endPos = buffer.find('\n', startPos)
  if endPos == -1:
    result = buffer[startPos .. ^1]
    startPos = buffer.len
  else:
    result = buffer[startPos ..< endPos]
    startPos = endPos + 1

proc generateProjectId*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), %{"message": "Unauthorized"})
    return

  let u1 = $uuid4()
  let stringU1 = u1.replace("-", "")
  try:
    var projectRecord = newProject(stringU1,user)
    withDB dbPool:
      databaseConnection.insert(projectRecord)
    info "Generated and stored new project", projectId = stringU1
    request.respond(200, newJsonHeaders(), stringU1)
  except CatchableError as e:
    error "Failed to store generated project ID", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), "Internal server error saving project")

proc handleSentryEnvelope*(request: Request) =
  let projectIdStr = request.pathParams.getOrDefault("id", "unknown")

  try:
    var projectRecord = newProject(projectIdStr)
    withDb dbPool:
      databaseConnection.select(projectRecord, "name = ?", projectIdStr)
  except NotFoundError:
    warn "Rejected envelope: Project ID does not exist", project = projectIdStr
    request.respond(404, newJsonHeaders(), "{\"error\":\"Project not found\"}")
    return
  except CatchableError as e:
    error "Database error checking project existence", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), "Database validation error")
    return

  try:
    let body = request.body
    if body.len == 0:
      request.respond(400, newHttpHeaders(), "Empty body")
      return

    var pos = 0

    let envHeaderLine = body.readNextLine(pos)
    if envHeaderLine.len == 0: return
    let envHeader = envHeaderLine.fromJson(EnvelopeHeader)

    while pos < body.len:
      let itemHeaderLine = body.readNextLine(pos).strip()
      if itemHeaderLine.len == 0: continue

      let itemHeader = itemHeaderLine.fromJson(ItemHeader)
      let payloadSlice = body.readNextLine(pos)

      if itemHeader.`type` == "event" or itemHeader.`type` == "transaction":
        let eventData = payloadSlice.fromJson(SentryEventPayload)

        var errorMsg = "Unknown error message format"
        if eventData.exception.values.len > 0:
          let ex = eventData.exception.values[0]
          errorMsg = ex.`type` & ": " & ex.value

          let unixNow = epochTime().int64
          var dbRecord = newSentryEvent(
            eventId = envHeader.event_id,
            project = projectRecord,
            platform = eventData.platform,
            level = eventData.level,
            errorType = ex.`type`,
            message = ex.value,
            receivedAt = unixNow
          )

          withDb dbPool:
            databaseConnection.insert(dbRecord)

        warn "Captured & Saved Sentry Exception!",
          id = envHeader.event_id,
          project = projectIdStr,
          msg = errorMsg

    let responseJson = "{\"id\":\"" & envHeader.event_id & "\"}"
    request.respond(200, newJsonHeaders(), responseJson)

  except CatchableError as e:
    error "Failed to handle envelope", errorMsg = e.msg
    request.respond(400, newJsonHeaders(), "Error storing log payload")
