include karax/prelude

import options
import algorithm
import math
import strutils
import tables
import kraut
import ../utils/auth
import ../components/layout

type MetricSeries = object
  name: string
  unit: string
  latest: float
  minValue: float
  maxValue: float
  values: seq[float]
  times: seq[string]

type ChartPanel = object
  title: string
  names: seq[string]
  series: seq[MetricSeries]

const KnownChartMetricNames = [
  "system.cpu.usage_percent",
  "system.load.1",
  "system.load.5",
  "system.load.15",
  "system.ram.usage_percent",
  "system.disk.io.read_bytes_per_second",
  "system.disk.io.write_bytes_per_second",
  "system.disk.usage_percent"
]

proc metricValue(metric: Metric): Option[float] =
  try:
    some(parseFloat(metric.value))
  except ValueError:
    none[float]()

proc formatMetricValue(value: float, unit: string): string =
  let absValue = abs(value)
  let formatted =
    if absValue >= 1_000_000_000:
      $(round(value / 1_000_000_000 * 10) / 10) & "B"
    elif absValue >= 1_000_000:
      $(round(value / 1_000_000 * 10) / 10) & "M"
    elif absValue >= 1_000:
      $(round(value / 1_000 * 10) / 10) & "K"
    elif absValue >= 100:
      $round(value)
    else:
      $(round(value * 100) / 100)
  if unit.len > 0:
    formatted & " " & unit
  else:
    formatted

proc shortMetricLabel(name: string): string =
  case name
  of "system.cpu.usage_percent":
    "CPU"
  of "system.ram.usage_percent":
    "Memory"
  of "system.disk.usage_percent":
    "Disk"
  of "system.load.1":
    "Load 1"
  of "system.load.5":
    "Load 5"
  of "system.load.15":
    "Load 15"
  of "system.disk.io.read_bytes_per_second":
    "Read"
  of "system.disk.io.write_bytes_per_second":
    "Write"
  else:
    name

proc metricStroke(name: string): string =
  case name
  of "system.cpu.usage_percent":
    "#38bdf8"
  of "system.ram.usage_percent":
    "#38bdf8"
  of "system.disk.usage_percent":
    "#f59e0b"
  of "system.load.1":
    "#22c55e"
  of "system.load.5":
    "#facc15"
  of "system.load.15":
    "#38bdf8"
  of "system.disk.io.read_bytes_per_second":
    "#38bdf8"
  of "system.disk.io.write_bytes_per_second":
    "#a855f7"
  else:
    "#475569"

proc metricDotClass(name: string): string =
  case name
  of "system.cpu.usage_percent", "system.ram.usage_percent", "system.load.15",
      "system.disk.io.read_bytes_per_second":
    "bg-sky-400"
  of "system.load.1":
    "bg-green-500"
  of "system.load.5", "system.disk.usage_percent":
    "bg-yellow-400"
  of "system.disk.io.write_bytes_per_second":
    "bg-purple-500"
  else:
    "bg-slate-500"

proc metricFill(name: string): string =
  case name
  of "system.load.1":
    "#dcfce7"
  of "system.disk.usage_percent":
    "#fef3c7"
  of "system.disk.io.write_bytes_per_second":
    "#f3e8ff"
  else:
    "#e0f2fe"

proc metricDarkFill(name: string): string =
  case name
  of "system.load.1":
    "#14532d"
  of "system.disk.usage_percent":
    "#713f12"
  of "system.disk.io.write_bytes_per_second":
    "#581c87"
  else:
    "#0c4a6e"

proc isKnownChartMetric(name: string): bool =
  for knownName in KnownChartMetricNames:
    if name == knownName:
      return true
  false

proc metricTimeLabel(value: string): string =
  let parts = value.split(' ')
  if parts.len >= 2 and parts[1].len >= 5:
    parts[1][0 .. 4]
  else:
    value

proc buildSeries(name: string): Option[MetricSeries] =
  var values: seq[float] = @[]
  var times: seq[string] = @[]
  var unit = ""
  for metric in projectMetricChartSamples:
    if metric.name != name:
      continue
    let value = metric.metricValue()
    if value.isNone:
      continue
    if unit.len == 0:
      unit = metric.unit
    values.add value.get
    times.add metricTimeLabel(metric.receivedAt)

  if values.len == 0:
    return none[MetricSeries]()

  values.reverse()
  times.reverse()
  var minValue = values[0]
  var maxValue = values[0]
  for value in values:
    if value < minValue:
      minValue = value
    if value > maxValue:
      maxValue = value

  some(MetricSeries(
    name: name,
    unit: unit,
    latest: values[^1],
    minValue: minValue,
    maxValue: maxValue,
    values: values,
    times: times
  ))

proc buildPanel(title: string, names: openArray[string]): Option[ChartPanel] =
  var panel = ChartPanel(title: title, names: @[], series: @[])
  for name in names:
    panel.names.add name
    let series = buildSeries(name)
    if series.isSome:
      panel.series.add series.get
  if panel.series.len == 0:
    none[ChartPanel]()
  else:
    some(panel)

proc chartPanels(): seq[ChartPanel] =
  for panel in [
    buildPanel("CPU %", ["system.cpu.usage_percent"]),
    buildPanel("Load (1/5/15)", ["system.load.1", "system.load.5", "system.load.15"]),
    buildPanel("Memory", ["system.ram.usage_percent"]),
    buildPanel("Disk I/O", ["system.disk.io.read_bytes_per_second", "system.disk.io.write_bytes_per_second"]),
    buildPanel("Disk Usage", ["system.disk.usage_percent"])
  ]:
    if panel.isSome:
      result.add panel.get

  var customNames: seq[string] = @[]
  for metric in projectMetricChartSamples:
    if metric.name.isKnownChartMetric():
      continue
    if metric.metricValue().isNone:
      continue
    if customNames.find(metric.name) < 0:
      customNames.add metric.name

  customNames.sort(system.cmp[string])
  for name in customNames:
    let panel = buildPanel(shortMetricLabel(name), [name])
    if panel.isSome:
      result.add panel.get

proc niceMax(value: float): float =
  if value <= 1:
    1
  elif value <= 2:
    2
  elif value <= 5:
    5
  elif value <= 10:
    10
  elif value <= 20:
    20
  elif value <= 40:
    40
  elif value <= 60:
    60
  elif value <= 100:
    100
  else:
    let magnitude = pow(10.0, floor(log10(value)))
    ceil(value / magnitude) * magnitude

proc svgNum(value: float): string =
  $(round(value * 100) / 100)

proc panelMax(panel: ChartPanel): float =
  result = 0
  for series in panel.series:
    if series.maxValue > result:
      result = series.maxValue
  result = niceMax(result * 1.15)

proc chartX(index, count: int): float =
  if count <= 1:
    52
  else:
    52 + (index.float / (count - 1).float) * 918

proc chartY(value, maxValue: float): float =
  let clamped =
    if maxValue <= 0:
      0.0
    elif value < 0:
      0.0
    elif value > maxValue:
      maxValue
    else:
      value
  188 - (clamped / maxValue) * 150

proc linePath(series: MetricSeries, maxValue: float): string =
  for index, value in series.values:
    let point = svgNum(chartX(index, series.values.len)) & " " & svgNum(chartY(value, maxValue))
    if index == 0:
      result = "M " & point
    else:
      result &= " L " & point

proc areaPath(series: MetricSeries, maxValue: float): string =
  if series.values.len == 0:
    return ""
  result = linePath(series, maxValue)
  result &= " L " & svgNum(chartX(series.values.len - 1, series.values.len)) & " 188"
  result &= " L " & svgNum(chartX(0, series.values.len)) & " 188 Z"

proc chartSvg(panel: ChartPanel): string =
  let maxValue = panel.panelMax()
  let bgColor = if darkMode: "#17131f" else: "#ffffff"
  let gridColor = if darkMode: "#3a3347" else: "#e2e8f0"
  let minorGridColor = if darkMode: "#2a2533" else: "#eef2f7"
  let axisTextColor = if darkMode: "#c4b7d2" else: "#64748b"
  let timeTextColor = if darkMode: "#d9cfe4" else: "#475569"
  let areaOpacity = if darkMode: "0.34" else: "0.82"
  result = "<svg class=\"h-56 w-full\" viewBox=\"0 0 1000 220\" preserveAspectRatio=\"none\" role=\"img\">"
  result &= "<rect x=\"0\" y=\"0\" width=\"1000\" height=\"220\" fill=\"" & bgColor & "\"/>"
  for i in 0 .. 4:
    let y = 38 + i.float * 37.5
    let labelValue = maxValue - (i.float / 4.0) * maxValue
    result &= "<line x1=\"52\" y1=\"" & svgNum(y) & "\" x2=\"970\" y2=\"" & svgNum(y) & "\" stroke=\"" & gridColor & "\" stroke-width=\"1\"/>"
    result &= "<text x=\"12\" y=\"" & svgNum(y + 4) & "\" fill=\"" & axisTextColor & "\" font-size=\"11\">" & svgNum(labelValue) & "</text>"
  for i in 0 .. 8:
    let x = 52 + i.float * 114.75
    result &= "<line x1=\"" & svgNum(x) & "\" y1=\"38\" x2=\"" & svgNum(x) & "\" y2=\"188\" stroke=\"" & minorGridColor & "\" stroke-width=\"1\"/>"
  if panel.series.len > 0:
    let fillColor = if darkMode: metricDarkFill(panel.series[0].name) else: metricFill(panel.series[0].name)
    result &= "<path d=\"" & areaPath(panel.series[0], maxValue) & "\" fill=\"" & fillColor & "\" fill-opacity=\"" & areaOpacity & "\"/>"
  for series in panel.series:
    result &= "<path d=\"" & linePath(series, maxValue) & "\" fill=\"none\" stroke=\"" & metricStroke(series.name) & "\" stroke-width=\"2.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
  let labelSeries = panel.series[0]
  let labelStep =
    if labelSeries.times.len <= 1:
      1
    else:
      max(1, labelSeries.times.len div 6)
  for index, label in labelSeries.times:
    if index mod labelStep == 0 or index == labelSeries.times.len - 1:
      result &= "<text x=\"" & svgNum(chartX(index, labelSeries.times.len) - 14) & "\" y=\"210\" fill=\"" & timeTextColor & "\" font-size=\"11\">" & label & "</text>"
  result &= "</svg>"

proc ensureMetricsPage(projectId: string, qryParams: Table[string, string]) =
  if logsPollingProjectId.len > 0:
    stopProjectLogsPolling()
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
  let urlRange = normalizeMetricRange(qryParams.getOrDefault("range", DefaultMetricRange))

  if metricsProjectId != projectId:
    metricsProjectId = projectId
    metricsSearch = urlSearch
    metricsSearchDraft = urlSearch
    metricsRange = urlRange
    metricsPage = urlPage
    metricsQueryKey = ""
    metricsChartQueryKey = ""
    metricsChartLastLoadedAt = 0
  elif metricsSearch != urlSearch or metricsPage != urlPage or metricsRange != urlRange:
    metricsSearch = urlSearch
    metricsSearchDraft = urlSearch
    metricsRange = urlRange
    metricsPage = urlPage
    metricsQueryKey = ""
    metricsChartQueryKey = ""
    metricsChartLastLoadedAt = 0

  let queryKey = projectId & "|" & metricsSearch & "|" & metricsRange & "|" & $metricsPage
  if metricsQueryKey != queryKey and not metricsRefreshInFlight:
    loadProjectMetrics(projectId, metricsSearch, metricsPage, metricRange = metricsRange)

  let chartQueryKey = projectId & "|" & metricsSearch & "|" & metricsRange
  if metricsChartQueryKey != chartQueryKey and not metricsChartLoading:
    loadProjectMetricChartSamples(projectId, metricsSearch, metricRange = metricsRange)

  startProjectMetricsPolling(projectId)

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

  ensureMetricsPage(projectId, context.qryParams)

  if savedToken().len == 0:
    return renderLoadingState("Metrics", "Redirecting...")

  if profileLoading or projectsLoading or not projectsLoaded:
    return renderLoadingState("Metrics", "Loading project...")

  let project = findProject(projectId)
  if project.isNone:
    return renderLoadingState("Metrics", "Project not found")

  let currentProject = project.get
  let projectName = displayProjectName(projectId, currentProject.name)
  let charts = chartPanels()

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Metrics", projectName)

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv(class="min-w-0 flex-1"):
          a(class="text-sm text-pink-700 hover:underline", href="#/dashboard"):
            text "Back to projects"
          h2(class="mt-2 text-2xl font-semibold"):
            text projectName
          if currentProject.publicKey.len > 0:
            p(class="mt-2 break-all font-mono text-xs text-slate-600"):
              text "POST /api/projects/" & projectId & "/metrics/ with X-Obisan-Key: " & currentProject.publicKey

      tdiv(class="mb-5 border-b border-slate-200"):
        nav(class="-mb-px flex gap-5 text-sm"):
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectEventsHref(projectId, eventsSearch, eventsPage)):
            text "Issues"
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectLogsHref(projectId, logsSearch, logsPage)):
            text "Logs"
          a(class="border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700", href=projectMetricsHref(projectId, metricsSearch, metricsPage)):
            text "Metrics"
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectUptimeHref(projectId)):
            text "Uptime"

      tdiv(class="mb-4 flex flex-wrap items-center justify-between gap-2"):
        tdiv(class="flex flex-wrap items-center gap-1"):
          button(
            class=(
              if metricsRange == "1h":
                "rounded border border-pink-600 bg-pink-50 px-3 py-2 text-sm font-medium text-pink-700"
              else:
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
            )
          ):
            text "1h"
            proc onclick(ev: Event; n: VNode) =
              setProjectMetricsRange("1h")
          button(
            class=(
              if metricsRange == "24h":
                "rounded border border-pink-600 bg-pink-50 px-3 py-2 text-sm font-medium text-pink-700"
              else:
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
            )
          ):
            text "24h"
            proc onclick(ev: Event; n: VNode) =
              setProjectMetricsRange("24h")
          button(
            class=(
              if metricsRange == "7d":
                "rounded border border-pink-600 bg-pink-50 px-3 py-2 text-sm font-medium text-pink-700"
              else:
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
            )
          ):
            text "7d"
            proc onclick(ev: Event; n: VNode) =
              setProjectMetricsRange("7d")
          button(
            class=(
              if metricsRange == "14d":
                "rounded border border-pink-600 bg-pink-50 px-3 py-2 text-sm font-medium text-pink-700"
              else:
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
            )
          ):
            text "14d"
            proc onclick(ev: Event; n: VNode) =
              setProjectMetricsRange("14d")
          button(
            class=(
              if metricsRange == "30d":
                "rounded border border-pink-600 bg-pink-50 px-3 py-2 text-sm font-medium text-pink-700"
              else:
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
            )
          ):
            text "1mo"
            proc onclick(ev: Event; n: VNode) =
              setProjectMetricsRange("30d")
          button(
            class=(
              if metricsRange == "all":
                "rounded border border-pink-600 bg-pink-50 px-3 py-2 text-sm font-medium text-pink-700"
              else:
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
            )
          ):
            text "All"
            proc onclick(ev: Event; n: VNode) =
              setProjectMetricsRange("all")
        span(class="text-sm text-slate-600"):
          text metricRangeLabel(metricsRange)

      tdiv(class="mb-3 flex flex-wrap items-center justify-between gap-2"):
        if not metricsLoading and metricsTotal > 0:
          p(class="text-sm text-slate-600"):
            text $metricsTotal & " metrics"
        else:
          span()
        span(class="text-sm"):
          if metricsPolling:
            span(class="text-emerald-700"):
              text "Polling"
          else:
            span(class="text-slate-500"):
              text "Paused"

      if metricsLoading:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
          text "Loading metrics..."
      elif projectMetrics.len == 0:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center"):
          p(class="text-lg font-medium"):
            text "No metrics yet"
          p(class="mt-2 text-sm text-slate-500"):
            text "Send CPU, memory, disk, or other system samples from your sidecar."
      else:
        if charts.len > 0:
          tdiv(class="mb-5 space-y-2"):
            for panel in charts:
              tdiv(class="overflow-hidden rounded border border-slate-200 bg-white"):
                tdiv(class="flex flex-wrap items-center justify-between gap-3 border-b border-slate-100 px-3 py-2"):
                  tdiv(class="min-w-0"):
                    h3(class="text-sm font-semibold text-slate-900"):
                      text panel.title
                    p(class="mt-0.5 text-xs text-slate-500"):
                      if metricsChartLoading:
                        text "Refreshing samples"
                      else:
                        text $panel.series[0].values.len & " samples"
                  tdiv(class="flex flex-wrap items-center gap-3 text-xs text-slate-600"):
                    for series in panel.series:
                      span(class="inline-flex items-center gap-1"):
                        span(
                          class="inline-block h-2.5 w-2.5 rounded-full " & metricDotClass(series.name)
                        )
                        span:
                          text shortMetricLabel(series.name)
                        span(class="font-mono text-slate-900"):
                          text formatMetricValue(series.latest, series.unit)
                tdiv(class="px-2 py-2"):
                  verbatim chartSvg(panel)
        elif metricsChartLoading:
          tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
            text "Loading chart samples..."
        else:
          tdiv(class="rounded border border-slate-200 bg-white p-8 text-center"):
            p(class="text-lg font-medium"):
              text "No chartable metrics"
            p(class="mt-2 text-sm text-slate-500"):
              text "Charts are shown for metrics with numeric values."

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
