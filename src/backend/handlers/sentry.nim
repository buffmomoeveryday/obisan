import mummy, json, chronicles
import uuid4
import options
import strutils
import norm/[pool, sqlite]

import ../database/db
import ../tasks/tasks
import ../utils/http
import ../utils/ntfy
import ../service/[authService, dbService, eventService, metricsService, projectService, queryService, requestService, sentryService]

proc listProjectEvents*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  let search = sanitizeEventSearch(request.queryParams.getOrDefault("search", ""))
  let page = parseQueryInt(request.queryParams.getOrDefault("page", "1"), 1, 1, 1_000_000)
  let pageSize = parseQueryInt(
    request.queryParams.getOrDefault("pageSize", $DefaultEventsPageSize),
    DefaultEventsPageSize,
    1,
    MaxEventsPageSize
  )
  let offset = (page - 1) * pageSize

  try:
    var parts: seq[string] = @[]
    var total = 0
    var totalPages = 0
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
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
          eventSummarySearchSql,
          projectDbId,
          pattern,
          pattern,
          pattern,
          pattern,
          pattern,
          pattern,
          pageSize,
          offset
        ):
          parts.add eventSummaryJson(row).pretty

    request.respond(200, newJsonHeaders(), (%* {
      "events": parseJson("[" & parts.join(",") & "]"),
      "search": search,
      "pagination": {
        "page": page,
        "pageSize": pageSize,
        "total": total,
        "totalPages": totalPages
      }
    }).pretty)
  except CatchableError as e:
    error "Failed to list project events", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to list project events"}).pretty)

proc getProjectEvent*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let eventId = request.pathParams.getOrDefault("eventId", "")
  if projectId.len == 0 or eventId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id and event id required"}).pretty)
    return

  try:
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return

      let row = db.getRow(eventDetailSql, projectInfo.get.dbId, eventId)
      if row.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Issue not found"}).pretty)
        return

      request.respond(200, newJsonHeaders(), eventDetailJson(row.get).pretty)
  except CatchableError as e:
    error "Failed to load project event", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to load issue"}).pretty)

proc listProjectLogs*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  let search = sanitizeEventSearch(request.queryParams.getOrDefault("search", ""))
  let page = parseQueryInt(request.queryParams.getOrDefault("page", "1"), 1, 1, 1_000_000)
  let pageSize = parseQueryInt(
    request.queryParams.getOrDefault("pageSize", $DefaultEventsPageSize),
    DefaultEventsPageSize,
    1,
    MaxEventsPageSize
  )
  let offset = (page - 1) * pageSize

  try:
    var parts: seq[string] = @[]
    var total = 0
    var totalPages = 0
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
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
          logSummarySearchSql,
          projectDbId,
          pattern,
          pattern,
          pattern,
          pattern,
          pattern,
          pageSize,
          offset
        ):
          parts.add eventSummaryJson(row).pretty

    request.respond(200, newJsonHeaders(), (%* {
      "logs": parseJson("[" & parts.join(",") & "]"),
      "search": search,
      "pagination": {
        "page": page,
        "pageSize": pageSize,
        "total": total,
        "totalPages": totalPages
      }
    }).pretty)
  except CatchableError as e:
    error "Failed to list project logs", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to list project logs"}).pretty)

proc listProjectMetrics*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  let search = sanitizeEventSearch(request.queryParams.getOrDefault("search", ""))
  let page = parseQueryInt(request.queryParams.getOrDefault("page", "1"), 1, 1, 1_000_000)
  let pageSize = parseQueryInt(
    request.queryParams.getOrDefault("pageSize", $DefaultMetricsPageSize),
    DefaultMetricsPageSize,
    1,
    MaxMetricsPageSize
  )
  let offset = (page - 1) * pageSize

  try:
    var parts: seq[string] = @[]
    var total = 0
    var totalPages = 0
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return

      let projectDbId = projectInfo.get.dbId
      total = countProjectMetrics(db, projectDbId, search)
      totalPages =
        if total == 0:
          0
        else:
          (total + pageSize - 1) div pageSize

      if search.len == 0:
        for row in db.rows(metricSummarySql, projectDbId, pageSize, offset):
          parts.add metricSummaryJson(row).pretty
      else:
        let pattern = likePattern(search)
        for row in db.rows(
          metricSummarySearchSql,
          projectDbId,
          pattern,
          pattern,
          pattern,
          pattern,
          pageSize,
          offset
        ):
          parts.add metricSummaryJson(row).pretty

    request.respond(200, newJsonHeaders(), (%* {
      "metrics": parseJson("[" & parts.join(",") & "]"),
      "search": search,
      "pagination": {
        "page": page,
        "pageSize": pageSize,
        "total": total,
        "totalPages": totalPages
      }
    }).pretty)
  except CatchableError as e:
    error "Failed to list project metrics", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to list project metrics"}).pretty)

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

proc ingestProjectMetrics*(request: Request) =
  let projectIdStr = request.pathParams.getOrDefault("id", "")
  if projectIdStr.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  var projectRecord = none[Project]()
  try:
    withDb dbPool:
      projectRecord = selectProjectByPathId(db, projectIdStr)
  except CatchableError as e:
    error "Database error checking project existence", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Database validation error"}).pretty)
    return

  if projectRecord.isNone:
    request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
    return

  let project = projectRecord.get
  let metricKey = extractMetricIngestKey(request)
  if project.publicKey.len > 0 and metricKey != project.publicKey:
    warn "Rejected metrics: Invalid public key", project = projectIdStr
    request.respond(403, newJsonHeaders(), (%* {"error": "Invalid credentials"}).pretty)
    return

  try:
    let accepted = parseMetricsPayload(request.body).len
    enqueueProjectMetrics(project.id.int, request.body)
    info "Queued project metrics", project = projectIdStr, count = accepted
    request.respond(202, newJsonHeaders(), (%* {"queued": accepted}).pretty)
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%* {"error": e.msg}).pretty)
  except CatchableError as e:
    error "Failed to queue project metrics", errorMsg = e.msg, project = projectIdStr
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to queue project metrics"}).pretty)

proc deleteProjectEvents*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  var eventIds: seq[string] = @[]
  try:
    eventIds = parseEventIds(request.body)
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%* {"error": e.msg}).pretty)
    return
  except CatchableError:
    request.respond(400, newJsonHeaders(), (%* {"error": "Invalid request body"}).pretty)
    return

  if eventIds.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "No event ids provided"}).pretty)
    return

  try:
    var deleted = 0
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return

      deleted = deleteProjectEventRows(db, projectInfo.get.dbId, eventIds)

    info "Deleted project events", project = projectId, count = deleted
    request.respond(200, newJsonHeaders(), (%* {"deleted": deleted}).pretty)
  except CatchableError as e:
    error "Failed to delete project events", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to delete events"}).pretty)

proc deleteProjectEvent*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let eventId = request.pathParams.getOrDefault("eventId", "")
  if projectId.len == 0 or eventId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id and event id required"}).pretty)
    return

  try:
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return

      let affected = deleteProjectEventRow(db, projectInfo.get.dbId, eventId)
      if affected == 0:
        request.respond(404, newJsonHeaders(), (%* {"error": "Issue not found"}).pretty)
        return

    info "Deleted project event", project = projectId, eventId = eventId
    request.respond(200, newJsonHeaders(), (%* {"deleted": 1}).pretty)
  except CatchableError as e:
    error "Failed to delete project event", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to delete issue"}).pretty)

proc listProjects*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  try:
    var parts: seq[string] = @[]
    withDb dbPool:
      for row in db.rows(
        sql"""SELECT p.id, p.name, p.publicKey, p.ntfyTopic, COUNT(e.id) AS issueCount
              FROM Project p
              LEFT JOIN SentryEvent e ON e.project = p.id AND e.platform != 'log'
              WHERE p.owner = ?
              GROUP BY p.id
              ORDER BY p.id DESC""",
        user.get.id
      ):
        let dbId = row[0].i
        let name = dbText(row[1])
        let publicKey = ensurePublicKey(db, name, dbText(row[2]))
        let ntfyTopic = ensureNtfyTopic(db, dbId.int, name, dbText(row[3]))
        parts.add projectListItemJson(request, dbId, name, publicKey, ntfyTopic, row[4].i).pretty

    request.respond(200, newJsonHeaders(), "{\"projects\":[" & parts.join(",") & "]}")
  except CatchableError as e:
    error "Failed to list projects", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to list projects"}).pretty)

proc generateProjectId*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  var projectName = "Untitled project"
  if request.body.len > 0:
    try:
      let body = parseJson(request.body)
      if "name" in body:
        projectName = normalizeProjectName(body["name"].getStr())
    except CatchableError:
      request.respond(400, newJsonHeaders(), (%* {"error": "Invalid request body"}).pretty)
      return

  let publicKey = ($uuid4()).replace("-", "")
  try:
    var projectRecord = newProject(projectName, publicKey, "", user.get)
    withDb dbPool:
      db.insert(projectRecord)
      projectRecord.ntfyTopic = generateNtfyTopic(projectRecord.id.int, projectName)
      db.update(projectRecord)
    info "Generated and stored new project", projectId = projectRecord.id, name = projectName
    request.respond(200, newJsonHeaders(), projectToJson(request, projectRecord).pretty)
  except CatchableError as e:
    error "Failed to store generated project ID", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), "Internal server error saving project")

proc updateProject*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  if request.body.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Request body required"}).pretty)
    return

  var projectName: string
  try:
    let body = parseJson(request.body)
    if "name" notin body:
      request.respond(400, newJsonHeaders(), (%* {"error": "Project name required"}).pretty)
      return
    projectName = normalizeProjectName(body["name"].getStr())
  except CatchableError:
    request.respond(400, newJsonHeaders(), (%* {"error": "Invalid request body"}).pretty)
    return

  try:
    var projectRecord: Project
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return

      let dbId = projectInfo.get.dbId
      db.exec(sql"UPDATE Project SET name = ? WHERE id = ?", projectName, dbId)
      let ntfyTopic = generateNtfyTopic(dbId, projectName)
      db.exec(sql"UPDATE Project SET ntfyTopic = ? WHERE id = ?", ntfyTopic, dbId)

      let row = db.getRow(
        sql"SELECT id, name, publicKey, ntfyTopic FROM Project WHERE id = ?",
        dbId
      )
      projectRecord = Project(
        name: dbText(row.get[1]),
        publicKey: dbText(row.get[2]),
        ntfyTopic: dbText(row.get[3]),
        owner: user.get
      )
      projectRecord.id = row.get[0].i

    request.respond(200, newJsonHeaders(), projectToJson(request, projectRecord).pretty)
  except CatchableError as e:
    error "Failed to update project", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to update project"}).pretty)

proc handleSentryEnvelope*(request: Request) =
  let projectIdStr = request.pathParams.getOrDefault("id", "unknown")
  var projectRecord = none[Project]()

  try:
    withDb dbPool:
      projectRecord = selectProjectByPathId(db, projectIdStr)
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
    let eventId = processEnvelopeBody(project, projectIdStr, envelope)
    let responseJson = "{\"id\":\"" & eventId & "\"}"
    request.respond(200, newJsonHeaders(), responseJson)

  except CatchableError as e:
    error "Failed to handle envelope", errorMsg = e.msg, project = projectIdStr
    request.respond(400, newJsonHeaders(), "Error storing log payload")
