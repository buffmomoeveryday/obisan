include karax/prelude

import options
import algorithm
import math
import strutils
import tables
import kraut
import ../utils/auth
import ../components/layout

type LogMetricSeries = object
  name: string
  unit: string
  latest: float
  maxValue: float
  values: seq[float]
  times: seq[string]

type LogMetricPanel = object
  title: string
  series: seq[LogMetricSeries]

var logsMetricRange = "10m"

proc ensureLogsPage(projectId: string, qryParams: Table[string, string]) =
  if metricsPollingProjectId.len > 0:
    stopProjectMetricsPolling()
  if uptimePollingProjectId.len > 0:
    stopProjectUptimePolling()

  if savedToken().len == 0:
    navigate("/login")
    return

  bootstrapSession()

  if profileLoading or projectsLoading or not projectsLoaded:
    return

  if findProject(projectId).isNone:
    return

  let urlSearch = qryParams.getOrDefault("search", "")
  let urlPage = parseEventsPageParam(qryParams.getOrDefault("page", ""))

  if logsProjectId != projectId:
    logsProjectId = projectId
    logsSearch = urlSearch
    logsSearchDraft = urlSearch
    logsPage = urlPage
    logsQueryKey = ""
  elif logsSearch != urlSearch or logsPage != urlPage:
    logsSearch = urlSearch
    logsSearchDraft = urlSearch
    logsPage = urlPage
    logsQueryKey = ""

  let queryKey = projectId & "|" & logsSearch & "|" & $logsPage
  if logsQueryKey != queryKey and not logsLoading:
    loadProjectLogs(projectId, logsSearch, logsPage)

  startProjectLogsPolling(projectId)

proc logLevelClass(level: string): string =
  case level.toLowerAscii()
  of "error", "fatal":
    "bg-red-100 text-red-800"
  of "warning", "warn":
    "bg-amber-100 text-amber-800"
  of "info":
    "bg-blue-100 text-blue-800"
  of "debug":
    "bg-violet-100 text-violet-800"
  of "trace":
    "bg-slate-100 text-slate-700"
  else:
    "bg-slate-100 text-slate-700"

proc setLogsMetricRange(metricRange: string) =
  logsMetricRange = normalizeMetricRange(metricRange)
  metricsProjectId = logsProjectId
  metricsSearch = ""
  metricsRange = logsMetricRange
  metricsChartQueryKey = ""
  metricsChartLastLoadedAt = 0
  projectMetricChartSamples = @[]
  loadProjectMetricChartSamples(logsProjectId, "", metricRange = logsMetricRange)

proc logMetricValue(metric: Metric): Option[float] =
  try:
    some(parseFloat(metric.value))
  except ValueError:
    none[float]()

proc logMetricLabel(name: string): string =
  case name
  of "system.cpu.usage_percent":
    "CPU"
  of "system.ram.usage_percent":
    "Memory"
  of "system.load.1":
    "Load 1"
  of "system.load.5":
    "Load 5"
  of "system.load.15":
    "Load 15"
  else:
    name

proc logMetricColor(name: string): string =
  case name
  of "system.load.1":
    "#22c55e"
  of "system.load.5":
    "#facc15"
  of "system.load.15":
    "#38bdf8"
  else:
    "#38bdf8"

proc logMetricTimeLabel(value: string): string =
  let parts = value.split(' ')
  if parts.len >= 2 and parts[1].len >= 5:
    parts[1][0 .. 4]
  else:
    value

proc buildLogMetricSeries(name: string): Option[LogMetricSeries] =
  var values: seq[float] = @[]
  var times: seq[string] = @[]
  var unit = ""
  for metric in projectMetricChartSamples:
    if metric.name != name:
      continue
    let value = metric.logMetricValue()
    if value.isNone:
      continue
    if unit.len == 0:
      unit = metric.unit
    values.add value.get
    times.add logMetricTimeLabel(metric.receivedAt)

  if values.len == 0:
    return none[LogMetricSeries]()

  values.reverse()
  times.reverse()
  var maxValue = values[0]
  for value in values:
    if value > maxValue:
      maxValue = value

  some(LogMetricSeries(
    name: name,
    unit: unit,
    latest: values[^1],
    maxValue: maxValue,
    values: values,
    times: times
  ))

proc buildLogMetricPanel(title: string, names: openArray[string]): Option[LogMetricPanel] =
  var panel = LogMetricPanel(title: title, series: @[])
  for name in names:
    let series = buildLogMetricSeries(name)
    if series.isSome:
      panel.series.add series.get
  if panel.series.len == 0:
    none[LogMetricPanel]()
  else:
    some(panel)

proc logMetricPanels(): seq[LogMetricPanel] =
  for panel in [
    buildLogMetricPanel("CPU", ["system.cpu.usage_percent"]),
    buildLogMetricPanel("Load", ["system.load.1", "system.load.5", "system.load.15"]),
    buildLogMetricPanel("Memory", ["system.ram.usage_percent"])
  ]:
    if panel.isSome:
      result.add panel.get

proc logNiceMax(value: float): float =
  if value <= 1:
    1
  elif value <= 5:
    5
  elif value <= 10:
    10
  elif value <= 20:
    20
  elif value <= 40:
    40
  elif value <= 100:
    100
  else:
    let magnitude = pow(10.0, floor(log10(value)))
    ceil(value / magnitude) * magnitude

proc logSvgNum(value: float): string =
  $(round(value * 100) / 100)

proc logPanelMax(panel: LogMetricPanel): float =
  result = 0
  for series in panel.series:
    if series.maxValue > result:
      result = series.maxValue
  result = logNiceMax(result * 1.15)

proc logChartX(index, count: int): float =
  if count <= 1:
    34
  else:
    34 + (index.float / (count - 1).float) * 286

proc logChartY(value, maxValue: float): float =
  let clamped =
    if maxValue <= 0:
      0.0
    elif value < 0:
      0.0
    elif value > maxValue:
      maxValue
    else:
      value
  110 - (clamped / maxValue) * 86

proc logLinePath(series: LogMetricSeries, maxValue: float): string =
  for index, value in series.values:
    let point = logSvgNum(logChartX(index, series.values.len)) & " " & logSvgNum(logChartY(value, maxValue))
    if index == 0:
      result = "M " & point
    else:
      result &= " L " & point

proc logMetricChartSvg(panel: LogMetricPanel): string =
  let maxValue = panel.logPanelMax()
  result = "<svg class=\"h-36 w-full\" viewBox=\"0 0 340 128\" preserveAspectRatio=\"none\" role=\"img\">"
  result &= "<rect x=\"0\" y=\"0\" width=\"340\" height=\"128\" fill=\"#ffffff\"/>"
  for i in 0 .. 3:
    let y = 24 + i.float * 28.6
    result &= "<line x1=\"34\" y1=\"" & logSvgNum(y) & "\" x2=\"320\" y2=\"" & logSvgNum(y) & "\" stroke=\"#e2e8f0\" stroke-width=\"1\"/>"
  for series in panel.series:
    result &= "<path d=\"" & logLinePath(series, maxValue) & "\" fill=\"none\" stroke=\"" & logMetricColor(series.name) & "\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
  result &= "</svg>"

proc renderLoadingState(title, message: string): VNode =
  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader(title, message)
    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
        text message

proc render*(context: Context): VNode =
  let projectId = context.urlParams.getOrDefault("id", "")
  if projectId.len == 0:
    navigate("/dashboard")

  ensureLogsPage(projectId, context.qryParams)

  if savedToken().len == 0:
    return renderLoadingState("Logs", "Redirecting...")

  if profileLoading or projectsLoading or not projectsLoaded:
    return renderLoadingState("Logs", "Loading project...")

  let project = findProject(projectId)
  if project.isNone:
    return renderLoadingState("Logs", "Project not found")

  let currentProject = project.get
  let projectName = displayProjectName(projectId, currentProject.name)
  let metricPanels = logMetricPanels()

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Logs", projectName)

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv(class="min-w-0 flex-1"):
          a(class="text-sm text-pink-700 hover:underline", href="#/dashboard"):
            text "Back to projects"
          h2(class="mt-2 text-2xl font-semibold"):
            text projectName
          if currentProject.dsn.len > 0:
            p(class="mt-2 break-all font-mono text-xs text-slate-600"):
              text currentProject.dsn
        tdiv(class="flex flex-wrap gap-2"):
          button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
            text "Copy DSN"
            proc onclick(ev: Event; n: VNode) =
              copyText(currentProject.dsn)

      tdiv(class="mb-5 border-b border-slate-200"):
        nav(class="-mb-px flex gap-5 text-sm"):
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectEventsHref(projectId, eventsSearch, eventsPage)):
            text "Issues"
          a(class="border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700", href=projectLogsHref(projectId, logsSearch, logsPage)):
            text "Logs"
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectMetricsHref(projectId, metricsSearch, metricsPage)):
            text "Metrics"
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectUptimeHref(projectId)):
            text "Uptime"

      tdiv(class="mb-4 grid gap-2 md:grid-cols-[minmax(0,1fr)_auto_auto] md:items-end"):
        tdiv(class="min-w-0"):
          label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
            text "Search logs"
          input(
            class="w-full rounded border border-slate-300 px-3 py-2 text-sm",
            placeholder="Search message, level, trace id, event id...",
            `type`="text",
            value=logsSearchDraft
          ):
            proc oninput(ev: Event; n: VNode) =
              logsSearchDraft = $n.value
        button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
          text "Search"
          proc onclick(ev: Event; n: VNode) =
            searchProjectLogs(logsSearchDraft)
        if logsSearch.len > 0:
          button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
            text "Clear"
            proc onclick(ev: Event; n: VNode) =
              logsSearchDraft = ""
              searchProjectLogs("")

      tdiv(class="mb-3 flex flex-wrap items-center justify-between gap-2"):
        if not logsLoading and logsTotal > 0:
          p(class="text-sm text-slate-600"):
            text "Page " & $logsPage & " of " & $logsTotalPages & " · " & $logsTotal & " logs"
            if logsSearch.len > 0:
              text " matching \"" & logsSearch & "\""
        else:
          span()
        span(class="text-sm"):
          if logsPolling:
            span(class="text-emerald-700"):
              text "Polling"
          else:
            span(class="text-slate-500"):
              text "Paused"

      tdiv(class="grid gap-4"):
        tdiv(class="min-w-0"):
          if logsLoading:
            tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
              text "Loading logs..."
          elif projectLogs.len == 0:
            tdiv(class="rounded border border-slate-200 bg-white p-8 text-center"):
              p(class="text-lg font-medium"):
                if logsSearch.len > 0:
                  text "No matching logs"
                else:
                  text "No logs yet"
              p(class="mt-2 text-sm text-slate-500"):
                if logsSearch.len > 0:
                  text "Try a different search term or clear the filter."
                else:
                  text "Send structured logs from your Sentry SDK with logging enabled."
          else:
            tdiv(class="overflow-hidden rounded border border-slate-200 bg-white"):
              tdiv(class="overflow-x-auto"):
                table(class="min-w-full text-left text-sm"):
                  thead(class="border-b border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500"):
                    tr:
                      th(class="px-4 py-3 font-medium"):
                        text "Level"
                      th(class="px-4 py-3 font-medium"):
                        text "Message"
                      th(class="px-4 py-3 font-medium"):
                        text "Received"
                      th(class="px-4 py-3 font-medium"):
                        text "Event ID"
                  tbody:
                    for log in projectLogs:
                      let issuePath = issueDetailHref(projectId, log.eventId)
                      tr(class="border-b border-slate-100 last:border-0 hover:bg-slate-50"):
                        td(class="px-4 py-3"):
                          span(class="rounded px-2 py-1 text-xs font-medium " & logLevelClass(log.level)):
                            text log.level
                        td(class="px-4 py-3 text-slate-800"):
                          a(class="block hover:text-pink-700", href=issuePath):
                            text log.message
                        td(class="whitespace-nowrap px-4 py-3 text-slate-500"):
                          text log.receivedAt
                        td(class="px-4 py-3 font-mono text-xs text-slate-500"):
                          a(class="hover:text-pink-700", href=issuePath):
                            text log.eventId

            if logsTotalPages > 1:
              tdiv(class="mt-4 flex flex-wrap items-center justify-between gap-3"):
                button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
                  text "Previous"
                  proc onclick(ev: Event; n: VNode) =
                    if logsPage > 1:
                      goToLogsPage(logsPage - 1)
                span(class="text-sm text-slate-600"):
                  text "Page " & $logsPage & " of " & $logsTotalPages
                button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
                  text "Next"
                  proc onclick(ev: Event; n: VNode) =
                    if logsPage < logsTotalPages:
                      goToLogsPage(logsPage + 1)

        aside(class="hidden"):
          tdiv(class="rounded border border-slate-200 bg-white p-3"):
            tdiv(class="mb-3 flex flex-wrap items-center justify-between gap-2"):
              h3(class="text-sm font-semibold text-slate-900"):
                text "Metrics"
              span(class="text-xs text-slate-500"):
                text metricRangeLabel(logsMetricRange)
            tdiv(class="mb-3 flex flex-wrap gap-1"):
              button(
                class=(
                  if logsMetricRange == "1m":
                    "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700"
                  else:
                    "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50"
                )
              ):
                text "1m"
                proc onclick(ev: Event; n: VNode) =
                  setLogsMetricRange("1m")
              button(
                class=(
                  if logsMetricRange == "5m":
                    "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700"
                  else:
                    "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50"
                )
              ):
                text "5m"
                proc onclick(ev: Event; n: VNode) =
                  setLogsMetricRange("5m")
              button(
                class=(
                  if logsMetricRange == "10m":
                    "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700"
                  else:
                    "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50"
                )
              ):
                text "10m"
                proc onclick(ev: Event; n: VNode) =
                  setLogsMetricRange("10m")
            if metricsChartLoading and metricPanels.len == 0:
              p(class="py-8 text-center text-sm text-slate-500"):
                text "Loading metrics..."
            elif metricPanels.len == 0:
              p(class="py-8 text-center text-sm text-slate-500"):
                text "No metrics in this window."
            else:
              tdiv(class="space-y-2"):
                for panel in metricPanels:
                  tdiv(class="rounded border border-slate-100 p-2"):
                    tdiv(class="mb-1 flex flex-wrap items-center justify-between gap-2"):
                      h4(class="text-xs font-semibold text-slate-900"):
                        text panel.title
                      tdiv(class="flex flex-wrap gap-2 text-xs text-slate-600"):
                        for series in panel.series:
                          span:
                            text logMetricLabel(series.name) & " " & $(round(series.latest * 100) / 100)
                    verbatim logMetricChartSvg(panel)

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
