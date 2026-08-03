include karax/prelude

import options
import strutils
import tables
import kraut
import ../utils/auth
import ../components/layout

var newMonitorName = ""
var newMonitorUrl = ""
var newMonitorTimeout = "5000"
var newMonitorRetries = "2"
var newMonitorInterval = "60"
var selectedMonitorId = ""
var showAddMonitorModal = false

proc ensureUptimePage(projectId: string) =
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

  if findProject(projectId).isNone:
    return

  if uptimeProjectId != projectId:
    uptimeProjectId = projectId
    uptimeQueryKey = ""
    selectedMonitorId = ""

  if uptimeQueryKey != projectId and not uptimeLoading:
    loadProjectUptime(projectId)

  startProjectUptimePolling(projectId)

proc uptimeStatusClass(status: string): string =
  case status.toLowerAscii()
  of "up":
    "bg-emerald-100 text-emerald-800"
  of "down":
    "bg-red-100 text-red-800"
  else:
    "bg-slate-100 text-slate-700"

proc renderLoadingState(title, message: string): VNode =
  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader(title, message)
    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
        text message

proc renderProjectTabs(projectId, projectName: string, active: string): VNode =
  buildHtml(tdiv):
    tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
      tdiv(class="min-w-0 flex-1"):
        a(class="text-sm text-pink-700 hover:underline", href="#/dashboard"):
          text "Back to projects"
        h2(class="mt-2 text-2xl font-semibold"):
          text projectName
    tdiv(class="mb-5 border-b border-slate-200"):
      nav(class="-mb-px flex flex-wrap gap-5 text-sm"):
        a(
          class=(if active == "issues": "border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700" else: "border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950"),
          href=projectEventsHref(projectId, eventsSearch, eventsPage)
        ):
          text "Issues"
        a(
          class=(if active == "logs": "border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700" else: "border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950"),
          href=projectLogsHref(projectId, logsSearch, logsPage)
        ):
          text "Logs"
        a(
          class=(if active == "metrics": "border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700" else: "border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950"),
          href=projectMetricsHref(projectId, metricsSearch, metricsPage)
        ):
          text "Metrics"
        a(
          class=(if active == "uptime": "border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700" else: "border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950"),
          href=projectUptimeHref(projectId)
        ):
          text "Uptime"

proc render*(context: Context): VNode =
  let projectId = context.urlParams.getOrDefault("id", "")
  if projectId.len == 0:
    navigate("/dashboard")

  ensureUptimePage(projectId)

  if savedToken().len == 0:
    return renderLoadingState("Uptime", "Redirecting...")

  if profileLoading or projectsLoading or not projectsLoaded:
    return renderLoadingState("Uptime", "Loading project...")

  let project = findProject(projectId)
  if project.isNone:
    return renderLoadingState("Uptime", "Project not found")

  let projectName = displayProjectName(projectId, project.get.name)

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Uptime", projectName)

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      renderProjectTabs(projectId, projectName, "uptime")

      tdiv(class="mb-3 flex items-center justify-between gap-2"):
        h3(class="text-lg font-semibold"):
          text "Monitors"
        tdiv(class="flex flex-wrap items-center gap-3"):
          if uptimePolling:
            span(class="text-sm text-slate-500"):
              text "Auto-refreshing every 30s"
          button(class="rounded bg-pink-600 px-4 py-2 text-sm font-medium text-white hover:bg-pink-500"):
            text "Add monitor"
            proc onclick(ev: Event; n: VNode) =
              showAddMonitorModal = true
              redraw()

      if uptimeLoading and projectUptimeMonitors.len == 0:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
          text "Loading monitors..."
      elif projectUptimeMonitors.len == 0:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center"):
          p(class="text-lg font-medium"):
            text "No uptime monitors yet"
          p(class="mt-2 text-sm text-slate-500"):
            text "Add a URL above to start checking availability."
      else:
        tdiv(class="space-y-4"):
          for monitor in projectUptimeMonitors:
            let item = monitor
            let isSelected = selectedMonitorId == item.id
            tdiv(class="overflow-hidden rounded border border-slate-200 bg-white"):
              tdiv(class="flex flex-wrap items-start justify-between gap-3 p-4"):
                tdiv(class="min-w-0 flex-1"):
                  tdiv(class="flex flex-wrap items-center gap-2"):
                    span(class="rounded px-2 py-1 text-xs font-medium " & uptimeStatusClass(item.lastStatus)):
                      text item.lastStatus
                    if not item.enabled:
                      span(class="rounded bg-slate-100 px-2 py-1 text-xs text-slate-600"):
                        text "paused"
                    h4(class="font-medium"):
                      text item.name
                  p(class="mt-1 break-all font-mono text-xs text-slate-600"):
                    text item.url
                  p(class="mt-2 text-sm text-slate-500"):
                    if item.lastCheckedAt.len > 0:
                      text "Last checked " & item.lastCheckedAt
                      if item.lastResponseMs > 0:
                        text " · " & $item.lastResponseMs & "ms"
                      if item.lastStatusCode > 0:
                        text " · HTTP " & $item.lastStatusCode
                    else:
                      text "Not checked yet"
                  if item.lastError.len > 0 and item.lastStatus == "down":
                    p(class="mt-1 text-sm text-red-700"):
                      text item.lastError
                  p(class="mt-1 text-xs text-slate-500"):
                    text "Timeout " & $item.timeoutMs & "ms · Retries " & $item.retryCount & " · Every " & $item.intervalSecs & "s"
                tdiv(class="flex flex-wrap gap-2"):
                  button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
                    if isSelected:
                      text "Hide checks"
                    else:
                      text "View checks"
                    proc onclick(ev: Event; n: VNode) =
                      if isSelected:
                        selectedMonitorId = ""
                        uptimeChecksMonitorId = ""
                        projectUptimeChecks = @[]
                      else:
                        selectedMonitorId = item.id
                        loadUptimeChecks(projectId, item.id, 1)
                      redraw()
                  button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
                    if item.enabled:
                      text "Pause"
                    else:
                      text "Resume"
                    proc onclick(ev: Event; n: VNode) =
                      if not uptimeSaving:
                        updateUptimeMonitor(projectId, item.id, not item.enabled, proc() = discard)
                  button(class="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 hover:bg-red-100"):
                    text "Delete"
                    proc onclick(ev: Event; n: VNode) =
                      if not uptimeSaving:
                        deleteUptimeMonitor(projectId, item.id, proc() =
                          if selectedMonitorId == item.id:
                            selectedMonitorId = ""
                        )

              if isSelected:
                tdiv(class="border-t border-slate-200 bg-slate-50 p-4"):
                  if uptimeChecksLoading and projectUptimeChecks.len == 0:
                    p(class="text-sm text-slate-500"):
                      text "Loading checks..."
                  elif projectUptimeChecks.len == 0:
                    p(class="text-sm text-slate-500"):
                      text "No checks recorded yet."
                  else:
                    tdiv(class="overflow-x-auto"):
                      table(class="min-w-full text-left text-sm"):
                        thead(class="text-xs uppercase tracking-wide text-slate-500"):
                          tr:
                            th(class="px-3 py-2 font-medium"):
                              text "Status"
                            th(class="px-3 py-2 font-medium"):
                              text "Response"
                            th(class="px-3 py-2 font-medium"):
                              text "Code"
                            th(class="px-3 py-2 font-medium"):
                              text "Checked"
                            th(class="px-3 py-2 font-medium"):
                              text "Error"
                        tbody:
                          for check in projectUptimeChecks:
                            tr(class="border-t border-slate-200"):
                              td(class="px-3 py-2"):
                                span(class="rounded px-2 py-1 text-xs font-medium " & uptimeStatusClass(check.status)):
                                  text check.status
                              td(class="px-3 py-2 text-slate-600"):
                                text $check.responseMs & "ms"
                              td(class="px-3 py-2 text-slate-600"):
                                if check.statusCode > 0:
                                  text $check.statusCode
                                else:
                                  text "—"
                              td(class="px-3 py-2 whitespace-nowrap text-slate-600"):
                                text check.checkedAt
                              td(class="px-3 py-2 text-slate-600"):
                                text check.error

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    if showAddMonitorModal:
      tdiv(class="fixed inset-0 z-40 flex items-center justify-center bg-slate-950/60 px-4 py-6"):
        tdiv(class="w-full max-w-2xl rounded border border-slate-200 bg-white p-5 shadow-xl"):
          tdiv(class="mb-4 flex items-start justify-between gap-3"):
            tdiv:
              h3(class="text-lg font-semibold"):
                text "Add monitor"
              p(class="mt-1 text-sm text-slate-600"):
                text "Probe an HTTP endpoint on a schedule. Alerts go to the project ntfy topic on status changes."
            button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
              text "Close"
              proc onclick(ev: Event; n: VNode) =
                if not uptimeSaving:
                  showAddMonitorModal = false
                  redraw()
          tdiv(class="grid gap-3 md:grid-cols-2"):
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "Name"
              input(
                class="w-full rounded border border-slate-300 px-3 py-2 text-sm",
                placeholder="e.g. API health",
                `type`="text",
                value=newMonitorName
              ):
                proc oninput(ev: Event; n: VNode) =
                  newMonitorName = $n.value
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "URL"
              input(
                class="w-full rounded border border-slate-300 px-3 py-2 text-sm font-mono",
                placeholder="https://example.com/health",
                `type`="url",
                value=newMonitorUrl
              ):
                proc oninput(ev: Event; n: VNode) =
                  newMonitorUrl = $n.value
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "Timeout (ms)"
              input(
                class="w-full rounded border border-slate-300 px-3 py-2 text-sm",
                placeholder="5000",
                `type`="number",
                value=newMonitorTimeout
              ):
                proc oninput(ev: Event; n: VNode) =
                  newMonitorTimeout = $n.value
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "Retries"
              input(
                class="w-full rounded border border-slate-300 px-3 py-2 text-sm",
                placeholder="2",
                `type`="number",
                value=newMonitorRetries
              ):
                proc oninput(ev: Event; n: VNode) =
                  newMonitorRetries = $n.value
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "Check interval (seconds)"
              input(
                class="w-full rounded border border-slate-300 px-3 py-2 text-sm",
                placeholder="60",
                `type`="number",
                value=newMonitorInterval
              ):
                proc oninput(ev: Event; n: VNode) =
                  newMonitorInterval = $n.value
          tdiv(class="mt-5 flex justify-end gap-2"):
            button(class="rounded border border-slate-300 bg-white px-4 py-2 text-sm hover:bg-slate-50"):
              text "Cancel"
              proc onclick(ev: Event; n: VNode) =
                if not uptimeSaving:
                  showAddMonitorModal = false
                  redraw()
            button(class="rounded bg-pink-600 px-4 py-2 text-sm font-medium text-white hover:bg-pink-500"):
              if uptimeSaving:
                text "Saving..."
              else:
                text "Add monitor"
              proc onclick(ev: Event; n: VNode) =
                if uptimeSaving:
                  return
                var timeoutMs = 5000
                var retryCount = 2
                var intervalSecs = 60
                try:
                  timeoutMs = parseInt(newMonitorTimeout.strip())
                except ValueError:
                  discard
                try:
                  retryCount = parseInt(newMonitorRetries.strip())
                except ValueError:
                  discard
                try:
                  intervalSecs = parseInt(newMonitorInterval.strip())
                except ValueError:
                  discard
                createUptimeMonitor(projectId, newMonitorName, newMonitorUrl, timeoutMs, retryCount, intervalSecs, proc() =
                  newMonitorName = ""
                  newMonitorUrl = ""
                  newMonitorTimeout = "5000"
                  newMonitorRetries = "2"
                  newMonitorInterval = "60"
                  showAddMonitorModal = false
                )

    renderCopyFeedback()
