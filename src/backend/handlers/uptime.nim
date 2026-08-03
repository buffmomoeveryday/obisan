import mummy
import json
import chronicles
import strutils
import options

import ../database/db
import ../utils/http
import ../tasks/tasks
import ../service/[authService, projectService, queryService, uptimeService, uptimeStore]

proc listProjectUptimeMonitors*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  if projectId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project id required"}).pretty)
    return

  try:
    var projectDbId = ""
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return
      projectDbId = $projectInfo.get.dbId

    let monitors = listMonitors(projectDbId)
    var parts: seq[string] = @[]
    for item in monitors:
      parts.add item.pretty

    request.respond(200, newJsonHeaders(), (%* {
      "monitors": parseJson("[" & parts.join(",") & "]")
    }).pretty)
  except CatchableError as e:
    error "Failed to list uptime monitors", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to list uptime monitors"}).pretty)

proc createProjectUptimeMonitor*(request: Request) =
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

  var monitorUrl, monitorName: string
  var timeoutMs, retryCount, intervalSecs: int
  var enabled = true

  try:
    let body = parseJson(request.body)
    if "url" notin body:
      request.respond(400, newJsonHeaders(), (%* {"error": "URL required"}).pretty)
      return
    monitorUrl = validateMonitorUrl(body["url"].getStr())
    monitorName = normalizeMonitorName(
      if "name" in body: body["name"].getStr() else: "Primary"
    )
    timeoutMs = clampInt(
      if "timeoutMs" in body: body["timeoutMs"].getInt() else: 0,
      DefaultTimeoutMs, MinTimeoutMs, MaxTimeoutMs
    )
    retryCount = clampInt(
      if "retryCount" in body: body["retryCount"].getInt() else: -1,
      DefaultRetryCount, MinRetryCount, MaxRetryCount
    )
    intervalSecs = clampInt(
      if "intervalSecs" in body: body["intervalSecs"].getInt() else: 0,
      DefaultIntervalSecs, MinIntervalSecs, MaxIntervalSecs
    )
    if "enabled" in body:
      enabled = body["enabled"].getBool()
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%* {"error": e.msg}).pretty)
    return
  except CatchableError:
    request.respond(400, newJsonHeaders(), (%* {"error": "Invalid request body"}).pretty)
    return

  try:
    var projectDbId = ""
    var ntfyTopic = ""
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id.int)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return
      projectDbId = $projectInfo.get.dbId
      let project = selectProjectByPathId(db, projectId)
      if project.isSome:
        ntfyTopic = project.get.ntfyTopic

    let monitor = createMonitor(
      projectDbId,
      monitorName,
      monitorUrl,
      ntfyTopic,
      timeoutMs,
      retryCount,
      intervalSecs,
      enabled
    )
    if enabled:
      enqueueUptimeMonitor(monitor["id"].getStr(), intervalSecs)

    request.respond(201, newJsonHeaders(), monitor.pretty)
  except CatchableError as e:
    error "Failed to create uptime monitor", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to create monitor"}).pretty)

proc updateProjectUptimeMonitor*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let monitorId = request.pathParams.getOrDefault("monitorId", "")
  if projectId.len == 0 or monitorId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project and monitor id required"}).pretty)
    return

  if request.body.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Request body required"}).pretty)
    return

  var monitorUrl, monitorName: string
  var timeoutMs, retryCount, intervalSecs: int
  var enabled = true
  var hasName, hasUrl, hasTimeout, hasRetry, hasInterval, hasEnabled: bool

  try:
    let body = parseJson(request.body)
    if "name" in body:
      hasName = true
      monitorName = normalizeMonitorName(body["name"].getStr())
    if "url" in body:
      hasUrl = true
      monitorUrl = validateMonitorUrl(body["url"].getStr())
    if "timeoutMs" in body:
      hasTimeout = true
      timeoutMs = clampInt(body["timeoutMs"].getInt(), DefaultTimeoutMs, MinTimeoutMs, MaxTimeoutMs)
    if "retryCount" in body:
      hasRetry = true
      retryCount = clampInt(body["retryCount"].getInt(), DefaultRetryCount, MinRetryCount, MaxRetryCount)
    if "intervalSecs" in body:
      hasInterval = true
      intervalSecs = clampInt(body["intervalSecs"].getInt(), DefaultIntervalSecs, MinIntervalSecs, MaxIntervalSecs)
    if "enabled" in body:
      hasEnabled = true
      enabled = body["enabled"].getBool()
  except ValueError as e:
    request.respond(400, newJsonHeaders(), (%* {"error": e.msg}).pretty)
    return
  except CatchableError:
    request.respond(400, newJsonHeaders(), (%* {"error": "Invalid request body"}).pretty)
    return

  try:
    var projectDbId = ""
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return
      projectDbId = $projectInfo.get.dbId

    let before = getMonitorForProject(monitorId, projectDbId)
    if before.isNone:
      request.respond(404, newJsonHeaders(), (%* {"error": "Monitor not found"}).pretty)
      return

    let oldDoc = before.get
    let updated = updateMonitor(
      projectDbId,
      monitorId,
      monitorName,
      monitorUrl,
      timeoutMs,
      retryCount,
      intervalSecs,
      enabled,
      hasName,
      hasUrl,
      hasTimeout,
      hasRetry,
      hasInterval,
      hasEnabled
    )
    if updated.isNone:
      request.respond(404, newJsonHeaders(), (%* {"error": "Monitor not found"}).pretty)
      return

    let newEnabled = if hasEnabled: enabled else: oldDoc["enabled"].getBool()
    let newInterval = if hasInterval: intervalSecs else: oldDoc["intervalSecs"].getInt()
    if monitorNeedsJobResync(
      hasEnabled,
      hasInterval,
      oldDoc["enabled"].getBool(),
      oldDoc["intervalSecs"].getInt(),
      newInterval,
      newEnabled
    ):
      if newEnabled:
        resyncUptimeMonitor(monitorId, newInterval)
      else:
        cancelUptimeJobs(monitorId)

    request.respond(200, newJsonHeaders(), updated.get.pretty)
  except CatchableError as e:
    error "Failed to update uptime monitor", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to update monitor"}).pretty)

proc deleteProjectUptimeMonitor*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let monitorId = request.pathParams.getOrDefault("monitorId", "")
  if projectId.len == 0 or monitorId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project and monitor id required"}).pretty)
    return

  try:
    var projectDbId = ""
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return
      projectDbId = $projectInfo.get.dbId

    if not deleteMonitor(projectDbId, monitorId):
      request.respond(404, newJsonHeaders(), (%* {"error": "Monitor not found"}).pretty)
      return

    request.respond(200, newJsonHeaders(), (%* {"deleted": 1}).pretty)
  except CatchableError as e:
    error "Failed to delete uptime monitor", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to delete monitor"}).pretty)

proc listProjectUptimeChecks*(request: Request) =
  let user = getUser(request)
  if user.isNone:
    request.respond(401, newJsonHeaders(), (%* {"message": "Unauthorized"}).pretty)
    return

  let projectId = request.pathParams.getOrDefault("id", "")
  let monitorId = request.pathParams.getOrDefault("monitorId", "")
  if projectId.len == 0 or monitorId.len == 0:
    request.respond(400, newJsonHeaders(), (%* {"error": "Project and monitor id required"}).pretty)
    return

  let page = parseQueryInt(request.queryParams.getOrDefault("page", "1"), 1, 1, 1_000_000)
  let pageSize = parseQueryInt(
    request.queryParams.getOrDefault("pageSize", $DefaultChecksPageSize),
    DefaultChecksPageSize,
    1,
    MaxChecksPageSize
  )

  try:
    var projectDbId = ""
    withDb dbPool:
      let projectInfo = selectOwnedProject(db, projectId, user.get.id)
      if projectInfo.isNone:
        request.respond(404, newJsonHeaders(), (%* {"error": "Project not found"}).pretty)
        return
      projectDbId = $projectInfo.get.dbId

    let result = listChecks(projectDbId, monitorId, page, pageSize)
    if result.isNone:
      request.respond(404, newJsonHeaders(), (%* {"error": "Monitor not found"}).pretty)
      return

    let data = result.get
    let totalPages =
      if data.total == 0:
        0
      else:
        (data.total + pageSize - 1) div pageSize

    var parts: seq[string] = @[]
    for item in data.checks:
      parts.add item.pretty

    request.respond(200, newJsonHeaders(), (%* {
      "checks": parseJson("[" & parts.join(",") & "]"),
      "pagination": {
        "page": page,
        "pageSize": pageSize,
        "total": data.total,
        "totalPages": totalPages
      }
    }).pretty)
  except CatchableError as e:
    error "Failed to list uptime checks", errorMsg = e.msg
    request.respond(500, newJsonHeaders(), (%* {"error": "Failed to list checks"}).pretty)
