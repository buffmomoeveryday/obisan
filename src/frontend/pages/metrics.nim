include karax/prelude

import options
import strutils
import tables
import kraut
import ../utils/auth
import ../components/layout

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

  if metricsProjectId != projectId:
    metricsProjectId = projectId
    metricsSearch = urlSearch
    metricsSearchDraft = urlSearch
    metricsPage = urlPage
    metricsQueryKey = ""
  elif metricsSearch != urlSearch or metricsPage != urlPage:
    metricsSearch = urlSearch
    metricsSearchDraft = urlSearch
    metricsPage = urlPage
    metricsQueryKey = ""

  let queryKey = projectId & "|" & metricsSearch & "|" & $metricsPage
  if metricsQueryKey != queryKey and not metricsLoading:
    loadProjectMetrics(projectId, metricsSearch, metricsPage)

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

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Metrics", projectName)

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv(class="min-w-0 flex-1"):
          a(class="text-sm text-pink-700 hover:underline", href="#/dashboard"):
            text "← Back to projects"
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

      tdiv(class="mb-4 flex flex-wrap items-end gap-2"):
        tdiv(class="min-w-0 flex-1"):
          label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
            text "Search metrics"
          input(
            class="w-full max-w-xl rounded border border-slate-300 px-3 py-2 text-sm",
            placeholder="Search name, type, unit, tags...",
            `type`="text",
            value=metricsSearchDraft
          ):
            proc oninput(ev: Event; n: VNode) =
              metricsSearchDraft = $n.value
        button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
          text "Search"
          proc onclick(ev: Event; n: VNode) =
            searchProjectMetrics(metricsSearchDraft)
        if metricsSearch.len > 0:
          button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
            text "Clear"
            proc onclick(ev: Event; n: VNode) =
              metricsSearchDraft = ""
              searchProjectMetrics("")

      tdiv(class="mb-3 flex flex-wrap items-center justify-between gap-2"):
        if not metricsLoading and metricsTotal > 0:
          p(class="text-sm text-slate-600"):
            text "Page " & $metricsPage & " of " & $metricsTotalPages & " · " & $metricsTotal & " metrics"
            if metricsSearch.len > 0:
              text " matching \"" & metricsSearch & "\""
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
            if metricsSearch.len > 0:
              text "No matching metrics"
            else:
              text "No metrics yet"
          p(class="mt-2 text-sm text-slate-500"):
            if metricsSearch.len > 0:
              text "Try a different search term or clear the filter."
            else:
              text "Send CPU, memory, disk, or other system samples from your sidecar."
      else:
        tdiv(class="overflow-hidden rounded border border-slate-200 bg-white"):
          tdiv(class="overflow-x-auto"):
            table(class="min-w-full text-left text-sm"):
              thead(class="border-b border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500"):
                tr:
                  th(class="px-4 py-3 font-medium"):
                    text "Name"
                  th(class="px-4 py-3 font-medium"):
                    text "Type"
                  th(class="px-4 py-3 font-medium"):
                    text "Value"
                  th(class="px-4 py-3 font-medium"):
                    text "Unit"
                  th(class="px-4 py-3 font-medium"):
                    text "Tags"
                  th(class="px-4 py-3 font-medium"):
                    text "Received"
              tbody:
                for metric in projectMetrics:
                  tr(class="border-b border-slate-100 last:border-0 hover:bg-slate-50"):
                    td(class="px-4 py-3 font-medium text-slate-800"):
                      text metric.name
                    td(class="px-4 py-3 text-slate-500"):
                      text metric.metricType
                    td(class="px-4 py-3 font-mono text-xs text-slate-800"):
                      text metric.value
                    td(class="px-4 py-3 text-slate-500"):
                      text metric.unit
                    td(class="px-4 py-3 font-mono text-xs text-slate-500"):
                      text metric.tags
                    td(class="whitespace-nowrap px-4 py-3 text-slate-500"):
                      text metric.receivedAt

        if metricsTotalPages > 1:
          tdiv(class="mt-4 flex flex-wrap items-center justify-between gap-3"):
            button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
              text "Previous"
              proc onclick(ev: Event; n: VNode) =
                if metricsPage > 1:
                  goToMetricsPage(metricsPage - 1)
            span(class="text-sm text-slate-600"):
              text "Page " & $metricsPage & " of " & $metricsTotalPages
            button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
              text "Next"
              proc onclick(ev: Event; n: VNode) =
                if metricsPage < metricsTotalPages:
                  goToMetricsPage(metricsPage + 1)

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
