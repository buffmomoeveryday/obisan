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

const EventsPageSize* = 20

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
  metricsPage* = 1
  metricsTotal* = 0
  metricsTotalPages* = 0
  metricsQueryKey* = ""
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
  issueDetailLoading* = false
  issueDetailLoadedFor* = ""
  currentUser* = AuthUser()
  projects* = newSeq[Project]()
  projectEvents* = newSeq[Issue]()
  projectLogs* = newSeq[Issue]()
  breadcrumbLogs* = newSeq[Issue]()
  projectMetrics* = newSeq[Metric]()
  projectUptimeMonitors* = newSeq[UptimeMonitor]()
  projectUptimeChecks* = newSeq[UptimeCheck]()
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
  metricsPage = 1
  metricsTotal = 0
  metricsTotalPages = 0
  metricsQueryKey = ""
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
  projectUptimeMonitors = @[]
  projectUptimeChecks = @[]
  issueDetailLoadedFor = ""
  projectLogs = @[]
  breadcrumbLogs = @[]
  projectMetrics = @[]
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

proc projectMetricsHash*(projectId: string, search: string = "", page: int = 1): string =
  result = "/projects/" & projectId & "/metrics"
  var parts: seq[string] = @[]
  if search.len > 0:
    parts.add "search=" & encodeQueryComponent(search)
  if page > 1:
    parts.add "page=" & $page
  if parts.len > 0:
    result &= "?" & parts.join("&")

proc projectMetricsHref*(projectId: string, search: string = "", page: int = 1): string =
  "#" & projectMetricsHash(projectId, search, page)

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

proc navigateProjectMetrics*(projectId: string, search: string = "", page: int = 1) =
  setHash(cstring(projectMetricsHash(projectId, search, page)))

proc buildEventsPath(projectId: string, search: string, page, pageSize: int): string =
  result = "/api/projects/" & projectId & "/events/?page=" & $page & "&pageSize=" & $pageSize
  if search.len > 0:
    result &= "&search=" & encodeQueryComponent(search)

proc buildLogsPath(projectId: string, search: string, page, pageSize: int): string =
  result = "/api/projects/" & projectId & "/logs/?page=" & $page & "&pageSize=" & $pageSize
  if search.len > 0:
    result &= "&search=" & encodeQueryComponent(search)

proc buildMetricsPath(projectId: string, search: string, page, pageSize: int): string =
  result = "/api/projects/" & projectId & "/metrics/?page=" & $page & "&pageSize=" & $pageSize
  if search.len > 0:
    result &= "&search=" & encodeQueryComponent(search)

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

proc loadProjectMetrics*(projectId: string, search: string = "", page: int = 1, pageSize: int = EventsPageSize) =
  if savedToken().len == 0:
    return

  metricsLoading = true
  let path = cstring(buildMetricsPath(projectId, search, page, pageSize))
  ajaxGet(path, authHeaders(), proc(status: int, response: cstring) =
    metricsLoading = false
    if status == 200:
      let data = parseJson($response)
      projectMetrics = @[]
      for item in data["metrics"]:
        projectMetrics.add parseMetric(item)
      metricsProjectId = projectId
      metricsSearch = search
      metricsPage = page
      if "pagination" in data:
        metricsTotal = data["pagination"]["total"].getInt()
        metricsTotalPages = data["pagination"]["totalPages"].getInt()
      else:
        metricsTotal = projectMetrics.len
        metricsTotalPages = if metricsTotal > 0: 1 else: 0
      metricsQueryKey = projectId & "|" & search & "|" & $page
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
  navigateProjectMetrics(metricsProjectId, term, 1)
  loadProjectMetrics(metricsProjectId, term, 1)

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
  navigateProjectMetrics(metricsProjectId, metricsSearch, page)
  loadProjectMetrics(metricsProjectId, metricsSearch, page)

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
  if not metricsLoading:
    loadProjectMetrics(metricsPollingProjectId, metricsSearch, metricsPage)

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
