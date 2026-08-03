include karax/prelude

import options
import algorithm
import math
import strutils
import kraut
import ../utils/auth
import ../components/layout

var deletingIssue = false
var issueMetricRange = "10m"

type DetailMetricSeries = object
  name: string
  latest: float
  maxValue: float
  values: seq[float]

proc setIssueMetricRange(projectId: string, untilUnix: int64, metricRange: string) =
  issueMetricRange = normalizeMetricRange(metricRange)
  metricsChartQueryKey = ""
  projectMetricChartSamples = @[]
  loadProjectMetricChartWindowSamples(projectId, untilUnix, issueMetricRange)

proc detailMetricValue(metric: Metric): Option[float] =
  try:
    some(parseFloat(metric.value))
  except ValueError:
    none[float]() 

proc detailMetricLabel(name: string): string =
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

proc detailMetricColor(name: string): string =
  case name
  of "system.load.1":
    "#22c55e"
  of "system.load.5":
    "#facc15"
  of "system.load.15":
    "#38bdf8"
  else:
    "#38bdf8"

proc buildDetailMetricSeries(name: string): Option[DetailMetricSeries] =
  var values: seq[float] = @[]
  for metric in projectMetricChartSamples:
    if metric.name != name:
      continue
    let value = metric.detailMetricValue()
    if value.isSome:
      values.add value.get
  if values.len == 0:
    return none[DetailMetricSeries]()
  values.reverse()
  var maxValue = values[0]
  for value in values:
    if value > maxValue:
      maxValue = value
  some(DetailMetricSeries(name: name, latest: values[^1], maxValue: maxValue, values: values))

proc detailSvgNum(value: float): string =
  $(round(value * 100) / 100)

proc detailChartX(index, count: int): float =
  if count <= 1:
    42
  else:
    42 + (index.float / (count - 1).float) * 318

proc detailChartY(value, maxValue: float): float =
  let limit = if maxValue <= 0: 1.0 else: maxValue * 1.15
  132 - (min(value, limit) / limit) * 104

proc detailLinePath(series: DetailMetricSeries): string =
  for index, value in series.values:
    let point = detailSvgNum(detailChartX(index, series.values.len)) & " " & detailSvgNum(detailChartY(value, series.maxValue))
    if index == 0:
      result = "M " & point
    else:
      result &= " L " & point

proc detailMetricChartSvg(series: DetailMetricSeries): string =
  result = "<svg class=\"h-40 w-full\" viewBox=\"0 0 380 156\" preserveAspectRatio=\"none\" role=\"img\">"
  result &= "<rect x=\"0\" y=\"0\" width=\"380\" height=\"156\" fill=\"#ffffff\"/>"
  for i in 0 .. 3:
    let y = 28 + i.float * 34.6
    result &= "<line x1=\"42\" y1=\"" & detailSvgNum(y) & "\" x2=\"360\" y2=\"" & detailSvgNum(y) & "\" stroke=\"#e2e8f0\" stroke-width=\"1\"/>"
  result &= "<path d=\"" & detailLinePath(series) & "\" fill=\"none\" stroke=\"" & detailMetricColor(series.name) & "\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
  result &= "</svg>"

proc issueLevelClass(level: string): string =
  case level.toLowerAscii()
  of "error", "fatal":
    "bg-red-100 text-red-800"
  of "warning":
    "bg-amber-100 text-amber-800"
  of "info":
    "bg-blue-100 text-blue-800"
  else:
    "bg-slate-100 text-slate-700"

proc ensureIssuePage(projectId, eventId: string) =
  if logsPollingProjectId.len > 0:
    stopProjectLogsPolling()
  if metricsPollingProjectId.len > 0:
    stopProjectMetricsPolling()

  if savedToken().len == 0:
    navigate("/login")
    return

  bootstrapSession()

  if profileLoading or projectsLoading or not projectsLoaded:
    return

  let viewKey = projectId & ":" & eventId
  if issueDetailLoadedFor != viewKey and not issueDetailLoading:
    loadIssueDetail(projectId, eventId)
  if isBreadcrumbLogEventId(eventId):
    if breadcrumbLogsLoadedFor != viewKey and not breadcrumbLogsLoading:
      loadBreadcrumbLogs(projectId, eventId)
  else:
    breadcrumbLogs = @[]
    breadcrumbLogsLoadedFor = ""
    breadcrumbLogsBaseEventId = ""

proc renderLoadingState(title, message: string): VNode =
  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader(title, message)
    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
        text message

proc render*(context: Context): VNode =
  let projectId = context.urlParams.getOrDefault("id", "")
  let eventId = context.urlParams.getOrDefault("eventId", "")
  if projectId.len == 0 or eventId.len == 0:
    navigate("/dashboard")

  ensureIssuePage(projectId, eventId)

  if savedToken().len == 0:
    return renderLoadingState("Issue", "Redirecting...")

  if profileLoading or projectsLoading or not projectsLoaded:
    return renderLoadingState("Issue", "Loading issue...")

  let project = findProject(projectId)
  let projectLabel =
    if project.isSome:
      displayProjectName(projectId, project.get.name)
    else:
      "Project #" & projectId

  let viewKey = projectId & ":" & eventId
  let issueReady = selectedIssue.eventId == eventId and issueDetailLoadedFor == viewKey
  if issueReady and selectedIssue.receivedAtUnix > 0:
    let metricKey = projectId & "|detail|" & issueMetricRange & "|" & $selectedIssue.receivedAtUnix
    if metricsChartQueryKey != metricKey and not metricsChartLoading:
      loadProjectMetricChartWindowSamples(projectId, selectedIssue.receivedAtUnix, issueMetricRange)

  var detailMetrics: seq[DetailMetricSeries] = @[]
  if issueReady:
    for name in ["system.cpu.usage_percent", "system.load.1", "system.load.5", "system.load.15", "system.ram.usage_percent"]:
      let series = buildDetailMetricSeries(name)
      if series.isSome:
        detailMetrics.add series.get

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Issue", projectLabel)

    tdiv(class="mx-auto max-w-7xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv:
          if isBreadcrumbLogEventId(eventId):
            a(class="text-sm text-pink-700 hover:underline", href=projectLogsHref(projectId, logsSearch, logsPage)):
              text "Back to logs"
          else:
            a(class="text-sm text-pink-700 hover:underline", href=projectEventsHref(projectId, eventsSearch, eventsPage)):
              text "Back to issues"
          h2(class="mt-2 text-2xl font-semibold"):
            if issueDetailLoading or not issueReady:
              text "Loading issue..."
            elif selectedIssue.errorType.len > 0:
              text selectedIssue.errorType
            else:
              text "Issue"
        if issueReady and not issueDetailLoading:
          button(class="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 hover:bg-red-100"):
            if deletingIssue:
              text "Deleting..."
            else:
              text "Delete issue"
            proc onclick(ev: Event; n: VNode) =
              if not deletingIssue:
                deletingIssue = true
                deleteProjectEvent(projectId, eventId, proc() =
                  deletingIssue = false
                  loadProjects()
                  navigateProjectEvents(projectId, eventsSearch, eventsPage)
                )

      if issueDetailLoading or not issueReady:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
          text "Loading issue details..."
      else:
        tdiv(class=(if isBreadcrumbLogEventId(eventId): "grid gap-4 lg:grid-cols-[minmax(0,1fr)_24rem]" else: "space-y-4")):
          tdiv(class="space-y-4"):
            tdiv(class="rounded border border-slate-200 bg-white p-4"):
              tdiv(class="flex flex-wrap items-center gap-3"):
                span(class="rounded px-2 py-1 text-xs font-medium " & issueLevelClass(selectedIssue.level)):
                  text selectedIssue.level
                span(class="text-sm text-slate-500"):
                  text selectedIssue.platform
                span(class="text-sm text-slate-500"):
                  text selectedIssue.receivedAt
              p(class="mt-4 text-lg font-medium text-slate-900"):
                text selectedIssue.message
              p(class="mt-2 break-all font-mono text-xs text-slate-500"):
                text "Event ID: "
                text selectedIssue.eventId

            if not isBreadcrumbLogEventId(eventId):
              tdiv(class="rounded border border-slate-200 bg-white p-4"):
                h3(class="text-sm font-semibold uppercase tracking-wide text-slate-500"):
                  text "Stack trace"
                if selectedIssue.stacktrace.len > 0:
                  pre(class="mt-4 overflow-x-auto rounded bg-slate-950 p-4 font-mono text-xs leading-6 text-slate-100"):
                    text selectedIssue.stacktrace
                else:
                  p(class="mt-4 text-sm text-slate-500"):
                    text "No stack trace was captured for this event."
                  p(class="mt-2 text-sm text-slate-500"):
                    text "Older events may not include a traceback. Run your app again and open the newest issue in the list."

            if not isBreadcrumbLogEventId(eventId):
              tdiv(class="rounded border border-slate-200 bg-white p-4"):
                tdiv(class="mb-3 flex flex-wrap items-center justify-between gap-2"):
                  h3(class="text-sm font-semibold uppercase tracking-wide text-slate-500"):
                    text "Metrics near this event"
                  span(class="text-xs text-slate-500"):
                    text metricRangeLabel(issueMetricRange)
                tdiv(class="mb-3 flex flex-wrap gap-1"):
                  button(class=(if issueMetricRange == "1m": "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700" else: "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50")):
                    text "1m"
                    proc onclick(ev: Event; n: VNode) =
                      setIssueMetricRange(projectId, selectedIssue.receivedAtUnix, "1m")
                  button(class=(if issueMetricRange == "5m": "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700" else: "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50")):
                    text "5m"
                    proc onclick(ev: Event; n: VNode) =
                      setIssueMetricRange(projectId, selectedIssue.receivedAtUnix, "5m")
                  button(class=(if issueMetricRange == "10m": "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700" else: "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50")):
                    text "10m"
                    proc onclick(ev: Event; n: VNode) =
                      setIssueMetricRange(projectId, selectedIssue.receivedAtUnix, "10m")
                if metricsChartLoading and detailMetrics.len == 0:
                  p(class="py-8 text-center text-sm text-slate-500"):
                    text "Loading metrics..."
                elif detailMetrics.len == 0:
                  p(class="py-8 text-center text-sm text-slate-500"):
                    text "No metrics in this window."
                else:
                  tdiv(class="grid gap-3 lg:grid-cols-2"):
                    for series in detailMetrics:
                      tdiv(class="rounded border border-slate-100 p-3"):
                        tdiv(class="mb-1 flex flex-wrap items-center justify-between gap-2"):
                          h4(class="text-xs font-semibold text-slate-900"):
                            text detailMetricLabel(series.name)
                          span(class="text-xs text-slate-600"):
                            text $(round(series.latest * 100) / 100)
                        verbatim detailMetricChartSvg(series)

          if isBreadcrumbLogEventId(eventId):
            aside(class="space-y-4 lg:sticky lg:top-6 lg:self-start"):
              tdiv(class="rounded border border-slate-200 bg-white p-4"):
                tdiv(class="mb-3 flex flex-wrap items-center justify-between gap-2"):
                  h3(class="text-sm font-semibold uppercase tracking-wide text-slate-500"):
                    text "Metrics near this log"
                  span(class="text-xs text-slate-500"):
                    text metricRangeLabel(issueMetricRange)
                tdiv(class="mb-3 flex flex-wrap gap-1"):
                  button(class=(if issueMetricRange == "1m": "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700" else: "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50")):
                    text "1m"
                    proc onclick(ev: Event; n: VNode) =
                      setIssueMetricRange(projectId, selectedIssue.receivedAtUnix, "1m")
                  button(class=(if issueMetricRange == "5m": "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700" else: "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50")):
                    text "5m"
                    proc onclick(ev: Event; n: VNode) =
                      setIssueMetricRange(projectId, selectedIssue.receivedAtUnix, "5m")
                  button(class=(if issueMetricRange == "10m": "rounded border border-pink-600 bg-pink-50 px-2.5 py-1.5 text-xs font-medium text-pink-700" else: "rounded border border-slate-300 bg-white px-2.5 py-1.5 text-xs text-slate-700 hover:bg-slate-50")):
                    text "10m"
                    proc onclick(ev: Event; n: VNode) =
                      setIssueMetricRange(projectId, selectedIssue.receivedAtUnix, "10m")
                if metricsChartLoading and detailMetrics.len == 0:
                  p(class="py-8 text-center text-sm text-slate-500"):
                    text "Loading metrics..."
                elif detailMetrics.len == 0:
                  p(class="py-8 text-center text-sm text-slate-500"):
                    text "No metrics in this window."
                else:
                  tdiv(class="space-y-3"):
                    for series in detailMetrics:
                      tdiv(class="rounded border border-slate-100 p-3"):
                        tdiv(class="mb-1 flex flex-wrap items-center justify-between gap-2"):
                          h4(class="text-xs font-semibold text-slate-900"):
                            text detailMetricLabel(series.name)
                          span(class="text-xs text-slate-600"):
                            text $(round(series.latest * 100) / 100)
                        verbatim detailMetricChartSvg(series)

              tdiv(class="rounded border border-slate-200 bg-white p-4"):
                tdiv(class="mb-3"):
                  h3(class="text-sm font-semibold uppercase tracking-wide text-slate-500"):
                    text "Breadcrumbs"
                  if breadcrumbLogsBaseEventId.len > 0:
                    p(class="mt-1 break-all font-mono text-xs text-slate-500"):
                      text breadcrumbLogsBaseEventId
                if breadcrumbLogsLoading:
                  p(class="text-sm text-slate-500"):
                    text "Loading breadcrumbs..."
                elif breadcrumbLogs.len == 0:
                  p(class="text-sm text-slate-500"):
                    text "No related breadcrumbs were found."
                else:
                  tdiv(class="max-h-[24rem] space-y-2 overflow-y-auto pr-1"):
                    for breadcrumb in breadcrumbLogs:
                      let active = breadcrumb.eventId == eventId
                      a(
                        class=(if active: "block rounded border border-pink-200 bg-pink-50 p-3" else: "block rounded border border-slate-200 p-3 hover:border-pink-200 hover:bg-pink-50"),
                        href=issueDetailHref(projectId, breadcrumb.eventId)
                      ):
                        tdiv(class="flex items-center justify-between gap-2"):
                          span(class="rounded px-2 py-1 text-xs font-medium " & issueLevelClass(breadcrumb.level)):
                            text breadcrumb.level
                          span(class="whitespace-nowrap text-xs text-slate-500"):
                            text breadcrumb.receivedAt
                        p(class="mt-2 line-clamp-2 text-sm font-medium text-slate-800"):
                          text breadcrumb.message
                        p(class="mt-2 break-all font-mono text-[11px] text-slate-500"):
                          text breadcrumb.eventId

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
