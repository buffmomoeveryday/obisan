include karax/prelude

import options
import strutils
import kraut
import ../utils/auth
import ../components/layout

var deletingIssue = false

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

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Issue", projectLabel)

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv:
          a(class="text-sm text-pink-700 hover:underline", href=projectEventsHref(projectId, eventsSearch, eventsPage)):
            text "← Back to issues"
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
            p(class="mt-2 font-mono text-xs text-slate-500"):
              text "Event ID: "
              text selectedIssue.eventId

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

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
