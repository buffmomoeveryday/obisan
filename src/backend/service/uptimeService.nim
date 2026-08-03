import json
import options
import strutils
import times
import os
import httpclient
import uuid4

import ../database/db
import ./dbService
import ./uptimeStore
import ./notification/notificationService

const
  DefaultTimeoutMs* = 5000
  DefaultRetryCount* = 2
  DefaultIntervalSecs* = 60
  MinTimeoutMs* = 1000
  MaxTimeoutMs* = 30000
  MinRetryCount* = 0
  MaxRetryCount* = 5
  MinIntervalSecs* = 30
  MaxIntervalSecs* = 3600
  MaxUrlLen* = 2048
  RetryPauseMs* = 500
  DefaultChecksPageSize* = 20
  MaxChecksPageSize* = 100

type
  CheckResult* = object
    status*: string
    responseMs*: int
    statusCode*: int
    error*: string

proc clampInt*(value, defaultValue, minValue, maxValue: int): int =
  if value <= 0:
    defaultValue
  elif value < minValue:
    minValue
  elif value > maxValue:
    maxValue
  else:
    value

proc validateMonitorUrl*(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    raise newException(ValueError, "URL required")
  if result.len > MaxUrlLen:
    raise newException(ValueError, "URL too long")
  let lowered = result.toLowerAscii()
  if not (lowered.startsWith("http://") or lowered.startsWith("https://")):
    raise newException(ValueError, "URL must start with http:// or https://")

proc normalizeMonitorName*(raw: string): string =
  result = raw.strip()
  if result.len == 0:
    result = "Primary"
  if result.len > 80:
    result = result[0 ..< 80]

proc newMonitorId*(): string =
  ($uuid4()).replace("-", "")

proc monitorDocToApiJson*(doc: JsonNode): JsonNode =
  let lastCheckedAt = doc["lastCheckedAt"].getInt().int64
  %* {
    "id": doc["id"].getStr(),
    "name": doc["name"].getStr(),
    "url": doc["url"].getStr(),
    "timeoutMs": doc["timeoutMs"].getInt(),
    "retryCount": doc["retryCount"].getInt(),
    "intervalSecs": doc["intervalSecs"].getInt(),
    "enabled": doc["enabled"].getBool(),
    "lastStatus": doc["lastStatus"].getStr(),
    "lastCheckedAt": if lastCheckedAt <= 0: "" else: formatUnixTime(lastCheckedAt),
    "lastResponseMs": doc["lastResponseMs"].getInt(),
    "lastStatusCode": doc["lastStatusCode"].getInt(),
    "lastError": doc["lastError"].getStr()
  }

proc checkDocToApiJson*(doc: JsonNode): JsonNode =
  let checkedAt =
    if "checkedAt" in doc:
      doc["checkedAt"].getInt().int64
    else:
      0'i64
  %* {
    "id": doc["id"].getStr(),
    "status": if "status" in doc: doc["status"].getStr() else: "unknown",
    "responseMs": if "responseMs" in doc: doc["responseMs"].getInt() else: 0,
    "statusCode": if "statusCode" in doc: doc["statusCode"].getInt() else: 0,
    "error": if "error" in doc: doc["error"].getStr() else: "",
    "checkedAt": if checkedAt <= 0: "" else: formatUnixTime(checkedAt)
  }

proc newMonitorDoc*(
  projectId, name, url, ntfyTopic: string,
  timeoutMs, retryCount, intervalSecs: int,
  enabled: bool
): JsonNode =
  %* {
    "id": newMonitorId(),
    "projectId": projectId,
    "name": name,
    "url": url,
    "timeoutMs": timeoutMs,
    "retryCount": retryCount,
    "intervalSecs": intervalSecs,
    "enabled": enabled,
    "ntfyTopic": ntfyTopic,
    "lastStatus": "unknown",
    "lastCheckedAt": 0,
    "lastResponseMs": 0,
    "lastStatusCode": 0,
    "lastError": ""
  }

proc singleHttpCheck(url: string, timeoutMs: int, useHead: bool): CheckResult =
  let started = epochTime().float
  var client = newHttpClient(timeout = timeoutMs)
  try:
    let response =
      if useHead:
        client.request(url, httpMethod = HttpHead)
      else:
        client.get(url)
    let elapsed = int((epochTime().float - started) * 1000.0)
    let code = response.code.int
    if code >= 200 and code < 400:
      CheckResult(status: "up", responseMs: elapsed, statusCode: code, error: "")
    else:
      CheckResult(
        status: "down",
        responseMs: elapsed,
        statusCode: code,
        error: "HTTP " & $code
      )
  except CatchableError as e:
    let elapsed = int((epochTime().float - started) * 1000.0)
    CheckResult(status: "down", responseMs: elapsed, statusCode: 0, error: e.msg)
  finally:
    client.close()

proc performCheck*(url: string, timeoutMs, retryCount: int): CheckResult =
  let attempts = retryCount + 1
  var last = CheckResult(status: "down", responseMs: 0, statusCode: 0, error: "No attempts made")
  for attempt in 0 ..< attempts:
    if attempt > 0:
      sleep(RetryPauseMs)
    var headResult = singleHttpCheck(url, timeoutMs, useHead = true)
    if headResult.statusCode == 405 or headResult.statusCode == 501:
      headResult = singleHttpCheck(url, timeoutMs, useHead = false)
    elif headResult.statusCode == 0 and headResult.error.len > 0:
      headResult = singleHttpCheck(url, timeoutMs, useHead = false)
    last = headResult
    if headResult.status == "up":
      return headResult
  last

proc executeMonitorCheck*(monitorId: string) =
  let maybeDoc = getMonitorDoc(monitorId)
  if maybeDoc.isNone:
    return
  var doc = maybeDoc.get
  if not doc["enabled"].getBool():
    return

  let previousStatus = doc["lastStatus"].getStr()
  let checkedAt = epochTime().int64
  let result = performCheck(
    doc["url"].getStr(),
    doc["timeoutMs"].getInt(),
    doc["retryCount"].getInt()
  )

  let checkId = monitorId & "-" & $checkedAt
  let checkDoc = %* {
    "id": checkId,
    "status": result.status,
    "responseMs": result.responseMs,
    "statusCode": result.statusCode,
    "error": result.error,
    "checkedAt": checkedAt
  }
  appendCheckDoc(monitorId, checkDoc)

  doc["lastStatus"] = %result.status
  doc["lastCheckedAt"] = %checkedAt
  doc["lastResponseMs"] = %result.responseMs
  doc["lastStatusCode"] = %result.statusCode
  doc["lastError"] = %result.error
  saveMonitorDoc(doc)

  let ntfyTopic = doc["ntfyTopic"].getStr()
  let name = doc["name"].getStr()
  let url = doc["url"].getStr()
  if previousStatus.len > 0 and previousStatus != "unknown" and previousStatus != result.status:
    let projectId = doc["projectId"].getStr()
    var projectName = ""
    var projectWebhookUrl = ""
    var projectNotificationConfigs = ""
    withDb dbPool:
      let projectRow = db.getRow(dbSql"SELECT name, webhookUrl, notificationConfigs FROM projects WHERE id = ?", projectId)
      if projectRow.isSome:
        projectName = dbText(projectRow.get[0])
        projectWebhookUrl = dbText(projectRow.get[1])
        projectNotificationConfigs = dbText(projectRow.get[2])

    let data = %* {
      "monitorId": monitorId,
      "name": name,
      "url": url,
      "previousStatus": previousStatus,
      "status": result.status,
      "responseMs": result.responseMs,
      "statusCode": result.statusCode,
      "error": result.error,
      "checkedAt": checkedAt
    }

    let title = if result.status == "down": "Uptime alert: " & name else: "Uptime recovered: " & name
    let body = if result.status == "down":
      name & " is DOWN\n" & url & "\n" & result.error
    else:
      name & " is back UP (" & $result.responseMs & "ms)\n" & url

    let priority = if result.status == "down": npHigh else: npNormal
    let notifService = buildProjectNotificationService(
      ntfyTopic,
      projectWebhookUrl,
      projectNotificationConfigs,
      projectName = projectName
    )
    let notifMsg = NotificationMessage(
      title: title,
      body: body,
      priority: priority,
      eventType: "uptime.status_changed",
      projectId: projectId,
      projectName: projectName,
      data: data
    )
    notifService.notify(notifMsg)

proc listMonitors*(projectId: string): seq[JsonNode] =
  for doc in listMonitorsForProject(projectId):
    result.add monitorDocToApiJson(doc)

proc createMonitor*(
  projectId, name, url, ntfyTopic: string,
  timeoutMs, retryCount, intervalSecs: int,
  enabled: bool
): JsonNode =
  let doc = newMonitorDoc(
    projectId, name, url, ntfyTopic,
    timeoutMs, retryCount, intervalSecs, enabled
  )
  saveMonitorDoc(doc)
  monitorDocToApiJson(doc)

proc updateMonitor*(
  projectId, monitorId: string,
  name, url: string,
  timeoutMs, retryCount, intervalSecs: int,
  enabled: bool,
  hasName, hasUrl, hasTimeout, hasRetry, hasInterval, hasEnabled: bool
): Option[JsonNode] =
  let existing = getMonitorForProject(monitorId, projectId)
  if existing.isNone:
    return none[JsonNode]()

  var doc = existing.get
  if hasName:
    doc["name"] = %name
  if hasUrl:
    doc["url"] = %url
  if hasTimeout:
    doc["timeoutMs"] = %timeoutMs
  if hasRetry:
    doc["retryCount"] = %retryCount
  if hasInterval:
    doc["intervalSecs"] = %intervalSecs
  if hasEnabled:
    doc["enabled"] = %enabled

  saveMonitorDoc(doc)
  some(monitorDocToApiJson(doc))

proc deleteMonitor*(projectId, monitorId: string): bool =
  let existing = getMonitorForProject(monitorId, projectId)
  if existing.isNone:
    return false
  cancelUptimeJobs(monitorId)
  deleteMonitorData(monitorId)
  true

proc listChecks*(projectId, monitorId: string, page, pageSize: int): Option[tuple[checks: seq[JsonNode], total: int]] =
  let existing = getMonitorForProject(monitorId, projectId)
  if existing.isNone:
    return none[tuple[checks: seq[JsonNode], total: int]]()

  let offset = (page - 1) * pageSize
  let total = countCheckDocs(monitorId)
  var checks: seq[JsonNode] = @[]
  for doc in listCheckDocs(monitorId, pageSize, offset):
    checks.add checkDocToApiJson(doc)
  some((checks: checks, total: total))

proc monitorNeedsJobResync*(
  hasEnabled, hasInterval: bool,
  oldEnabled: bool,
  oldInterval, newInterval: int,
  newEnabled: bool
): bool =
  if hasEnabled and oldEnabled != newEnabled:
    return true
  if hasInterval and oldInterval != newInterval:
    return true
  false
