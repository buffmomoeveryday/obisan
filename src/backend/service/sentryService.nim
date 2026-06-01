import mummy
import json
import jsony
import chronicles
import std/[options, strformat, strutils, times]
import uuid4
import zippy

import ../database/db
import norm/[pool, sqlite]
import lowdb/sqlite
import ../tasks/tasks
import ../utils/webhook
import ../../shared/types/sentry
import ./requestService

const DuplicateWindowSecs = 2'i64

proc parseSentryKeyFromAuth*(auth: string): string =
  const keyPrefix = "sentry_key="
  for part in auth.split(','):
    let piece = part.strip()
    let lower = piece.toLowerAscii()
    let idx = lower.find(keyPrefix)
    if idx >= 0:
      return piece[idx + keyPrefix.len .. ^1].strip().strip(chars={'"', '\''})
  ""

proc extractSentryKey*(request: Request): string =
  result = parseSentryKeyFromAuth(requestHeader(request, "X-Sentry-Auth"))
  if result.len > 0:
    return

  let authorization = requestHeader(request, "Authorization")
  let authLower = authorization.toLowerAscii()
  if authLower.startsWith("sentry "):
    result = parseSentryKeyFromAuth(authorization[7 .. ^1])

proc readNextLine*(buffer: string, startPos: var int): string =
  let endPos = buffer.find('\n', startPos)
  if endPos == -1:
    result = buffer[startPos .. ^1]
    startPos = buffer.len
  else:
    result = buffer[startPos ..< endPos]
    startPos = endPos + 1

proc isGzip*(data: string): bool =
  data.len >= 2 and data[0].char == 31.char and data[1].char == 139.char

proc maybeUncompress*(data: string): string =
  if isGzip(data):
    uncompress(data)
  else:
    data

proc decodeEnvelopeBody*(request: Request, body: string): string =
  let encoding = requestHeader(request, "Content-Encoding").toLowerAscii()
  if "gzip" in encoding or isGzip(body):
    maybeUncompress(body)
  else:
    body

proc readItemPayload*(body: string, pos: var int, itemHeader: ItemHeader): string =
  if itemHeader.length > 0:
    let endPos = pos + itemHeader.length
    if endPos > body.len:
      raise newException(ValueError, "Envelope payload truncated")
    result = body[pos ..< endPos]
    pos = endPos
    if pos < body.len and body[pos] == '\n':
      inc pos
  else:
    result = body.readNextLine(pos)

proc formatStacktrace*(ex: SentryExceptionDetails): string =
  if ex.stacktrace.frames.len == 0:
    return ""

  var lines: seq[string] = @["Traceback (most recent call last):"]
  for frame in ex.stacktrace.frames:
    let file =
      if frame.abs_path.len > 0:
        frame.abs_path
      elif frame.filename.len > 0:
        frame.filename
      else:
        "<unknown>"
    let funcName =
      if frame.function.len > 0:
        frame.function
      else:
        "<unknown>"
    lines.add &"  File \"{file}\", line {frame.lineno}, in {funcName}"
    if frame.context_line.len > 0:
      lines.add "    " & frame.context_line.strip()
  lines.add ex.`type` & ": " & ex.value
  lines.join("\n")

proc extractEventMessage*(eventData: SentryEventPayload): (string, string, string, string) =
  if eventData.exception.values.len > 0:
    let ex = eventData.exception.values[0]
    return (ex.`type`, ex.value, ex.`type` & ": " & ex.value, formatStacktrace(ex))
  if eventData.message.len > 0:
    return ("Message", eventData.message, eventData.message, "")
  ("Unknown", "Unknown error message format", "Unknown error message format", "")

proc nodeString(node: JsonNode, key: string, fallback: string = ""): string =
  if node.kind == JObject and key in node and node[key].kind == JString:
    node[key].getStr()
  else:
    fallback

proc nodeInt(node: JsonNode, key: string, fallback: int = 0): int =
  if node.kind == JObject and key in node and node[key].kind == JInt:
    node[key].getInt()
  else:
    fallback

proc nodeUnixTime(node: JsonNode, key: string): int64 =
  if node.kind == JObject and key in node:
    case node[key].kind
    of JInt:
      return node[key].getInt().int64
    of JFloat:
      return node[key].getFloat().int64
    else:
      discard
  epochTime().int64

proc nodeTimestamp(node: JsonNode, key: string): int64 =
  if node.kind == JObject and key in node:
    case node[key].kind
    of JInt:
      return node[key].getInt().int64
    of JFloat:
      return node[key].getFloat().int64
    of JString:
      try:
        return parseFloat(node[key].getStr()).int64
      except ValueError:
        discard
    else:
      discard
  epochTime().int64

proc newLogEventId(envelopeEventId: string, index: int): string =
  if envelopeEventId.len > 0:
    envelopeEventId & "-log-" & $index
  else:
    ($uuid4()).replace("-", "")

proc newBreadcrumbLogEventId(eventId: string, index: int): string =
  if eventId.len > 0:
    eventId & "-breadcrumb-" & $index
  else:
    ($uuid4()).replace("-", "")

proc hasRecentDuplicate(
  db: DbConn,
  projectId: int64,
  platform, level, errorType, message: string,
  receivedAt: int64
): bool =
  let row = db.getRow(
    sql"""SELECT id FROM SentryEvent
          WHERE project = ?
          AND platform = ?
          AND level = ?
          AND errorType = ?
          AND message = ?
          AND receivedAt >= ?
          LIMIT 1""",
    projectId,
    platform,
    level,
    errorType,
    message,
    receivedAt - DuplicateWindowSecs
  )
  row.isSome

proc logDetails(logNode: JsonNode): string =
  var details = newJObject()
  if logNode.kind == JObject:
    if "trace_id" in logNode:
      details["trace_id"] = logNode["trace_id"]
    if "severity_number" in logNode:
      details["severity_number"] = logNode["severity_number"]
    if "attributes" in logNode:
      details["attributes"] = logNode["attributes"]
  if details.len == 0:
    ""
  else:
    details.pretty()

proc sentryWebhookData(
  eventId, level, platform, errorType, message, stacktrace: string,
  receivedAt: int64
): JsonNode =
  %* {
    "eventId": eventId,
    "level": level,
    "platform": platform,
    "errorType": errorType,
    "message": message,
    "stacktrace": stacktrace,
    "receivedAt": receivedAt
  }

proc saveSentryLog*(
  project: Project,
  projectIdStr: string,
  eventId: string,
  logNode: JsonNode
) =
  let level = logNode.nodeString("level", "info")
  let message = logNode.nodeString("body", logNode.nodeString("message", ""))
  let unixTime = logNode.nodeUnixTime("timestamp")
  var dbRecord = newSentryEvent(
    eventId = eventId,
    project = project,
    platform = "log",
    level = level,
    errorType = "Log",
    message = message,
    stacktrace = logDetails(logNode),
    receivedAt = unixTime
  )

  withDb dbPool:
    if hasRecentDuplicate(db, project.id, "log", level, "Log", message, unixTime):
      return
    db.insert(dbRecord)

  info "Sentry log received",
    project = projectIdStr,
    eventId = eventId,
    level = level,
    message = message

  if project.webhookUrl.len > 0:
    let data = sentryWebhookData(eventId, level, "log", "Log", message, dbRecord.stacktrace, unixTime)
    enqueueWebhook(
      project.webhookUrl,
      "log.created",
      webhookPayload("log.created", $project.id, project.name, data)
    )

proc saveSentryLogs*(
  project: Project,
  projectIdStr: string,
  envelopeEventId: string,
  payload: string
): string =
  let data = parseJson(payload)
  if data.kind != JObject or "items" notin data or data["items"].kind != JArray:
    raise newException(ValueError, "Invalid Sentry log payload")

  var index = 0
  for item in data["items"]:
    let eventId = newLogEventId(envelopeEventId, index)
    if result.len == 0:
      result = eventId
    saveSentryLog(project, projectIdStr, eventId, item)
    inc index

proc saveSentryBreadcrumbLog*(
  project: Project,
  projectIdStr: string,
  eventId: string,
  breadcrumb: SentryBreadcrumb
) =
  let unixTime =
    if breadcrumb.timestamp > 0:
      breadcrumb.timestamp.int64
    else:
      epochTime().int64
  let level =
    if breadcrumb.level.len > 0:
      breadcrumb.level
    else:
      "info"
  let message =
    if breadcrumb.message.len > 0:
      breadcrumb.message
    else:
      breadcrumb.category

  var dbRecord = newSentryEvent(
    eventId = eventId,
    project = project,
    platform = "log",
    level = level,
    errorType = "Log",
    message = message,
    stacktrace = "",
    receivedAt = unixTime
  )

  withDb dbPool:
    if hasRecentDuplicate(db, project.id, "log", level, "Log", message, unixTime):
      return
    db.insert(dbRecord)

  info "Sentry breadcrumb log received",
    project = projectIdStr,
    eventId = eventId,
    level = level,
    category = breadcrumb.category,
    message = message

  if project.webhookUrl.len > 0:
    let data = sentryWebhookData(eventId, level, "log", "Log", message, "", unixTime)
    enqueueWebhook(
      project.webhookUrl,
      "log.created",
      webhookPayload("log.created", $project.id, project.name, data)
    )

proc saveSentryBreadcrumbLogs*(
  project: Project,
  projectIdStr: string,
  eventId: string,
  eventData: SentryEventPayload
) =
  var index = 0
  for breadcrumb in eventData.breadcrumbs.values:
    if breadcrumb.`type` == "log" or breadcrumb.category.len > 0:
      saveSentryBreadcrumbLog(
        project,
        projectIdStr,
        newBreadcrumbLogEventId(eventId, index),
        breadcrumb
      )
    inc index

proc saveSentryBreadcrumbJsonLog*(
  project: Project,
  projectIdStr: string,
  eventId: string,
  breadcrumb: JsonNode
) =
  let unixTime = breadcrumb.nodeTimestamp("timestamp")
  let level = breadcrumb.nodeString("level", "info")
  let message = breadcrumb.nodeString("message", breadcrumb.nodeString("category", ""))
  var details = newJObject()
  if breadcrumb.kind == JObject:
    if "category" in breadcrumb:
      details["category"] = breadcrumb["category"]
    if "type" in breadcrumb:
      details["type"] = breadcrumb["type"]
    if "data" in breadcrumb:
      details["data"] = breadcrumb["data"]

  var dbRecord = newSentryEvent(
    eventId = eventId,
    project = project,
    platform = "log",
    level = level,
    errorType = "Log",
    message = message,
    stacktrace = if details.len > 0: details.pretty() else: "",
    receivedAt = unixTime
  )

  withDb dbPool:
    if hasRecentDuplicate(db, project.id, "log", level, "Log", message, unixTime):
      return
    db.insert(dbRecord)

  info "Sentry breadcrumb log received",
    project = projectIdStr,
    eventId = eventId,
    level = level,
    message = message

  if project.webhookUrl.len > 0:
    let data = sentryWebhookData(eventId, level, "log", "Log", message, dbRecord.stacktrace, unixTime)
    enqueueWebhook(
      project.webhookUrl,
      "log.created",
      webhookPayload("log.created", $project.id, project.name, data)
    )

proc saveSentryBreadcrumbJsonLogs*(
  project: Project,
  projectIdStr: string,
  eventId: string,
  payload: string
) =
  let data = parseJson(payload)
  if data.kind != JObject or "breadcrumbs" notin data:
    return

  let breadcrumbs = data["breadcrumbs"]
  if breadcrumbs.kind != JObject or "values" notin breadcrumbs or breadcrumbs["values"].kind != JArray:
    return

  var index = 0
  for breadcrumb in breadcrumbs["values"]:
    if breadcrumb.kind == JObject:
      let breadcrumbType = breadcrumb.nodeString("type")
      let category = breadcrumb.nodeString("category")
      let message = breadcrumb.nodeString("message")
      if breadcrumbType == "log" or category.len > 0 or message.len > 0:
        saveSentryBreadcrumbJsonLog(
          project,
          projectIdStr,
          newBreadcrumbLogEventId(eventId, index),
          breadcrumb
        )
    inc index

proc formatStacktraceJson(exceptionNode: JsonNode): string =
  if exceptionNode.kind != JObject or "stacktrace" notin exceptionNode:
    return ""
  let stacktrace = exceptionNode["stacktrace"]
  if stacktrace.kind != JObject or "frames" notin stacktrace or stacktrace["frames"].kind != JArray:
    return ""

  var lines: seq[string] = @["Traceback (most recent call last):"]
  for frame in stacktrace["frames"]:
    if frame.kind != JObject:
      continue
    let file =
      if frame.nodeString("abs_path").len > 0:
        frame.nodeString("abs_path")
      elif frame.nodeString("filename").len > 0:
        frame.nodeString("filename")
      else:
        "<unknown>"
    let funcName =
      if frame.nodeString("function").len > 0:
        frame.nodeString("function")
      else:
        "<unknown>"
    let lineNo = frame.nodeInt("lineno")
    lines.add &"  File \"{file}\", line {lineNo}, in {funcName}"
    if frame.nodeString("context_line").len > 0:
      lines.add "    " & frame.nodeString("context_line").strip()
  lines.add exceptionNode.nodeString("type", "Error") & ": " & exceptionNode.nodeString("value")
  lines.join("\n")

proc extractEventJsonMessage(eventNode: JsonNode): (string, string, string, string) =
  if eventNode.kind == JObject and "exception" in eventNode:
    let exceptionBlock = eventNode["exception"]
    if exceptionBlock.kind == JObject and "values" in exceptionBlock and
        exceptionBlock["values"].kind == JArray and exceptionBlock["values"].len > 0:
      let ex = exceptionBlock["values"][0]
      if ex.kind == JObject:
        let exType = ex.nodeString("type", "Exception")
        let exValue = ex.nodeString("value")
        return (exType, exValue, exType & ": " & exValue, formatStacktraceJson(ex))

  let message =
    if eventNode.kind == JObject and "message" in eventNode:
      case eventNode["message"].kind
      of JString:
        eventNode["message"].getStr()
      of JObject:
        eventNode["message"].nodeString("formatted", eventNode["message"].nodeString("message"))
      else:
        ""
    else:
      ""
  if message.len > 0:
    return ("Message", message, message, "")
  ("Unknown", "Unknown error message format", "Unknown error message format", "")

proc saveSentryEventJson*(
  project: Project,
  projectIdStr: string,
  eventId: string,
  payload: string
) =
  let eventNode = parseJson(payload)
  let (errorType, message, displayMessage, stacktrace) = extractEventJsonMessage(eventNode)
  let level = eventNode.nodeString("level")
  let platform = eventNode.nodeString("platform")
  let unixNow = epochTime().int64
  var dbRecord = newSentryEvent(
    eventId = eventId,
    project = project,
    platform = platform,
    level = level,
    errorType = errorType,
    message = message,
    stacktrace = stacktrace,
    receivedAt = unixNow
  )

  var inserted = false
  withDb dbPool:
    if not hasRecentDuplicate(db, project.id, platform, level, errorType, message, unixNow):
      db.insert(dbRecord)
      inserted = true

  saveSentryBreadcrumbJsonLogs(project, projectIdStr, eventId, payload)

  if not inserted:
    info "Duplicate Sentry event skipped",
      project = projectIdStr,
      eventId = eventId,
      level = level,
      platform = platform,
      message = displayMessage
    return

  info "Sentry event received",
    project = projectIdStr,
    eventId = eventId,
    level = level,
    platform = platform,
    message = displayMessage

  if project.ntfyTopic.len > 0:
    let alertTitle = project.name & ": " & errorType
    let notificationBody = "[" & level & "] " & displayMessage
    enqueueNtfy(project.ntfyTopic, notificationBody, alertTitle)

  if project.webhookUrl.len > 0:
    let data = sentryWebhookData(eventId, level, platform, errorType, message, stacktrace, unixNow)
    enqueueWebhook(
      project.webhookUrl,
      "issue.created",
      webhookPayload("issue.created", $project.id, project.name, data)
    )

proc saveSentryEvent*(
  project: Project,
  projectIdStr: string,
  eventId: string,
  eventData: SentryEventPayload
) =
  let (errorType, message, displayMessage, stacktrace) = extractEventMessage(eventData)
  let unixNow = epochTime().int64
  var dbRecord = newSentryEvent(
    eventId = eventId,
    project = project,
    platform = eventData.platform,
    level = eventData.level,
    errorType = errorType,
    message = message,
    stacktrace = stacktrace,
    receivedAt = unixNow
  )

  withDb dbPool:
    db.insert(dbRecord)

  info "Sentry event received",
    project = projectIdStr,
    eventId = eventId,
    level = eventData.level,
    platform = eventData.platform,
    message = displayMessage

  if project.ntfyTopic.len > 0:
    let alertTitle = project.name & ": " & errorType
    let notificationBody = "[" & eventData.level & "] " & displayMessage
    enqueueNtfy(project.ntfyTopic, notificationBody, alertTitle)

  if project.webhookUrl.len > 0:
    let data = sentryWebhookData(eventId, eventData.level, eventData.platform, errorType, message, stacktrace, unixNow)
    enqueueWebhook(
      project.webhookUrl,
      "issue.created",
      webhookPayload("issue.created", $project.id, project.name, data)
    )

proc processEnvelopeBody*(project: Project, projectIdStr: string, body: string): string =
  var pos = 0
  var firstStoredId = ""

  let envHeaderLine = body.readNextLine(pos)
  if envHeaderLine.len == 0:
    raise newException(ValueError, "Missing envelope header")

  let envHeader = envHeaderLine.fromJson(EnvelopeHeader)

  while pos < body.len:
    let itemHeaderLine = body.readNextLine(pos).strip()
    if itemHeaderLine.len == 0:
      continue

    let itemHeader = itemHeaderLine.fromJson(ItemHeader)
    let payloadSlice = maybeUncompress(body.readItemPayload(pos, itemHeader))

    if itemHeader.`type` == "event":
      saveSentryEventJson(project, projectIdStr, envHeader.event_id, payloadSlice)
      if firstStoredId.len == 0:
        firstStoredId = envHeader.event_id
    elif itemHeader.`type` == "transaction":
      discard
    elif itemHeader.`type` == "log":
      let logId = saveSentryLogs(project, projectIdStr, envHeader.event_id, payloadSlice)
      if firstStoredId.len == 0:
        firstStoredId = logId

  if firstStoredId.len > 0:
    firstStoredId
  else:
    envHeader.event_id
