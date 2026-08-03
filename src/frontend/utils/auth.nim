import json
import options
import strutils
import uri
import karax/[kajax, localstorage, karax]

const tokenKey = cstring"obisan_token"
const themeKey = cstring"obisan_theme"

type AuthUser* = object
  id*: string
  name*: string
  email*: string

type Project* = object
  id*: string
  name*: string
  publicKey*: string
  dsn*: string
  ntfyTopic*: string
  ntfyUrl*: string
  webhookUrl*: string
  emailEnabled*: bool
  emailToAddrs*: string
  issueCount*: int

type Issue* = object
  eventId*: string
  errorType*: string
  message*: string
  level*: string
  platform*: string
  receivedAt*: string

type IssueDetail* = object
  eventId*: string
  errorType*: string
  message*: string
  level*: string
  platform*: string
  receivedAt*: string
  receivedAtUnix*: int64
  stacktrace*: string

type Metric* = object
  id*: string
  name*: string
  metricType*: string
  value*: string
  unit*: string
  tags*: string
  receivedAt*: string

type UptimeMonitor* = object
  id*: string
  name*: string
  url*: string
  timeoutMs*: int
  retryCount*: int
  intervalSecs*: int
  enabled*: bool
  lastStatus*: string
  lastCheckedAt*: string
  lastResponseMs*: int
  lastStatusCode*: int
  lastError*: string

type UptimeCheck* = object
  id*: string
  status*: string
  responseMs*: int
  statusCode*: int
  error*: string
  checkedAt*: string

type ProjectMember* = object
  id*: string
  name*: string
  email*: string
  owner*: bool

type AppSettings* = object
  ntfyServerUrl*: string
  ntfyUsername*: string
  ntfyTokenConfigured*: bool
  ntfyPasswordConfigured*: bool
  smtpHost*: string
  smtpPort*: int
  smtpUsername*: string
  smtpPasswordConfigured*: bool
  smtpFromAddr*: string
  smtpUseTls*: bool

const EventsPageSize* = 20
const MetricsChartPollMs = 15000
const DefaultMetricRange* = "1h"

proc browserNowMs(): int =
  {.emit: "`result` = Date.now();".}

var
  setupLoaded* = false
  needsSetup* = false
  profileLoading* = false
  projectsLoading* = false
  projectsLoaded* = false
  eventsLoading* = false
  eventsProjectId* = ""
  eventsSearch* = ""
  eventsSearchDraft* = ""
  eventsPage* = 1
  eventsTotal* = 0
  eventsTotalPages* = 0
  eventsQueryKey* = ""
  selectedEventIds* = newSeq[string]()
  eventsDeleting* = false
  logsLoading* = false
  logsProjectId* = ""
  logsSearch* = ""
  logsSearchDraft* = ""
  logsPage* = 1
  logsTotal* = 0
  logsTotalPages* = 0
  logsQueryKey* = ""
  logsPolling* = false
  logsPollingProjectId* = ""
  breadcrumbLogsLoading* = false
  breadcrumbLogsLoadedFor* = ""
  breadcrumbLogsBaseEventId* = ""
  metricsLoading* = false
  metricsProjectId* = ""
  metricsSearch* = ""
  metricsSearchDraft* = ""
  metricsRange* = DefaultMetricRange
  metricsPage* = 1
  metricsTotal* = 0
  metricsTotalPages* = 0
  metricsQueryKey* = ""
  metricsRefreshInFlight* = false
  metricsChartLoading* = false
  metricsChartProjectId* = ""
  metricsChartQueryKey* = ""
  metricsChartLastLoadedAt* = 0
  metricsPolling* = false
  metricsPollingProjectId* = ""
  uptimeLoading* = false
  uptimeSaving* = false
  uptimeProjectId* = ""
  uptimeQueryKey* = ""
  uptimeChecksLoading* = false
  uptimeChecksMonitorId* = ""
  uptimeChecksPage* = 1
  uptimeChecksTotal* = 0
  uptimeChecksTotalPages* = 0
  uptimePolling* = false
  uptimePollingProjectId* = ""
  membersLoading* = false
  membersSaving* = false
  membersProjectId* = ""
  settingsLoading* = false
  settingsSaving* = false
  profileSaving* = false
  settingsLoaded* = false
  issueDetailLoading* = false
  issueDetailLoadedFor* = ""
  currentUser* = AuthUser()
  projects* = newSeq[Project]()
  projectEvents* = newSeq[Issue]()
  projectLogs* = newSeq[Issue]()
  breadcrumbLogs* = newSeq[Issue]()
  projectMetrics* = newSeq[Metric]()
  projectMetricChartSamples* = newSeq[Metric]()
  projectUptimeMonitors* = newSeq[UptimeMonitor]()
  projectUptimeChecks* = newSeq[UptimeCheck]()
  projectMembers* = newSeq[ProjectMember]()
  appSettings* = AppSettings(ntfyServerUrl: "https://ntfy.sh", smtpUseTls: true)
  selectedIssue* = IssueDetail()
  authMessage* = ""
  copyFeedback* = ""
  darkMode* = false

proc applyThemeClass() =
  let enabled = darkMode
  {.emit: "document.documentElement.classList.toggle('dark', `enabled`);".}

proc syncThemeFromDom*() =
  {.emit: "`darkMode` = document.documentElement.classList.contains('dark');".}

proc toggleTheme*() =
  darkMode = not darkMode
  let mode = if darkMode: cstring"dark" else: cstring"light"
  setItem(themeKey, mode)
  applyThemeClass()
  redraw()

proc setHash(path: cstring) =
  {.emit: "window.location.hash = '#' + `path`;".}

proc navigate*(path: string) =
  setHash(cstring(path))

proc savedToken*(): string =
  if hasItem(tokenKey):
    result = $getItem(tokenKey)

proc isAuthenticated*(): bool =
  savedToken().len > 0 and currentUser.email.len > 0

proc smtpConfigured*(): bool =
  appSettings.smtpHost.strip().len > 0 and appSettings.smtpFromAddr.strip().len > 0

proc clearCopyFeedback*() {.exportc.} =
  copyFeedback = ""
  redraw()

proc copyText*(text: string) =
  let value = cstring(text)
  copyFeedback = "Copied!"
  redraw()
  {.emit: """
    navigator.clipboard.writeText(`value`);
    setTimeout(function() { clearCopyFeedback(); }, 2000);
  """.}

proc clearSession*() =
  removeItem(tokenKey)
  currentUser = AuthUser()
  projects = @[]
  projectsLoaded = false
  projectEvents = @[]
  eventsProjectId = ""
  eventsSearch = ""
  eventsSearchDraft = ""
  eventsPage = 1
  eventsTotal = 0
  eventsTotalPages = 0
  eventsQueryKey = ""
  selectedEventIds = @[]
  eventsDeleting = false
  logsLoading = false
  logsProjectId = ""
  logsSearch = ""
  logsSearchDraft = ""
  logsPage = 1
  logsTotal = 0
  logsTotalPages = 0
  logsQueryKey = ""
  logsPolling = false
  logsPollingProjectId = ""
  breadcrumbLogsLoading = false
  breadcrumbLogsLoadedFor = ""
  breadcrumbLogsBaseEventId = ""
  metricsLoading = false
  metricsProjectId = ""
  metricsSearch = ""
  metricsSearchDraft = ""
  metricsRange = DefaultMetricRange
  metricsPage = 1
  metricsTotal = 0
  metricsTotalPages = 0
  metricsQueryKey = ""
  metricsRefreshInFlight = false
  metricsChartLoading = false
  metricsChartProjectId = ""
  metricsChartQueryKey = ""
  metricsChartLastLoadedAt = 0
  metricsPolling = false
  metricsPollingProjectId = ""
  uptimeLoading = false
  uptimeSaving = false
  uptimeProjectId = ""
  uptimeQueryKey = ""
  uptimeChecksLoading = false
  uptimeChecksMonitorId = ""
  uptimeChecksPage = 1
  uptimeChecksTotal = 0
  uptimeChecksTotalPages = 0
  uptimePolling = false
  uptimePollingProjectId = ""
  membersLoading = false
  membersSaving = false
  membersProjectId = ""
  settingsLoading = false
  settingsSaving = false
  profileSaving = false
  settingsLoaded = false
  projectUptimeMonitors = @[]
  projectUptimeChecks = @[]
  projectMembers = @[]
  appSettings = AppSettings(ntfyServerUrl: "https://ntfy.sh", smtpUseTls: true)
  issueDetailLoadedFor = ""
  projectLogs = @[]
  breadcrumbLogs = @[]
  projectMetrics = @[]
  projectMetricChartSamples = @[]
  selectedIssue = IssueDetail()
  copyFeedback = ""

proc clearEventSelection*() =
  selectedEventIds = @[]

proc findProject*(projectId: string): Option[Project] =
  for project in projects:
    if project.id == projectId:
      return some(project)
  none[Project]()

proc setSessionToken(token: string) =
  setItem(tokenKey, cstring(token))

proc jsonHeaders(): seq[(cstring, cstring)] =
  @[(cstring"Content-Type", cstring"application/json")]

proc authHeaders(): seq[(cstring, cstring)] =
  @[
    (cstring"Content-Type", cstring"application/json"),
    (cstring"Authorization", cstring("Bearer " & savedToken()))
  ]

proc parseProject(data: JsonNode): Project =
  Project(
    id: data["id"].getStr(),
    name: data["name"].getStr(),
    publicKey: data["publicKey"].getStr(),
    dsn: data["dsn"].getStr(),
    ntfyTopic: if "ntfyTopic" in data: data["ntfyTopic"].getStr() else: "",
    ntfyUrl: if "ntfyUrl" in data: data["ntfyUrl"].getStr() else: "",
    webhookUrl: if "webhookUrl" in data: data["webhookUrl"].getStr() else: "",
    emailEnabled: if "emailEnabled" in data: data["emailEnabled"].getBool() else: false,
    emailToAddrs: if "emailToAddrs" in data: data["emailToAddrs"].getStr() else: "",
    issueCount: if "issueCount" in data: data["issueCount"].getInt() else: 0
  )

proc parseIssue(data: JsonNode): Issue =
  Issue(
    eventId: data["eventId"].getStr(),
    errorType: data["errorType"].getStr(),
    message: data["message"].getStr(),
    level: data["level"].getStr(),
    platform: data["platform"].getStr(),
    receivedAt: data["receivedAt"].getStr()
  )

proc parseMetric(data: JsonNode): Metric =
  Metric(
    id: data["id"].getStr(),
    name: data["name"].getStr(),
    metricType: data["type"].getStr(),
    value: $data["value"].getFloat(),
    unit: data["unit"].getStr(),
    tags: data["tags"].getStr(),
    receivedAt: data["receivedAt"].getStr()
  )

proc parseUptimeMonitor(data: JsonNode): UptimeMonitor =
  UptimeMonitor(
    id: data["id"].getStr(),
    name: data["name"].getStr(),
    url: data["url"].getStr(),
    timeoutMs: data["timeoutMs"].getInt(),
    retryCount: data["retryCount"].getInt(),
    intervalSecs: data["intervalSecs"].getInt(),
    enabled: data["enabled"].getBool(),
    lastStatus: data["lastStatus"].getStr(),
    lastCheckedAt: data["lastCheckedAt"].getStr(),
    lastResponseMs: data["lastResponseMs"].getInt(),
    lastStatusCode: data["lastStatusCode"].getInt(),
    lastError: data["lastError"].getStr()
  )

proc parseUptimeCheck(data: JsonNode): UptimeCheck =
  UptimeCheck(
    id: data["id"].getStr(),
    status: data["status"].getStr(),
    responseMs: data["responseMs"].getInt(),
    statusCode: data["statusCode"].getInt(),
    error: data["error"].getStr(),
    checkedAt: data["checkedAt"].getStr()
  )

proc parseProjectMember(data: JsonNode): ProjectMember =
  ProjectMember(
    id: data["id"].getStr(),
    name: data["name"].getStr(),
    email: data["email"].getStr(),
    owner: if "owner" in data: data["owner"].getBool() else: false
  )

proc parseAppSettings(data: JsonNode): AppSettings =
  AppSettings(
    ntfyServerUrl: if "ntfyServerUrl" in data: data["ntfyServerUrl"].getStr() else: "https://ntfy.sh",
    ntfyUsername: if "ntfyUsername" in data: data["ntfyUsername"].getStr() else: "",
    ntfyTokenConfigured: if "ntfyTokenConfigured" in data: data["ntfyTokenConfigured"].getBool() else: false,
    ntfyPasswordConfigured: if "ntfyPasswordConfigured" in data: data["ntfyPasswordConfigured"].getBool() else: false,
    smtpHost: if "smtpHost" in data: data["smtpHost"].getStr() else: "",
    smtpPort: if "smtpPort" in data: data["smtpPort"].getInt() else: 0,
    smtpUsername: if "smtpUsername" in data: data["smtpUsername"].getStr() else: "",
    smtpPasswordConfigured: if "smtpPasswordConfigured" in data: data["smtpPasswordConfigured"].getBool() else: false,
    smtpFromAddr: if "smtpFromAddr" in data: data["smtpFromAddr"].getStr() else: "",
    smtpUseTls: if "smtpUseTls" in data: data["smtpUseTls"].getBool() else: true
  )

proc loadProfile*(goDashboard = false) =
  if savedToken().len == 0:
    currentUser = AuthUser()
    if not needsSetup:
      navigate("/login")
    return

  profileLoading = true
  ajaxGet(cstring"/api/profile/", authHeaders(), proc(status: int, response: cstring) =
    profileLoading = false
    if status == 200:
      let data = parseJson($response)
      currentUser = AuthUser(
        id: $data["id"].getInt(),
        name: data["name"].getStr(),
        email: data["email"].getStr()
      )
      authMessage = ""
      if goDashboard:
        navigate("/dashboard")
      redraw()
    else:
      clearSession()
      authMessage = "Your session expired. Sign in again."
      navigate("/login")
  )

proc loadProjects*() =
  if savedToken().len == 0:
    return

  projectsLoading = true
  ajaxGet(cstring"/api/projects/", authHeaders(), proc(status: int, response: cstring) =
    projectsLoading = false
    projectsLoaded = true
    if status == 200:
      let data = parseJson($response)
      projects = @[]
      for item in data["projects"]:
        projects.add parseProject(item)
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view projects."
      navigate("/login")
    else:
      authMessage = "Unable to load projects."
    redraw()
  )

proc loadAppSettings*() =
  if savedToken().len == 0:
    return
  if settingsLoading:
    return

  settingsLoading = true
  ajaxGet(cstring"/api/settings/", authHeaders(), proc(status: int, response: cstring) =
    settingsLoading = false
    if status == 200:
      appSettings = parseAppSettings(parseJson($response))
      settingsLoaded = true
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view settings."
      navigate("/login")
    else:
      authMessage = "Unable to load settings."
    redraw()
  )

proc updateAppSettings*(
  ntfyServerUrl, ntfyUsername, ntfyPassword, ntfyToken: string,
  clearNtfyPassword, clearNtfyToken: bool,
  smtpHost, smtpPort, smtpUsername, smtpPassword, smtpFromAddr: string,
  smtpUseTls, clearSmtpPassword: bool,
  onDone: proc() {.closure.}
) =
  if savedToken().len == 0 or settingsSaving:
    return

  var portValue = 0
  if smtpPort.strip().len > 0:
    try:
      portValue = parseInt(smtpPort.strip())
    except ValueError:
      authMessage = "SMTP port must be a number."
      redraw()
      return

  settingsSaving = true
  let body = $(%* {
    "ntfyServerUrl": ntfyServerUrl.strip(),
    "ntfyUsername": ntfyUsername.strip(),
    "ntfyPassword": ntfyPassword,
    "ntfyToken": ntfyToken,
    "clearNtfyPassword": clearNtfyPassword,
    "clearNtfyToken": clearNtfyToken,
    "smtpHost": smtpHost.strip(),
    "smtpPort": portValue,
    "smtpUsername": smtpUsername.strip(),
    "smtpPassword": smtpPassword,
    "smtpFromAddr": smtpFromAddr.strip(),
    "smtpUseTls": smtpUseTls,
    "clearSmtpPassword": clearSmtpPassword
  })
  ajax(cstring"PATCH", cstring"/api/settings/", authHeaders(), cstring(body), proc(status: int, response: cstring) =
    settingsSaving = false
    if status == 200:
      appSettings = parseAppSettings(parseJson($response))
      settingsLoaded = true
      authMessage = ""
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update settings."
      navigate("/login")
    else:
      try:
        let data = parseJson($response)
        if "error" in data:
          authMessage = data["error"].getStr()
        else:
          authMessage = "Unable to update settings."
      except CatchableError:
        authMessage = "Unable to update settings."
    redraw()
  )

proc updateProfile*(
  name, email, currentPassword, newPassword: string,
  onDone: proc() {.closure.}
) =
  if savedToken().len == 0 or profileSaving:
    return

  profileSaving = true
  let body = $(%* {
    "name": name.strip(),
    "email": email.strip(),
    "currentPassword": currentPassword,
    "newPassword": newPassword
  })
  ajax(cstring"PATCH", cstring"/api/profile/", authHeaders(), cstring(body), proc(status: int, response: cstring) =
    profileSaving = false
    if status == 200:
      let data = parseJson($response)
      currentUser = AuthUser(
        id: $data["id"].getInt(),
        name: data["name"].getStr(),
        email: data["email"].getStr()
      )
      if "token" in data:
        setSessionToken(data["token"].getStr())
      authMessage = ""
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update your account."
      navigate("/login")
    else:
      try:
        let data = parseJson($response)
        if "error" in data:
          authMessage = data["error"].getStr()
        else:
          authMessage = "Unable to update account."
      except CatchableError:
        authMessage = "Unable to update account."
    redraw()
  )

proc bootstrapSession*() =
  if savedToken().len == 0:
    return
  if currentUser.email.len == 0 and not profileLoading:
    loadProfile()
  elif not projectsLoaded and not projectsLoading:
    loadProjects()

proc parseIssueDetail(data: JsonNode): IssueDetail =
  IssueDetail(
    eventId: data["eventId"].getStr(),
    errorType: data["errorType"].getStr(),
    message: data["message"].getStr(),
    level: data["level"].getStr(),
    platform: data["platform"].getStr(),
    receivedAt: data["receivedAt"].getStr(),
    receivedAtUnix: if "receivedAtUnix" in data: data["receivedAtUnix"].getBiggestInt().int64 else: 0,
    stacktrace: data["stacktrace"].getStr()
  )

proc breadcrumbParentEventId*(eventId: string): string =
  let marker = "-breadcrumb-"
  let markerAt = eventId.find(marker)
  if markerAt < 0:
    ""
  else:
    eventId[0 ..< markerAt]

proc isBreadcrumbLogEventId*(eventId: string): bool =
  breadcrumbParentEventId(eventId).len > 0

proc buildLogsPath(projectId: string, search: string, page, pageSize: int): string

proc loadIssueDetail*(projectId, eventId: string) =
  if savedToken().len == 0:
    return

  let viewKey = projectId & ":" & eventId
  issueDetailLoading = true
  selectedIssue = IssueDetail()
  let path = cstring("/api/projects/" & projectId & "/events/" & eventId & "/")
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    issueDetailLoading = false
    if status == 200:
      selectedIssue = parseIssueDetail(parseJson($response))
      issueDetailLoadedFor = viewKey
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view this issue."
      navigate("/login")
    elif status == 404:
      issueDetailLoadedFor = ""
      authMessage = "Issue not found."
      navigate("/projects/" & projectId)
    else:
      issueDetailLoadedFor = ""
      authMessage = "Unable to load issue details."
    redraw()
  )

proc loadBreadcrumbLogs*(projectId, eventId: string) =
  if savedToken().len == 0:
    return

  let baseEventId = breadcrumbParentEventId(eventId)
  if baseEventId.len == 0:
    breadcrumbLogs = @[]
    breadcrumbLogsLoadedFor = ""
    breadcrumbLogsBaseEventId = ""
    return

  let viewKey = projectId & ":" & eventId
  breadcrumbLogsLoading = true
  let path = cstring(buildLogsPath(projectId, baseEventId, 1, 100))
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    breadcrumbLogsLoading = false
    if status == 200:
      let data = parseJson($response)
      breadcrumbLogs = @[]
      for item in data["logs"]:
        let itemIssue = parseIssue(item)
        if itemIssue.eventId.find(baseEventId & "-breadcrumb-") == 0:
          breadcrumbLogs.add itemIssue
      breadcrumbLogsLoadedFor = viewKey
      breadcrumbLogsBaseEventId = baseEventId
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view logs."
      navigate("/login")
    else:
      breadcrumbLogs = @[]
      breadcrumbLogsLoadedFor = ""
      breadcrumbLogsBaseEventId = baseEventId
      authMessage = "Unable to load breadcrumb logs."
    redraw()
  )

proc issueDetailHref*(projectId, eventId: string): string =
  "#/projects/" & projectId & "/issues/" & eventId

proc encodeQueryComponent*(value: string): string =
  encodeUrl(value, usePlus = false)

proc parseEventsPageParam*(value: string): int =
  result = 1
  if value.len == 0:
    return
  try:
    let page = parseInt(value)
    if page >= 1:
      result = page
  except ValueError:
    discard

proc projectEventsHash*(projectId: string, search: string = "", page: int = 1): string =
  result = "/projects/" & projectId
  var parts: seq[string] = @[]
  if search.len > 0:
    parts.add "search=" & encodeQueryComponent(search)
  if page > 1:
    parts.add "page=" & $page
  if parts.len > 0:
    result &= "?" & parts.join("&")

proc projectEventsHref*(projectId: string, search: string = "", page: int = 1): string =
  "#" & projectEventsHash(projectId, search, page)

proc projectLogsHash*(projectId: string, search: string = "", page: int = 1): string =
  result = "/projects/" & projectId & "/logs"
  var parts: seq[string] = @[]
  if search.len > 0:
    parts.add "search=" & encodeQueryComponent(search)
  if page > 1:
    parts.add "page=" & $page
  if parts.len > 0:
    result &= "?" & parts.join("&")

proc projectLogsHref*(projectId: string, search: string = "", page: int = 1): string =
  "#" & projectLogsHash(projectId, search, page)

proc normalizeMetricRange*(raw: string): string =
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

proc metricRangeLabel*(metricRange: string): string =
  case normalizeMetricRange(metricRange)
  of "1m":
    "1 minute"
  of "5m":
    "5 minutes"
  of "10m":
    "10 minutes"
  of "1h":
    "1 hour"
  of "24h":
    "24 hours"
  of "7d":
    "7 days"
  of "14d":
    "14 days"
  of "30d":
    "1 month"
  else:
    "All"

proc projectMetricsHash*(projectId: string, search: string = "", page: int = 1, metricRange: string = DefaultMetricRange): string =
  result = "/projects/" & projectId & "/metrics"
  var parts: seq[string] = @[]
  if search.len > 0:
    parts.add "search=" & encodeQueryComponent(search)
  let rangeValue = normalizeMetricRange(metricRange)
  if rangeValue != DefaultMetricRange:
    parts.add "range=" & encodeQueryComponent(rangeValue)
  if page > 1:
    parts.add "page=" & $page
  if parts.len > 0:
    result &= "?" & parts.join("&")

proc projectMetricsHref*(projectId: string, search: string = "", page: int = 1, metricRange: string = DefaultMetricRange): string =
  "#" & projectMetricsHash(projectId, search, page, metricRange)

proc projectUptimeHash*(projectId: string): string =
  "/projects/" & projectId & "/uptime"

proc projectUptimeHref*(projectId: string): string =
  "#" & projectUptimeHash(projectId)

proc navigateProjectUptime*(projectId: string) =
  setHash(cstring(projectUptimeHash(projectId)))

proc navigateProjectEvents*(projectId: string, search: string = "", page: int = 1) =
  setHash(cstring(projectEventsHash(projectId, search, page)))

proc navigateProjectLogs*(projectId: string, search: string = "", page: int = 1) =
  setHash(cstring(projectLogsHash(projectId, search, page)))

proc navigateProjectMetrics*(projectId: string, search: string = "", page: int = 1, metricRange: string = DefaultMetricRange) =
  setHash(cstring(projectMetricsHash(projectId, search, page, metricRange)))

proc buildEventsPath(projectId: string, search: string, page, pageSize: int): string =
  result = "/api/projects/" & projectId & "/events/?page=" & $page & "&pageSize=" & $pageSize
  if search.len > 0:
    result &= "&search=" & encodeQueryComponent(search)

proc buildLogsPath(projectId: string, search: string, page, pageSize: int): string =
  result = "/api/projects/" & projectId & "/logs/?page=" & $page & "&pageSize=" & $pageSize
  if search.len > 0:
    result &= "&search=" & encodeQueryComponent(search)

proc buildMetricsPath(projectId: string, search: string, page, pageSize: int, metricRange: string = DefaultMetricRange): string =
  result = "/api/projects/" & projectId & "/metrics/?page=" & $page & "&pageSize=" & $pageSize
  result &= "&range=" & encodeQueryComponent(normalizeMetricRange(metricRange))
  if search.len > 0:
    result &= "&search=" & encodeQueryComponent(search)

proc buildMetricsWindowPath(projectId: string, pageSize: int, metricRange: string, untilUnix: int64): string =
  result = buildMetricsPath(projectId, "", 1, pageSize, metricRange)
  if untilUnix > 0:
    result &= "&until=" & $untilUnix

proc metricChartPageSize(metricRange: string): int =
  case normalizeMetricRange(metricRange)
  of "1m", "5m", "10m":
    300
  of "1h":
    800
  of "24h":
    2000
  else:
    5000

proc loadProjectEvents*(projectId: string, search: string = "", page: int = 1, pageSize: int = EventsPageSize) =
  if savedToken().len == 0:
    return

  eventsLoading = true
  let path = cstring(buildEventsPath(projectId, search, page, pageSize))
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    eventsLoading = false
    if status == 200:
      let data = parseJson($response)
      projectEvents = @[]
      for item in data["events"]:
        projectEvents.add parseIssue(item)
      eventsProjectId = projectId
      eventsSearch = search
      eventsSearchDraft = search
      eventsPage = page
      if "pagination" in data:
        eventsTotal = data["pagination"]["total"].getInt()
        eventsTotalPages = data["pagination"]["totalPages"].getInt()
      else:
        eventsTotal = projectEvents.len
        eventsTotalPages = if eventsTotal > 0: 1 else: 0
      eventsQueryKey = projectId & "|" & search & "|" & $page
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view issues."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
      navigate("/dashboard")
    else:
      authMessage = "Unable to load issues."
    redraw()
  )

proc loadProjectLogs*(projectId: string, search: string = "", page: int = 1, pageSize: int = EventsPageSize) =
  if savedToken().len == 0:
    return

  logsLoading = true
  let path = cstring(buildLogsPath(projectId, search, page, pageSize))
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    logsLoading = false
    if status == 200:
      let data = parseJson($response)
      projectLogs = @[]
      for item in data["logs"]:
        projectLogs.add parseIssue(item)
      logsProjectId = projectId
      logsSearch = search
      logsPage = page
      if "pagination" in data:
        logsTotal = data["pagination"]["total"].getInt()
        logsTotalPages = data["pagination"]["totalPages"].getInt()
      else:
        logsTotal = projectLogs.len
        logsTotalPages = if logsTotal > 0: 1 else: 0
      logsQueryKey = projectId & "|" & search & "|" & $page
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view logs."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
      navigate("/dashboard")
    else:
      authMessage = "Unable to load logs."
    redraw()
  )

proc loadProjectMetrics*(
  projectId: string,
  search: string = "",
  page: int = 1,
  pageSize: int = EventsPageSize,
  showLoading: bool = true,
  metricRange: string = DefaultMetricRange
) =
  if savedToken().len == 0:
    return
  if metricsRefreshInFlight:
    return

  metricsRefreshInFlight = true
  if showLoading:
    metricsLoading = true
  let rangeValue = normalizeMetricRange(metricRange)
  let path = cstring(buildMetricsPath(projectId, search, page, pageSize, rangeValue))
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    metricsRefreshInFlight = false
    if showLoading:
      metricsLoading = false
    if status == 200:
      let data = parseJson($response)
      projectMetrics = @[]
      for item in data["metrics"]:
        projectMetrics.add parseMetric(item)
      metricsProjectId = projectId
      metricsSearch = search
      metricsRange = rangeValue
      metricsPage = page
      if "pagination" in data:
        metricsTotal = data["pagination"]["total"].getInt()
        metricsTotalPages = data["pagination"]["totalPages"].getInt()
      else:
        metricsTotal = projectMetrics.len
        metricsTotalPages = if metricsTotal > 0: 1 else: 0
      metricsQueryKey = projectId & "|" & search & "|" & rangeValue & "|" & $page
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view metrics."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
      navigate("/dashboard")
    else:
      authMessage = "Unable to load metrics."
    redraw()
  )

proc loadProjectMetricChartSamples*(projectId: string, search: string = "", pageSize: int = 0, metricRange: string = DefaultMetricRange) =
  if savedToken().len == 0 or projectId.len == 0:
    return

  metricsChartLoading = true
  let rangeValue = normalizeMetricRange(metricRange)
  let samplePageSize =
    if pageSize > 0:
      pageSize
    else:
      metricChartPageSize(rangeValue)
  let requestedKey = projectId & "|" & search & "|" & rangeValue
  let path = cstring(buildMetricsPath(projectId, search, 1, samplePageSize, rangeValue))
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    if metricsProjectId != projectId or metricsSearch != search or metricsRange != rangeValue:
      return

    metricsChartLoading = false
    if status == 200:
      let data = parseJson($response)
      projectMetricChartSamples = @[]
      for item in data["metrics"]:
        projectMetricChartSamples.add parseMetric(item)
      metricsChartProjectId = projectId
      metricsChartQueryKey = requestedKey
      metricsChartLastLoadedAt = browserNowMs()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view metrics."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
      navigate("/dashboard")
    redraw()
  )

proc loadProjectMetricChartWindowSamples*(projectId: string, untilUnix: int64, metricRange: string = "10m") =
  if savedToken().len == 0 or projectId.len == 0 or untilUnix <= 0:
    return

  metricsChartLoading = true
  let rangeValue = normalizeMetricRange(metricRange)
  let requestedKey = projectId & "|detail|" & rangeValue & "|" & $untilUnix
  let path = cstring(buildMetricsWindowPath(projectId, metricChartPageSize(rangeValue), rangeValue, untilUnix))
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    if selectedIssue.receivedAtUnix != untilUnix:
      return

    metricsChartLoading = false
    if status == 200:
      let data = parseJson($response)
      projectMetricChartSamples = @[]
      for item in data["metrics"]:
        projectMetricChartSamples.add parseMetric(item)
      metricsChartProjectId = projectId
      metricsChartQueryKey = requestedKey
      metricsChartLastLoadedAt = browserNowMs()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view metrics."
      navigate("/login")
    redraw()
  )

proc loadProjectMembers*(projectId: string) =
  if savedToken().len == 0 or projectId.len == 0:
    return
  if membersLoading:
    return

  membersLoading = true
  let path = cstring("/api/projects/" & projectId & "/members/")
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    membersLoading = false
    if status == 200:
      let data = parseJson($response)
      projectMembers = @[]
      for item in data["members"]:
        projectMembers.add parseProjectMember(item)
      membersProjectId = projectId
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view project members."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
    else:
      authMessage = "Unable to load project members."
    redraw()
  )

proc saveProjectMember*(
  projectId, name, email: string,
  onDone: proc() {.closure.}
) =
  if savedToken().len == 0 or membersSaving:
    return

  membersSaving = true
  let body = $(%* {
    "name": name.strip(),
    "email": email.strip()
  })
  let path = cstring("/api/projects/" & projectId & "/members/")
  ajax(cstring"POST", path, authHeaders(), cstring(body), proc(status: int, response: cstring) =
    membersSaving = false
    if status == 200:
      authMessage = ""
      loadProjectMembers(projectId)
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update project members."
      navigate("/login")
    else:
      try:
        let data = parseJson($response)
        if "error" in data:
          authMessage = data["error"].getStr()
        else:
          authMessage = "Unable to save project member."
      except CatchableError:
        authMessage = "Unable to save project member."
    redraw()
  )

proc inviteUser*(
  name, email: string,
  onDone: proc() {.closure.}
) =
  if savedToken().len == 0 or membersSaving:
    return

  membersSaving = true
  let body = $(%* {
    "name": name.strip(),
    "email": email.strip()
  })
  ajax(cstring"POST", cstring"/api/invites/", authHeaders(), cstring(body), proc(status: int, response: cstring) =
    membersSaving = false
    if status == 200:
      authMessage = ""
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to invite users."
      navigate("/login")
    else:
      try:
        let data = parseJson($response)
        if "error" in data:
          authMessage = data["error"].getStr()
        else:
          authMessage = "Unable to invite user."
      except CatchableError:
        authMessage = "Unable to invite user."
    redraw()
  )

proc removeProjectMember*(projectId, memberId: string) =
  if savedToken().len == 0 or membersSaving:
    return

  membersSaving = true
  let path = cstring("/api/projects/" & projectId & "/members/" & memberId & "/")
  ajax(cstring"DELETE", path, authHeaders(), cstring"", proc(status: int, response: cstring) =
    membersSaving = false
    if status == 200:
      authMessage = ""
      loadProjectMembers(projectId)
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update project members."
      navigate("/login")
    else:
      authMessage = "Unable to remove project member."
    redraw()
  )

proc searchProjectEvents*(search: string) =
  if eventsProjectId.len == 0:
    return
  clearEventSelection()
  let term = search.strip()
  navigateProjectEvents(eventsProjectId, term, 1)
  loadProjectEvents(eventsProjectId, term, 1)

proc searchProjectLogs*(search: string) =
  if logsProjectId.len == 0:
    return
  let term = search.strip()
  navigateProjectLogs(logsProjectId, term, 1)
  loadProjectLogs(logsProjectId, term, 1)

proc searchProjectMetrics*(search: string) =
  if metricsProjectId.len == 0:
    return
  let term = search.strip()
  navigateProjectMetrics(metricsProjectId, term, 1, metricsRange)
  loadProjectMetrics(metricsProjectId, term, 1, metricRange = metricsRange)

proc setProjectMetricsRange*(metricRange: string) =
  if metricsProjectId.len == 0:
    return
  let rangeValue = normalizeMetricRange(metricRange)
  metricsRange = rangeValue
  metricsPage = 1
  metricsQueryKey = ""
  metricsChartQueryKey = ""
  metricsChartLastLoadedAt = 0
  projectMetricChartSamples = @[]
  navigateProjectMetrics(metricsProjectId, metricsSearch, 1, rangeValue)
  loadProjectMetrics(metricsProjectId, metricsSearch, 1, metricRange = rangeValue)
  loadProjectMetricChartSamples(metricsProjectId, metricsSearch, metricRange = rangeValue)

proc goToEventsPage*(page: int) =
  if eventsProjectId.len == 0:
    return
  if page < 1:
    return
  if eventsTotalPages > 0 and page > eventsTotalPages:
    return
  clearEventSelection()
  navigateProjectEvents(eventsProjectId, eventsSearch, page)
  loadProjectEvents(eventsProjectId, eventsSearch, page)

proc goToLogsPage*(page: int) =
  if logsProjectId.len == 0:
    return
  if page < 1:
    return
  if logsTotalPages > 0 and page > logsTotalPages:
    return
  navigateProjectLogs(logsProjectId, logsSearch, page)
  loadProjectLogs(logsProjectId, logsSearch, page)

proc goToMetricsPage*(page: int) =
  if metricsProjectId.len == 0:
    return
  if page < 1:
    return
  if metricsTotalPages > 0 and page > metricsTotalPages:
    return
  navigateProjectMetrics(metricsProjectId, metricsSearch, page, metricsRange)
  loadProjectMetrics(metricsProjectId, metricsSearch, page, metricRange = metricsRange)

proc stopProjectLogsPolling*() =
  logsPolling = false
  logsPollingProjectId = ""
  {.emit: """
    if (window.obisanLogsPoller) {
      clearInterval(window.obisanLogsPoller);
      window.obisanLogsPoller = null;
    }
  """.}

proc stopProjectMetricsPolling*() =
  metricsPolling = false
  metricsPollingProjectId = ""
  {.emit: """
    if (window.obisanMetricsPoller) {
      clearInterval(window.obisanMetricsPoller);
      window.obisanMetricsPoller = null;
    }
  """.}

proc pollProjectLogs*() {.exportc.} =
  if logsPollingProjectId.len == 0 or savedToken().len == 0:
    stopProjectLogsPolling()
    return
  if not logsLoading:
    loadProjectLogs(logsPollingProjectId, logsSearch, logsPage)

proc startProjectLogsPolling*(projectId: string) =
  if savedToken().len == 0 or projectId.len == 0:
    return
  if logsPolling and logsPollingProjectId == projectId:
    return

  stopProjectLogsPolling()
  logsPolling = true
  logsPollingProjectId = projectId
  redraw()
  {.emit: """
    window.obisanLogsPoller = setInterval(function() {
      pollProjectLogs();
    }, 3000);
  """.}

proc pollProjectMetrics*() {.exportc.} =
  if metricsPollingProjectId.len == 0 or savedToken().len == 0:
    stopProjectMetricsPolling()
    return

  if not metricsRefreshInFlight:
    loadProjectMetrics(metricsPollingProjectId, metricsSearch, metricsPage, showLoading = false, metricRange = metricsRange)

  let now = browserNowMs()
  if not metricsChartLoading and now - metricsChartLastLoadedAt >= MetricsChartPollMs:
    loadProjectMetricChartSamples(metricsPollingProjectId, metricsSearch, metricRange = metricsRange)

proc startProjectMetricsPolling*(projectId: string) =
  if savedToken().len == 0 or projectId.len == 0:
    return
  if metricsPolling and metricsPollingProjectId == projectId:
    return

  stopProjectMetricsPolling()
  metricsPolling = true
  metricsPollingProjectId = projectId
  redraw()
  {.emit: """
    window.obisanMetricsPoller = setInterval(function() {
      pollProjectMetrics();
    }, 3000);
  """.}

proc loadProjectUptime*(projectId: string) =
  if savedToken().len == 0:
    return

  uptimeLoading = true
  let path = cstring("/api/projects/" & projectId & "/uptime/")
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    uptimeLoading = false
    if status == 200:
      let data = parseJson($response)
      projectUptimeMonitors = @[]
      for item in data["monitors"]:
        projectUptimeMonitors.add parseUptimeMonitor(item)
      uptimeProjectId = projectId
      uptimeQueryKey = projectId
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view uptime monitors."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
      navigate("/dashboard")
    else:
      authMessage = "Unable to load uptime monitors."
    redraw()
  )

proc loadUptimeChecks*(projectId, monitorId: string, page: int = 1) =
  if savedToken().len == 0 or monitorId.len == 0:
    return

  uptimeChecksLoading = true
  let path = cstring("/api/projects/" & projectId & "/uptime/" & monitorId & "/checks/?page=" & $page)
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    uptimeChecksLoading = false
    if status == 200:
      let data = parseJson($response)
      projectUptimeChecks = @[]
      for item in data["checks"]:
        projectUptimeChecks.add parseUptimeCheck(item)
      uptimeChecksMonitorId = monitorId
      uptimeChecksPage = page
      if "pagination" in data:
        uptimeChecksTotal = data["pagination"]["total"].getInt()
        uptimeChecksTotalPages = data["pagination"]["totalPages"].getInt()
      else:
        uptimeChecksTotal = projectUptimeChecks.len
        uptimeChecksTotalPages = if uptimeChecksTotal > 0: 1 else: 0
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to view uptime checks."
      navigate("/login")
    else:
      authMessage = "Unable to load uptime checks."
    redraw()
  )

proc stopProjectUptimePolling*() =
  uptimePolling = false
  uptimePollingProjectId = ""
  {.emit: """
    if (window.obisanUptimePoller) {
      clearInterval(window.obisanUptimePoller);
      window.obisanUptimePoller = null;
    }
  """.}

proc pollProjectUptime*() {.exportc.} =
  if uptimePollingProjectId.len == 0 or savedToken().len == 0:
    stopProjectUptimePolling()
    return
  if not uptimeLoading:
    loadProjectUptime(uptimePollingProjectId)
  if uptimeChecksMonitorId.len > 0 and not uptimeChecksLoading:
    loadUptimeChecks(uptimePollingProjectId, uptimeChecksMonitorId, uptimeChecksPage)

proc startProjectUptimePolling*(projectId: string) =
  if savedToken().len == 0 or projectId.len == 0:
    return
  if uptimePolling and uptimePollingProjectId == projectId:
    return

  stopProjectUptimePolling()
  uptimePolling = true
  uptimePollingProjectId = projectId
  redraw()
  {.emit: """
    window.obisanUptimePoller = setInterval(function() {
      pollProjectUptime();
    }, 30000);
  """.}

proc createUptimeMonitor*(
  projectId, name, url: string,
  timeoutMs, retryCount, intervalSecs: int,
  onDone: proc() {.closure.}
) =
  if savedToken().len == 0 or url.strip().len == 0:
    authMessage = "Enter a URL to monitor."
    redraw()
    return

  uptimeSaving = true
  let body = $(%* {
    "name": name.strip(),
    "url": url.strip(),
    "timeoutMs": timeoutMs,
    "retryCount": retryCount,
    "intervalSecs": intervalSecs
  })
  let path = cstring("/api/projects/" & projectId & "/uptime/")
  ajax(cstring"POST", path, authHeaders(), cstring(body), proc(status: int, response: cstring) =
    uptimeSaving = false
    if status == 201:
      authMessage = ""
      loadProjectUptime(projectId)
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to create a monitor."
      navigate("/login")
    else:
      try:
        let data = parseJson($response)
        if "error" in data:
          authMessage = data["error"].getStr()
        else:
          authMessage = "Unable to create monitor."
      except CatchableError:
        authMessage = "Unable to create monitor."
    redraw()
  )

proc updateUptimeMonitor*(
  projectId, monitorId: string,
  enabled: bool,
  onDone: proc() {.closure.}
) =
  if savedToken().len == 0:
    return

  uptimeSaving = true
  let body = $(%* {"enabled": enabled})
  let path = cstring("/api/projects/" & projectId & "/uptime/" & monitorId & "/")
  ajax(cstring"PATCH", path, authHeaders(), cstring(body), proc(status: int, response: cstring) =
    uptimeSaving = false
    if status == 200:
      authMessage = ""
      loadProjectUptime(projectId)
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update monitor."
      navigate("/login")
    else:
      authMessage = "Unable to update monitor."
    redraw()
  )

proc deleteUptimeMonitor*(projectId, monitorId: string, onDone: proc() {.closure.}) =
  if savedToken().len == 0:
    return

  uptimeSaving = true
  let path = cstring("/api/projects/" & projectId & "/uptime/" & monitorId & "/")
  ajax(cstring"DELETE", path, authHeaders(), cstring"", proc(status: int, response: cstring) =
    uptimeSaving = false
    if status == 200:
      authMessage = ""
      if uptimeChecksMonitorId == monitorId:
        uptimeChecksMonitorId = ""
        projectUptimeChecks = @[]
      loadProjectUptime(projectId)
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to delete monitor."
      navigate("/login")
    else:
      authMessage = "Unable to delete monitor."
    redraw()
  )

proc isEventSelected*(eventId: string): bool =
  for id in selectedEventIds:
    if id == eventId:
      return true
  false

proc toggleEventSelection*(eventId: string) =
  if isEventSelected(eventId):
    var next: seq[string] = @[]
    for id in selectedEventIds:
      if id != eventId:
        next.add id
    selectedEventIds = next
  else:
    selectedEventIds.add eventId
  redraw()

proc allPageEventsSelected*(): bool =
  if projectEvents.len == 0:
    return false
  for issue in projectEvents:
    if not isEventSelected(issue.eventId):
      return false
  true

proc toggleSelectAllPageEvents*() =
  if allPageEventsSelected():
    clearEventSelection()
  else:
    selectedEventIds = @[]
    for issue in projectEvents:
      selectedEventIds.add issue.eventId
  redraw()

proc deleteSelectedEvents*(projectId: string) =
  if selectedEventIds.len == 0 or eventsDeleting:
    return

  eventsDeleting = true
  let ids = selectedEventIds
  let body = $(%* {"eventIds": ids})
  let path = cstring("/api/projects/" & projectId & "/events/delete/")
  ajax(cstring"POST", path, authHeaders(), cstring(body), proc(status: int, response: cstring) =
    eventsDeleting = false
    if status == 200:
      clearEventSelection()
      authMessage = ""
      if eventsProjectId.len > 0:
        var reloadPage = eventsPage
        if projectEvents.len <= ids.len and eventsPage > 1:
          reloadPage = eventsPage - 1
        navigateProjectEvents(eventsProjectId, eventsSearch, reloadPage)
        loadProjectEvents(eventsProjectId, eventsSearch, reloadPage)
        loadProjects()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to delete issues."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
      navigate("/dashboard")
    else:
      authMessage = "Unable to delete selected issues."
    redraw()
  )

proc deleteProjectEvent*(projectId, eventId: string, onDone: proc() {.closure.}) =
  if projectId.len == 0 or eventId.len == 0:
    return

  let path = cstring("/api/projects/" & projectId & "/events/" & eventId & "/")
  ajax(cstring"DELETE", path, authHeaders(), cstring"", proc(status: int, response: cstring) =
    if status == 200:
      authMessage = ""
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to delete this issue."
      navigate("/login")
    elif status == 404:
      authMessage = "Issue not found."
      navigate("/projects/" & projectId)
    else:
      authMessage = "Unable to delete issue."
    redraw()
  )

proc loadSetupStatus*() =
  ajaxGet(cstring"/api/setup-status/", @[], proc(status: int, response: cstring) =
    setupLoaded = true
    if status == 200:
      let data = parseJson($response)
      needsSetup = data["needsSetup"].getBool()
      if needsSetup:
        clearSession()
        navigate("/register")
      elif savedToken().len > 0:
        loadProfile()
      else:
        navigate("/login")
    else:
      authMessage = "Unable to check setup status."
  )

proc register*(name, email, password: string) =
  if name.len == 0 or email.len == 0 or password.len == 0:
    authMessage = "Fill in name, email, and password."
    return

  authMessage = ""
  let body = $(%* {"name": name, "email": email, "password": password})
  ajaxPost(cstring"/api/register/", jsonHeaders(), cstring(body), proc(status: int, response: cstring) =
    if status == 201:
      let data = parseJson($response)
      setSessionToken(data["token"].getStr())
      needsSetup = false
      loadProfile(true)
    else:
      authMessage = "Registration failed."
  )

proc login*(email, password: string) =
  if email.len == 0 or password.len == 0:
    authMessage = "Fill in email and password."
    return

  authMessage = ""
  let body = $(%* {"email": email, "password": password})
  ajaxPost(cstring"/api/login/", jsonHeaders(), cstring(body), proc(status: int, response: cstring) =
    if status == 200:
      let data = parseJson($response)
      setSessionToken(data["token"].getStr())
      loadProfile(true)
    else:
      authMessage = "Invalid email or password."
  )

proc logout*() =
  clearSession()
  navigate("/login")

proc isHexChar(c: char): bool =
  c in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}

proc isAutoGeneratedSlug(name: string): bool =
  if name.len != 32:
    return false
  for c in name:
    if not isHexChar(c):
      return false
  true

proc projectNameForEdit*(name: string): string =
  if isAutoGeneratedSlug(name):
    ""
  else:
    name

proc displayProjectName*(id, name: string): string =
  if name.len > 0 and not isAutoGeneratedSlug(name):
    name
  else:
    "Project #" & id

proc generateProject*(name: string, onDone: proc() {.closure.}) =
  let trimmed = name.strip()
  if trimmed.len == 0:
    authMessage = "Enter a project name."
    redraw()
    return

  authMessage = ""
  let body = $(%* {"name": trimmed})
  ajaxPost(cstring"/api/generate-project/", authHeaders(), cstring(body), proc(status: int, response: cstring) =
    if status == 200:
      let data = parseJson($response)
      projects = @[parseProject(data)] & projects
      authMessage = ""
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in before creating a project."
      navigate("/login")
    else:
      authMessage = "Unable to create project."
    redraw()
  )

proc updateProjectName*(projectId, name: string, onDone: proc() {.closure.}) =
  let trimmed = name.strip()
  if trimmed.len == 0:
    authMessage = "Enter a project name."
    redraw()
    return

  authMessage = ""
  let body = $(%* {"name": trimmed})
  let path = cstring("/api/projects/" & projectId & "/")
  ajax(cstring"PATCH", path, authHeaders(), cstring(body), proc(status: int, response: cstring) =
    if status == 200:
      let data = parseJson($response)
      for i, project in projects:
        if project.id == projectId:
          projects[i] = parseProject(data)
          break
      authMessage = ""
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update this project."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
    else:
      authMessage = "Unable to update project."
    redraw()
  )

proc updateProjectWebhookUrl*(projectId, webhookUrl: string, onDone: proc() {.closure.}) =
  let trimmed = webhookUrl.strip()
  authMessage = ""
  let body = $(%* {"webhookUrl": trimmed})
  let path = cstring("/api/projects/" & projectId & "/")
  ajax(cstring"PATCH", path, authHeaders(), cstring(body), proc(status: int, response: cstring) =
    if status == 200:
      let data = parseJson($response)
      for i, project in projects:
        if project.id == projectId:
          projects[i] = parseProject(data)
          break
      authMessage = ""
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update this project."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
    else:
      try:
        let data = parseJson($response)
        if "error" in data:
          authMessage = data["error"].getStr()
        else:
          authMessage = "Unable to update webhook."
      except CatchableError:
        authMessage = "Unable to update webhook."
    onDone()
    redraw()
  )

proc updateProjectEmailSettings*(projectId: string, emailEnabled: bool, emailToAddrs: string, onDone: proc() {.closure.}) =
  authMessage = ""
  let body = $(%* {
    "emailEnabled": emailEnabled,
    "emailToAddrs": emailToAddrs.strip()
  })
  let path = cstring("/api/projects/" & projectId & "/")
  ajax(cstring"PATCH", path, authHeaders(), cstring(body), proc(status: int, response: cstring) =
    if status == 200:
      let data = parseJson($response)
      for i, project in projects:
        if project.id == projectId:
          projects[i] = parseProject(data)
          break
      authMessage = ""
      onDone()
    elif status == 401:
      clearSession()
      authMessage = "Sign in to update this project."
      navigate("/login")
    elif status == 404:
      authMessage = "Project not found."
    else:
      try:
        let data = parseJson($response)
        if "error" in data:
          authMessage = data["error"].getStr()
        else:
          authMessage = "Unable to update email settings."
      except CatchableError:
        authMessage = "Unable to update email settings."
    redraw()
  )
