include karax/prelude

import options
import strutils
import tables
import kraut
import ../utils/auth
import ../components/layout

var editingProjectName = false
var projectNameDraft = ""
var savingProjectName = false

proc ensureProjectPage(projectId: string, qryParams: Table[string, string]) =
  if logsPollingProjectId.len > 0:
    stopProjectLogsPolling()
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

  if eventsProjectId != projectId:
    eventsProjectId = projectId
    eventsSearch = urlSearch
    eventsSearchDraft = urlSearch
    eventsPage = urlPage
    eventsQueryKey = ""
    clearEventSelection()
  elif eventsSearch != urlSearch or eventsPage != urlPage:
    eventsSearch = urlSearch
    eventsSearchDraft = urlSearch
    eventsPage = urlPage
    eventsQueryKey = ""
    clearEventSelection()

  let queryKey = projectId & "|" & eventsSearch & "|" & $eventsPage
  if eventsQueryKey != queryKey and not eventsLoading:
    loadProjectEvents(projectId, eventsSearch, eventsPage)

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

  ensureProjectPage(projectId, context.qryParams)

  if savedToken().len == 0:
    return renderLoadingState("Issues", "Redirecting...")

  if profileLoading or projectsLoading or not projectsLoaded:
    return renderLoadingState("Issues", "Loading project...")

  let project = findProject(projectId)
  if project.isNone:
    return renderLoadingState("Issues", "Project not found")

  let currentProject = project.get
  let dsn = currentProject.dsn
  let ntfyUrl = currentProject.ntfyUrl
  let ntfyTopic = currentProject.ntfyTopic
  let projectName = displayProjectName(projectId, currentProject.name)
  let renameDraftSeed = projectNameForEdit(currentProject.name)

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Issues", projectName)

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv(class="min-w-0 flex-1"):
          a(class="text-sm text-pink-700 hover:underline", href="#/dashboard"):
            text "← Back to projects"
          if editingProjectName:
            tdiv(class="mt-3 flex flex-wrap items-end gap-2"):
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "Project name"
                input(
                  class="w-72 rounded border border-slate-300 px-3 py-2 text-sm",
                  placeholder="Project name",
                  `type`="text",
                  value=projectNameDraft
                ):
                  proc oninput(ev: Event; n: VNode) =
                    projectNameDraft = $n.value
              button(class="rounded bg-pink-600 px-3 py-2 text-sm font-medium text-white hover:bg-pink-500"):
                if savingProjectName:
                  text "Saving..."
                else:
                  text "Save"
                proc onclick(ev: Event; n: VNode) =
                  if not savingProjectName:
                    savingProjectName = true
                    updateProjectName(projectId, projectNameDraft, proc() =
                      savingProjectName = false
                      editingProjectName = false
                    )
              button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
                text "Cancel"
                proc onclick(ev: Event; n: VNode) =
                  editingProjectName = false
                  projectNameDraft = renameDraftSeed
          else:
            h2(class="mt-2 text-2xl font-semibold"):
              text projectName
            button(class="mt-2 text-sm text-pink-700 hover:underline"):
              text "Rename project"
              proc onclick(ev: Event; n: VNode) =
                editingProjectName = true
                projectNameDraft = renameDraftSeed
          if dsn.len > 0:
            p(class="mt-2 break-all font-mono text-xs text-slate-600"):
              text dsn
          if ntfyUrl.len > 0:
            p(class="mt-2 text-sm text-slate-600"):
              text "Push alerts: subscribe to "
              span(class="font-mono text-xs"):
                text ntfyTopic
              text " on ntfy.sh (topic updates when you rename the project)."
        tdiv(class="flex flex-wrap gap-2"):
          button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
            text "Copy DSN"
            proc onclick(ev: Event; n: VNode) =
              copyText(dsn)
          if ntfyTopic.len > 0:
            button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
              text "Copy ntfy topic"
              proc onclick(ev: Event; n: VNode) =
                copyText(ntfyTopic)

      tdiv(class="mb-5 border-b border-slate-200"):
        nav(class="-mb-px flex gap-5 text-sm"):
          a(class="border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700", href=projectEventsHref(projectId, eventsSearch, eventsPage)):
            text "Issues"
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectLogsHref(projectId, logsSearch, logsPage)):
            text "Logs"
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectMetricsHref(projectId, metricsSearch, metricsPage)):
            text "Metrics"
          a(class="border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950", href=projectUptimeHref(projectId)):
            text "Uptime"

      tdiv(class="mb-4 flex flex-wrap items-end gap-2"):
        tdiv(class="min-w-0 flex-1"):
          label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
            text "Search issues"
          input(
            class="w-full max-w-xl rounded border border-slate-300 px-3 py-2 text-sm",
            placeholder="Search message, type, level, platform, event id...",
            `type`="text",
            value=eventsSearchDraft
          ):
            proc oninput(ev: Event; n: VNode) =
              eventsSearchDraft = $n.value
        button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
          text "Search"
          proc onclick(ev: Event; n: VNode) =
            searchProjectEvents(eventsSearchDraft)
        if eventsSearch.len > 0:
          button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
            text "Clear"
            proc onclick(ev: Event; n: VNode) =
              eventsSearchDraft = ""
              searchProjectEvents("")

      if not eventsLoading and eventsTotal > 0:
        p(class="mb-3 text-sm text-slate-600"):
          text "Page " & $eventsPage & " of " & $eventsTotalPages & " · " & $eventsTotal & " issues"
          if eventsSearch.len > 0:
            text " matching \"" & eventsSearch & "\""

      if eventsLoading:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
          text "Loading issues..."
      elif projectEvents.len == 0:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center"):
          p(class="text-lg font-medium"):
            if eventsSearch.len > 0:
              text "No matching issues"
            else:
              text "No issues yet"
          p(class="mt-2 text-sm text-slate-500"):
            if eventsSearch.len > 0:
              text "Try a different search term or clear the filter."
            else:
              text "Send an error from your app using the DSN above."
      else:
        if selectedEventIds.len > 0 or projectEvents.len > 0:
          tdiv(class="mb-3 flex flex-wrap items-center gap-2"):
            if selectedEventIds.len > 0:
              span(class="text-sm text-slate-600"):
                text $selectedEventIds.len & " selected"
              button(class="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 hover:bg-red-100"):
                if eventsDeleting:
                  text "Deleting..."
                else:
                  text "Delete selected"
                proc onclick(ev: Event; n: VNode) =
                  if not eventsDeleting:
                    deleteSelectedEvents(projectId)
              button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
                text "Clear selection"
                proc onclick(ev: Event; n: VNode) =
                  clearEventSelection()
                  redraw()
        tdiv(class="overflow-hidden rounded border border-slate-200 bg-white"):
          tdiv(class="overflow-x-auto"):
            table(class="min-w-full text-left text-sm"):
              thead(class="border-b border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500"):
                tr:
                  th(class="px-4 py-3 font-medium w-10"):
                    input(`type`="checkbox", checked=allPageEventsSelected()):
                      proc onclick(ev: Event; n: VNode) =
                        {.emit: "ev.stopPropagation();".}
                        toggleSelectAllPageEvents()
                  th(class="px-4 py-3 font-medium"):
                    text "Level"
                  th(class="px-4 py-3 font-medium"):
                    text "Type"
                  th(class="px-4 py-3 font-medium"):
                    text "Message"
                  th(class="px-4 py-3 font-medium"):
                    text "Platform"
                  th(class="px-4 py-3 font-medium"):
                    text "Received"
              tbody:
                for issue in projectEvents:
                  let issuePath = issueDetailHref(projectId, issue.eventId)
                  let eventId = issue.eventId
                  let rowSelected = isEventSelected(eventId)
                  tr(class="border-b border-slate-100 last:border-0 hover:bg-slate-50"):
                    td(class="px-4 py-3"):
                      input(`type`="checkbox", checked=rowSelected):
                        proc onclick(ev: Event; n: VNode) =
                          {.emit: "ev.stopPropagation();".}
                          toggleEventSelection(eventId)
                    td(class="px-4 py-3"):
                      span(class="rounded px-2 py-1 text-xs font-medium " & issueLevelClass(issue.level)):
                        text issue.level
                    td(class="px-4 py-3 font-medium"):
                      a(class="text-pink-700 hover:underline", href=issuePath):
                        text issue.errorType
                    td(class="px-4 py-3 text-slate-700"):
                      a(class="block hover:text-pink-700", href=issuePath):
                        text issue.message
                    td(class="px-4 py-3 text-slate-500"):
                      text issue.platform
                    td(class="px-4 py-3 whitespace-nowrap text-slate-500"):
                      text issue.receivedAt

        if eventsTotalPages > 1:
          tdiv(class="mt-4 flex flex-wrap items-center justify-between gap-3"):
            button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
              text "Previous"
              proc onclick(ev: Event; n: VNode) =
                if eventsPage > 1:
                  goToEventsPage(eventsPage - 1)
            span(class="text-sm text-slate-600"):
              text "Page " & $eventsPage & " of " & $eventsTotalPages
            button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
              text "Next"
              proc onclick(ev: Event; n: VNode) =
                if eventsPage < eventsTotalPages:
                  goToEventsPage(eventsPage + 1)

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
