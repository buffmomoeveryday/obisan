include karax/prelude

import options
import strutils
import tables
import kraut
import ../utils/auth
import ../components/layout

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

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Logs", projectName)

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv(class="min-w-0 flex-1"):
          a(class="text-sm text-pink-700 hover:underline", href="#/dashboard"):
            text "← Back to projects"
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

      tdiv(class="mb-4 flex flex-wrap items-end gap-2"):
        tdiv(class="min-w-0 flex-1"):
          label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
            text "Search logs"
          input(
            class="w-full max-w-xl rounded border border-slate-300 px-3 py-2 text-sm",
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

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
