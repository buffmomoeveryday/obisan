import mummy, json, chronicles
import uuid4
import options
import strutils
import times

import ../database/db
import ../tasks/tasks
import ../utils/http
import ../service/notification/ntfy
import ../service/notification/webhook
import
  ../service/[
    appSettingsService, authService, dbService, eventService, metricsService,
    projectService, queryService, requestService, sentryService,
  ]


# helpers
const DefaultMetricRange* = "1h"

proc normalizeMetricRange(raw: string): string =
    case raw.strip().toLowerAscii()
    of "1minute", "1min", "1m", "minute":
      "1m"
    of "5minute", "5minutes", "5min", "5m":
      "5m"
    of "10minute", "10minutes", "10min", "10m":
      "10m"
    of "hour", "1hour", "1h", "60m":
      "1h"
    of "24hour", "24hours", "24h", "1day", "1d", "day":
      "24h"
    of "week", "1week", "7day", "7days", "7d":
      "7d"
    of "14day", "14days", "14d":
      "14d"
    of "1month", "month", "30day", "30days", "30d":
      "30d"
    of "all":
      "all"
    else:
      DefaultMetricRange

proc metricRangeSeconds(metricRange: string): int64 =
  case metricRange
  of "1m":
    60
  of "5m":
    5 * 60
  of "10m":
    10 * 60
  of "1h":
    60 * 60
  of "24h":
    24 * 60 * 60
  of "7d":
    7 * 24 * 60 * 60
  of "14d":
    14 * 24 * 60 * 60
  of "30d":
    30 * 24 * 60 * 60
  else:
    0

proc metricRangeSinceUnix(metricRange: string): int64 =
  let seconds = metricRangeSeconds(metricRange)
  if seconds <= 0:
    0
  else:
    getTime().toUnix() - seconds

proc parseQueryInt64(value: string, defaultValue: int64): int64 =
  if value.len == 0:
    return defaultValue
  try:
    parseBiggestInt(value).int64
  except ValueError:
    defaultValue

proc extractMetricIngestKey(request: Request): string =
  result = request.queryParams.getOrDefault("key", "")
  if result.len > 0:
    return result
  result = requestHeader(request, "X-Obisan-Key")
  if result.len > 0:
    return result

  let authorization = requestHeader(request, "Authorization")
  if authorization.toLowerAscii().startsWith("bearer "):
    result = authorization[7 .. ^1].strip()
    if result.len > 0:
      return result

  return extractSentryKey(request)

# handlers
proc listProjectEvents*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%*{"error": "Project id required"}).pretty)
    return

  let search = sanitizeEventSearch(request.queryParams.getOrDefault("search", ""))
  let page =
    parseQueryInt(request.queryParams.getOrDefault("page", "1"), 1, 1, 1_000_000)
  let pageSize = parseQueryInt(
    request.queryParams.getOrDefault("pageSize", $DefaultEventsPageSize),
    DefaultEventsPageSize,
    1,
    MaxEventsPageSize,
  )
  let offset = (page - 1) * pageSize

  try:
    var parts: seq[string] = @[]
    var total = 0
    var totalPages = 0
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(
          404, newJsonHeaders(), (%*{"error": "Project not found"}).pretty
        )
        return

      let projectDbId = projectInfo.get.dbId
      total = countProjectEvents(db, projectDbId, search)
      totalPages =
        if total == 0:
          0
        else:
          (total + pageSize - 1) div pageSize

      if search.len == 0:
        for row in db.rows(eventSummarySql, projectDbId, pageSize, offset):
          parts.add eventSummaryJson(row).pretty
      else:
        let pattern = likePattern(search)
        for row in db.rows(
          eventSummarySearchSql, projectDbId, pattern, pattern, pattern, pattern,
          pattern, pattern, pageSize, offset,
        ):
          parts.add eventSummaryJson(row).pretty

    request.respond(
      200,
      newJsonHeaders(),
      (
        %*{
          "events": parseJson("[" & parts.join(",") & "]"),
          "search": search,
          "pagination": {
            "page": page, "pageSize": pageSize, "total": total, "totalPages": totalPages
          },
        }
      ).pretty,
    )
  except CatchableError as e:
    error "Failed to list project events", errorMsg = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Failed to list project events"}).pretty
    )

proc getProjectEvent*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let eventId = request.pathParams.getOrDefault("eventId", "")
  if projectId.len == 0 or eventId.len == 0:
    request.respond(
      400, newJsonHeaders(), (%*{"error": "Project id and event id required"}).pretty
    )
    return

  try:
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(
          404, newJsonHeaders(), (%*{"error": "Project not found"}).pretty
        )
        return

      let row = db.getRow(eventDetailSql, projectInfo.get.dbId, eventId)
      if row.isNone:
        request.respond(404, newJsonHeaders(), (%*{"error": "Issue not found"}).pretty)
        return

      request.respond(200, newJsonHeaders(), eventDetailJson(row.get).pretty)
  except CatchableError as e:
    error "Failed to load project event", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%*{"error": "Failed to load issue"}).pretty)

proc listProjectLogs*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%*{"error": "Project id required"}).pretty)
    return

  let search = sanitizeEventSearch(request.queryParams.getOrDefault("search", ""))
  let page =
    parseQueryInt(request.queryParams.getOrDefault("page", "1"), 1, 1, 1_000_000)
  let pageSize = parseQueryInt(
    request.queryParams.getOrDefault("pageSize", $DefaultEventsPageSize),
    DefaultEventsPageSize,
    1,
    MaxEventsPageSize,
  )
  let offset = (page - 1) * pageSize

  try:
    var parts: seq[string] = @[]
    var total = 0
    var totalPages = 0
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(
          404, newJsonHeaders(), (%*{"error": "Project not found"}).pretty
        )
        return

      let projectDbId = projectInfo.get.dbId
      total = countProjectLogs(db, projectDbId, search)
      totalPages =
        if total == 0:
          0
        else:
          (total + pageSize - 1) div pageSize

      if search.len == 0:
        for row in db.rows(logSummarySql, projectDbId, pageSize, offset):
          parts.add eventSummaryJson(row).pretty
      else:
        let pattern = likePattern(search)
        for row in db.rows(
          logSummarySearchSql, projectDbId, pattern, pattern, pattern, pattern, pattern,
          pageSize, offset,
        ):
          parts.add eventSummaryJson(row).pretty

    request.respond(
      200,
      newJsonHeaders(),
      (
        %*{
          "logs": parseJson("[" & parts.join(",") & "]"),
          "search": search,
          "pagination": {
            "page": page, "pageSize": pageSize, "total": total, "totalPages": totalPages
          },
        }
      ).pretty,
    )
  except CatchableError as e:
    error "Failed to list project logs", errorMsg = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Failed to list project logs"}).pretty
    )

proc listProjectMetrics*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%*{"error": "Project id required"}).pretty)
    return

  let search = sanitizeEventSearch(request.queryParams.getOrDefault("search", ""))
  let metricRange = normalizeMetricRange(request.queryParams.getOrDefault("range", DefaultMetricRange))
  let untilUnix = getTime().toUnix()
  let rangeSeconds = metricRangeSeconds(metricRange)
  let sinceUnix = metricRangeSinceUnix(metricRange)
  let page =
    parseQueryInt(request.queryParams.getOrDefault("page", "1"), 1, 1, 1_000_000)
  let pageSize = parseQueryInt(
    request.queryParams.getOrDefault("pageSize", $DefaultMetricsPageSize),
    DefaultMetricsPageSize,
    1,
    MaxMetricsPageSize,
  )
  let offset = (page - 1) * pageSize

  try:
    var parts: seq[string] = @[]
    var total = 0
    var totalPages = 0

    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), "{\"error\":\"Project not found\"}")
        return

      let projectDbId = projectInfo.get.dbId
      total = countProjectMetrics(db, projectDbId, search, sinceUnix)
      totalPages =
        if total == 0:
          0
        else:
          (total + pageSize - 1) div pageSize

      if search.len == 0 and untilUnix > 0 and sinceUnix > 0:
        for row in db.rows(metricSummaryWindowSql, projectDbId, sinceUnix, untilUnix, pageSize, offset):
          parts.add metricSummaryJsonText(row)
      elif search.len == 0 and sinceUnix <= 0:
        for row in db.rows(metricSummarySql, projectDbId, pageSize, offset):
          parts.add metricSummaryJsonText(row)
      elif search.len == 0:
        for row in db.rows(metricSummarySinceSql, projectDbId, sinceUnix, pageSize, offset):
          parts.add metricSummaryJsonText(row)
      elif sinceUnix <= 0:
        let pattern = likePattern(search)
        for row in db.rows(
          metricSummarySearchSql, projectDbId, pattern, pattern, pattern, pattern,
          pageSize, offset,
        ):
          parts.add metricSummaryJsonText(row)
      else:
        let pattern = likePattern(search)
        for row in db.rows(
          metricSummarySearchSinceSql, projectDbId, sinceUnix, pattern, pattern, pattern, pattern,
          pageSize, offset,
        ):
          parts.add metricSummaryJsonText(row)

    let responseJson =
      "{\"metrics\":[" & parts.join(",") &
      "],\"search\":" & escapeJson(search) &
      ",\"range\":" & escapeJson(metricRange) &
      ",\"pagination\":{\"page\":" & $page &
      ",\"pageSize\":" & $pageSize &
      ",\"total\":" & $total &
      ",\"totalPages\":" & $totalPages &
      "}}"

    request.respond(200, newJsonHeaders(), responseJson)
  except CatchableError as e:
    error "Failed to list project metrics", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), "{\"error\":\"Failed to list project metrics\"}")


proc ingestProjectMetrics*(request: Request) =
  let projectIdStr = request.pathParams.getOrDefault("id", "")
  if projectIdStr.len == 0:
    request.respond(400, newJsonHeaders(), (%*{"error": "Project id required"}).pretty)
    return

  var projectRecord = none[Project]()
  try:
    withDb dbPool:
      projectRecord = selectCachedProjectByPathId(db, projectIdStr)
  except CatchableError as e:
    error "Database error checking project existence", errorMsg = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Database validation error"}).pretty
    )
    return

  if projectRecord.isNone:
    request.respond(404, newJsonHeaders(), (%*{"error": "Project not found"}).pretty)
    return

  let project = projectRecord.get
  let metricKey = extractMetricIngestKey(request)
  if project.publicKey.len > 0 and metricKey != project.publicKey:
    warn "Rejected metrics: Invalid public key", project = projectIdStr
    request.respond(403, newJsonHeaders(), (%*{"error": "Invalid credentials"}).pretty)
    return

  try:
    let metrics = parseMetricsPayload(request.body)
    let accepted = metrics.len
    enqueueProjectMetrics(project.id.int, metricsToQueuePayload(metrics))
    info "``Queued project metrics``", project = projectIdStr, count = accepted
    request.respond(202, newJsonHeaders(), (%*{"queued": accepted}).pretty)
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%*{"error": e.msg}).pretty)
  except CatchableError as e:
    error "Failed to queue project metrics", errorMsg = e.msg, project = projectIdStr
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Failed to queue project metrics"}).pretty
    )

proc deleteProjectEvents*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%*{"error": "Project id required"}).pretty)
    return

  var eventIds: seq[string] = @[]
  try:
    eventIds = parseEventIds(request.body)
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%*{"error": e.msg}).pretty)
    return
  except CatchableError:
    request.respond(400, newJsonHeaders(), (%*{"error": "Invalid request body"}).pretty)
    return

  if eventIds.len == 0:
    request.respond(
      400, newJsonHeaders(), (%*{"error": "No event ids provided"}).pretty
    )
    return

  try:
    var deleted = 0
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(
          404, newJsonHeaders(), (%*{"error": "Project not found"}).pretty
        )
        return

      deleted = deleteProjectEventRows(db, projectInfo.get.dbId, eventIds)

    info "Deleted project events", project = projectId, count = deleted
    request.respond(200, newJsonHeaders(), (%*{"deleted": deleted}).pretty)
  except CatchableError as e:
    error "Failed to delete project events", errorMsg = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Failed to delete events"}).pretty
    )

proc deleteProjectEvent*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let eventId = request.pathParams.getOrDefault("eventId", "")
  if projectId.len == 0 or eventId.len == 0:
    request.respond(
      400, newJsonHeaders(), (%*{"error": "Project id and event id required"}).pretty
    )
    return

  try:
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(
          404, newJsonHeaders(), (%*{"error": "Project not found"}).pretty
        )
        return

      let affected = deleteProjectEventRow(db, projectInfo.get.dbId, eventId)
      if affected == 0:
        request.respond(404, newJsonHeaders(), (%*{"error": "Issue not found"}).pretty)
        return

    info "Deleted project event", project = projectId, eventId = eventId
    request.respond(200, newJsonHeaders(), (%*{"deleted": 1}).pretty)
  except CatchableError as e:
    error "Failed to delete project event", errorMsg = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Failed to delete issue"}).pretty
    )

proc listProjects*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  try:
    var parts: seq[string] = @[]
    withDb dbPool:
      let settings = loadAppSettings(db)
      for row in db.rows(
        dbSql"""SELECT p.id, p.name, p.publicKey, p.ntfyTopic, p.webhookUrl, p.notificationConfigs, COUNT(e.id) AS issueCount
              FROM projects p
              LEFT JOIN user_project_access a ON a.project = p.id AND a.memberUser = ?
              LEFT JOIN sentry_events e ON e.project = p.id AND e.platform != 'log'
              WHERE p.owner = ? OR a.id IS NOT NULL
              GROUP BY p.id
              ORDER BY p.id DESC""",
        user.get.id,
        user.get.id,
      ):
        let dbId = row[0].i
        let name = dbText(row[1])
        let publicKey = ensurePublicKey(db, name, dbText(row[2]))
        let ntfyTopic = ensureNtfyTopic(db, dbId.int, name, dbText(row[3]))
        parts.add projectListItemJson(
          request,
          dbId,
          name,
          publicKey,
          ntfyTopic,
          dbText(row[4]),
          dbText(row[5]),
          row[6].i,
          settings.ntfyServerUrl,
        ).pretty

    request.respond(200, newJsonHeaders(), "{\"projects\":[" & parts.join(",") & "]}")
  except CatchableError as e:
    error "Failed to list projects", errorMsg = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Failed to list projects"}).pretty
    )

proc generateProjectId*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  var projectName = ""
  if request.body.len > 0:
    try:
      let body = parseJson(request.body)
      if "name" in body:
        projectName = body["name"].getStr()
    except CatchableError:
      request.respond(
        400, newJsonHeaders(), (%*{"error": "Invalid request body"}).pretty
      )
      return
  projectName = projectNameWithRandomSuffix(projectName)

  let publicKey = ($uuid4()).replace("-", "")
  try:
    var projectRecord = newProject(projectName, publicKey, "", user.get)
    withDb dbPool:
      db.insert(projectRecord)
      projectRecord.ntfyTopic = generateNtfyTopic(projectRecord.id.int, projectName)
      db.update(projectRecord)
    info "Generated and stored new project",
      projectId = projectRecord.id, name = projectName
    request.respond(200, newJsonHeaders(), projectToJson(request, projectRecord).pretty)
  except CatchableError as e:
    error "Failed to store generated project ID", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), "Internal server error saving project")

proc updateProject*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%*{"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%*{"error": "Project id required"}).pretty)
    return

  if request.body.len == 0:
    request.respond(
      400, newJsonHeaders(), (%*{"error": "Request body required"}).pretty
    )
    return

  var projectName = ""
  var webhookUrl = ""
  var notificationConfigs = ""
  var hasName = false
  var hasWebhookUrl = false
  var hasEmailSettings = false
  try:
    let body = parseJson(request.body)
    if "name" in body:
      hasName = true
      projectName = normalizeProjectName(body["name"].getStr())
    if "webhookUrl" in body:
      hasWebhookUrl = true
      webhookUrl = normalizeWebhookUrl(body["webhookUrl"].getStr())
    if "emailEnabled" in body or "emailToAddrs" in body:
      hasEmailSettings = true
      let currentEmailEnabled =
        if "emailEnabled" in body:
          body["emailEnabled"].getBool()
        else:
          false
      let currentEmailToAddrs =
        if "emailToAddrs" in body:
          normalizeProjectEmailRecipients(body["emailToAddrs"].getStr())
        else:
          ""
      notificationConfigs = projectNotificationConfigsJson(currentEmailEnabled, currentEmailToAddrs)
    if not hasName and not hasWebhookUrl and not hasEmailSettings:
      request.respond(
        400, newJsonHeaders(), (%*{"error": "No project fields provided"}).pretty
      )
      return
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%*{"error": e.msg}).pretty)
    return
  except CatchableError:
    request.respond(400, newJsonHeaders(), (%*{"error": "Invalid request body"}).pretty)
    return

  try:
    var projectRecord: Project
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(
          404, newJsonHeaders(), (%*{"error": "Project not found"}).pretty
        )
        return

      let dbId = projectInfo.get.dbId
      if hasName:
        db.exec(dbSql"UPDATE projects SET name = ? WHERE id = ?", projectName, dbId)
        let ntfyTopic = generateNtfyTopic(dbId, projectName)
        db.exec(dbSql"UPDATE projects SET ntfyTopic = ? WHERE id = ?", ntfyTopic, dbId)
      if hasWebhookUrl:
        db.exec(dbSql"UPDATE projects SET webhookUrl = ? WHERE id = ?", webhookUrl, dbId)
      if hasEmailSettings:
        db.exec(dbSql"UPDATE projects SET notificationConfigs = ? WHERE id = ?", notificationConfigs, dbId)

      let row = db.getRow(
        dbSql"SELECT id, name, publicKey, ntfyTopic, webhookUrl, notificationConfigs FROM projects WHERE id = ?",
        dbId,
      )
      projectRecord = Project(
        name: dbText(row.get[1]),
        publicKey: dbText(row.get[2]),
        ntfyTopic: dbText(row.get[3]),
        webhookUrl: dbText(row.get[4]),
        notificationConfigs: dbText(row.get[5]),
        owner: user.get,
      )
      projectRecord.id = row.get[0].i

      invalidateProjectCache($dbId)
      invalidateProjectCache(projectInfo.get.name)
      invalidateProjectCache(projectRecord.name)

    request.respond(200, newJsonHeaders(), projectToJson(request, projectRecord).pretty)
  except CatchableError as e:
    error "Failed to update project", errorMsg = e.msg
    request.respond(
      500, newJsonHeaders(), (%*{"error": "Failed to update project"}).pretty
    )

proc handleSentryEnvelope*(request: Request) =
  let projectIdStr = request.pathParams.getOrDefault("id", "unknown")
  var projectRecord = none[Project]()

  try:
    withDb dbPool:
      projectRecord = selectCachedProjectByPathId(db, projectIdStr)
  except CatchableError as e:
    error "Database error checking project existence", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), "Database validation error")
    return

  if projectRecord.isNone:
    warn "Rejected envelope: Project ID does not exist", project = projectIdStr
    request.respond(404, newJsonHeaders(), "{\"error\":\"Project not found\"}")
    return

  let project = projectRecord.get

  if project.publicKey.len > 0:
    let sentryKey = extractSentryKey(request)
    if sentryKey != project.publicKey:
      warn "Rejected envelope: Invalid public key", project = projectIdStr
      request.respond(403, newJsonHeaders(), "{\"error\":\"Invalid credentials\"}")
      return

  try:
    if request.body.len == 0:
      request.respond(400, emptyHttpHeaders(), "Empty body")
      return

    let envelope = decodeEnvelopeBody(request, request.body)
    let eventId = queuedEnvelopeResponseId(envelope)
    if not tryEnqueueSentryEnvelope(project, projectIdStr, envelope):
      var headers = newJsonHeaders()
      headers["Retry-After"] = "1"
      request.respond(
        503,
        headers,
        "{\"error\":\"Sentry ingestion queue is full\"}"
      )
      return

    let responseJson = "{\"id\":\"" & eventId & "\"}"
    request.respond(202, newJsonHeaders(), responseJson)
  except CatchableError as e:
    error "Failed to handle envelope", errorMsg = e.msg, project = projectIdStr
    request.respond(400, newJsonHeaders(), "Error storing log payload")
