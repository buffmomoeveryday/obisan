include karax/prelude

import kraut
import ../utils/auth
import ../components/layout

var creatingProject = false
var newProjectName = ""

proc ensureAuthenticated() =
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

proc render*(context: Context): VNode =
  ensureAuthenticated()

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Projects", "Track errors from your applications")

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      tdiv(class="mb-6 flex flex-wrap items-end justify-between gap-3"):
        tdiv:
          h2(class="text-2xl font-semibold"):
            text "Your projects"
          p(class="mt-1 text-sm text-slate-600"):
            text "Name each project for readable alerts and ntfy.sh topics."
        tdiv(class="flex flex-wrap items-end gap-2"):
          a(class="rounded border border-slate-300 bg-white px-4 py-2 text-sm hover:bg-slate-50", href="#/invite"):
            text "Invite user"
          tdiv:
            label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
              text "Project name"
            input(
              class="w-56 rounded border border-slate-300 px-3 py-2 text-sm",
              placeholder="e.g. Backend API",
              `type`="text",
              value=newProjectName
            ):
              proc oninput(ev: Event; n: VNode) =
                newProjectName = $n.value
          button(class="rounded bg-pink-600 px-4 py-2 text-sm font-medium text-white hover:bg-pink-500"):
            if creatingProject:
              text "Creating..."
            else:
              text "New project"
            proc onclick(ev: Event; n: VNode) =
              if not creatingProject:
                if newProjectName.strip().len == 0:
                  authMessage = "Enter a project name."
                  return
                creatingProject = true
                generateProject(newProjectName, proc() =
                  creatingProject = false
                  newProjectName = ""
                  if projects.len > 0:
                    navigate("/projects/" & projects[0].id)
                )

      if projectsLoading:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
          text "Loading projects..."
      elif projects.len == 0:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center"):
          p(class="text-lg font-medium"):
            text "No projects yet"
          p(class="mt-2 text-sm text-slate-500"):
            text "Enter a name above and create a project to get a DSN and ntfy topic."
      else:
        tdiv(class="overflow-hidden rounded border border-slate-200 bg-white"):
          tdiv(class="overflow-x-auto"):
            table(class="min-w-full text-left text-sm"):
              thead(class="border-b border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500"):
                tr:
                  th(class="px-4 py-3 font-medium"):
                    text "Project"
                  th(class="px-4 py-3 font-medium"):
                    text "Issues"
                  th(class="px-4 py-3 font-medium"):
                    text "DSN"
                  th(class="px-4 py-3 font-medium"):
                    text "ntfy.sh"
                  th(class="px-4 py-3 font-medium"):
                    text ""
              tbody:
                for project in projects:
                  let item = project
                  tr(class="border-b border-slate-100 last:border-0 hover:bg-slate-50"):
                    td(class="px-4 py-3"):
                      a(class="font-medium text-pink-700 hover:underline", href="#/projects/" & item.id):
                        text displayProjectName(item.id, item.name)
                    td(class="px-4 py-3"):
                      if item.issueCount > 0:
                        span(class="rounded bg-red-100 px-2 py-1 text-xs font-medium text-red-800"):
                          text $item.issueCount
                      else:
                        span(class="text-slate-400"):
                          text "0"
                    td(class="px-4 py-3"):
                      p(class="max-w-md truncate font-mono text-xs text-slate-600"):
                        text item.dsn
                    td(class="px-4 py-3"):
                      if item.ntfyUrl.len > 0:
                        p(class="max-w-xs truncate font-mono text-xs text-slate-600"):
                          text item.ntfyTopic
                      else:
                        span(class="text-slate-400"):
                          text "—"
                    td(class="px-4 py-3 whitespace-nowrap"):
                      tdiv(class="flex items-center gap-2"):
                        button(class="rounded border border-slate-300 px-2 py-1 text-xs hover:bg-slate-50"):
                          text "Copy DSN"
                          proc onclick(ev: Event; n: VNode) =
                            copyText(item.dsn)
                        if item.ntfyUrl.len > 0:
                          button(class="rounded border border-slate-300 px-2 py-1 text-xs hover:bg-slate-50"):
                            text "Copy topic"
                            proc onclick(ev: Event; n: VNode) =
                              copyText(item.ntfyTopic)
                        a(class="rounded bg-pink-600 px-2 py-1 text-xs font-medium text-white hover:bg-pink-500", href="#/projects/" & item.id):
                          text "View issues"

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

    renderCopyFeedback()
