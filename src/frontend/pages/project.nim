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
var webhookUrlDraft = ""
var webhookDraftProjectId = ""
var savingWebhookUrl = false
var webhookModalOpen = false
var emailSettingsDraftProjectId = ""
var projectEmailEnabledDraft = false
var projectEmailToAddrsDraft = ""
var savingProjectEmailSettings = false
var showProjectSettings = false

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

  if not settingsLoaded and not settingsLoading:
    loadAppSettings()

  if membersProjectId != projectId and not membersLoading:
    loadProjectMembers(projectId)

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
  of "error", "fatal": "bg-red-100 text-red-800"
  of "warning": "bg-amber-100 text-amber-800"
  of "info": "bg-blue-100 text-blue-800"
  else: "bg-slate-100 text-slate-700"

proc renderLoadingState(title, message: string): VNode =
  buildHtml(tdiv(class = "min-h-screen hanami-bg text-slate-950")):
    renderAppHeader(title, message)
    tdiv(class = "mx-auto max-w-6xl px-6 py-8"):
      tdiv(
        class =
          "rounded border border-slate-200 bg-white p-8 text-center text-slate-500"
      ):
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
  let webhookUrl = currentProject.webhookUrl
  let emailEnabled = currentProject.emailEnabled
  let emailToAddrs = currentProject.emailToAddrs
  let projectName = displayProjectName(projectId, currentProject.name)
  let renameDraftSeed = projectNameForEdit(currentProject.name)
  if webhookDraftProjectId != projectId:
    webhookDraftProjectId = projectId
    webhookUrlDraft = webhookUrl
  if emailSettingsDraftProjectId != projectId:
    emailSettingsDraftProjectId = projectId
    projectEmailEnabledDraft = emailEnabled
    projectEmailToAddrsDraft = emailToAddrs

  buildHtml(tdiv(class = "min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Issues", projectName)

    tdiv(class = "mx-auto max-w-6xl px-6 py-8"):
      tdiv(class = "mb-6 flex flex-wrap items-start justify-between gap-3"):
        tdiv(class = "min-w-0 flex-1"):
          a(class = "text-sm text-pink-700 hover:underline", href = "#/dashboard"):
            text "Back to projects"
          if editingProjectName:
            tdiv(class = "mt-3 flex flex-wrap items-end gap-2"):
              tdiv:
                label(
                  class =
                    "mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"
                ):
                  text "Project name"
                input(
                  class = "w-72 rounded border border-slate-300 px-3 py-2 text-sm",
                  placeholder = "Project name",
                  `type` = "text",
                  value = projectNameDraft,
                ):
                  proc oninput(ev: Event, n: VNode) =
                    projectNameDraft = $n.value

              button(
                class =
                  "rounded bg-pink-600 px-3 py-2 text-sm font-medium text-white hover:bg-pink-500"
              ):
                if savingProjectName:
                  text "Saving..."
                else:
                  text "Save"
                proc onclick(ev: Event, n: VNode) =
                  if not savingProjectName:
                    savingProjectName = true
                    updateProjectName(
                      projectId,
                      projectNameDraft,
                      proc() =
                        savingProjectName = false
                        editingProjectName = false,
                    )

              button(
                class =
                  "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
              ):
                text "Cancel"
                proc onclick(ev: Event, n: VNode) =
                  editingProjectName = false
                  projectNameDraft = renameDraftSeed

          else:
            h2(class = "mt-2 text-2xl font-semibold"):
              text projectName
            button(class = "mt-2 text-sm text-pink-700 hover:underline"):
              text "Rename project"
              proc onclick(ev: Event, n: VNode) =
                editingProjectName = true
                projectNameDraft = renameDraftSeed

        tdiv(class = "flex flex-wrap gap-2"):
          button(
            class =
              "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
          ):
            text "Webhook"
            proc onclick(ev: Event, n: VNode) =
              webhookUrlDraft = webhookUrl
              webhookModalOpen = true

          a(
            class =
              "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50",
            href = "#/projects/" & projectId & "/invite",
          ):
            text "Invite user"
          button(
            class =
              "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
          ):
            text "Copy DSN"
            proc onclick(ev: Event, n: VNode) =
              copyText(dsn)

          if ntfyTopic.len > 0:
            button(
              class =
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
            ):
              text "Copy ntfy topic"
              proc onclick(ev: Event, n: VNode) =
                copyText(ntfyTopic)

      tdiv(class = "mb-5 border-b border-slate-200"):
        nav(class = "-mb-px flex gap-5 text-sm"):
          a(
            class = "border-b-2 border-pink-600 px-1 py-3 font-medium text-pink-700",
            href = projectEventsHref(projectId, eventsSearch, eventsPage),
          ):
            text "Issues"
          a(
            class =
              "border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950",
            href = projectLogsHref(projectId, logsSearch, logsPage),
          ):
            text "Logs"
          a(
            class =
              "border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950",
            href = projectMetricsHref(projectId, metricsSearch, metricsPage),
          ):
            text "Metrics"
          a(
            class =
              "border-b-2 border-transparent px-1 py-3 text-slate-600 hover:border-slate-300 hover:text-slate-950",
            href = projectUptimeHref(projectId),
          ):
            text "Uptime"

      if dsn.len > 0 or ntfyUrl.len > 0 or webhookUrl.len > 0 or showProjectSettings:
        tdiv(class = "mb-4 max-w-2xl rounded border border-slate-200 bg-white p-4"):
          if dsn.len > 0:
            tdiv(class = "mb-3"):
              label(
                class =
                  "mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"
              ):
                text "DSN"
              p(class = "break-all font-mono text-xs text-slate-600"):
                text dsn
          if ntfyUrl.len > 0:
            tdiv(class = "mb-3"):
              label(
                class =
                  "mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"
              ):
                text "Push alerts"
              p(class = "text-sm text-slate-600"):
                text "Subscribe to "
                span(class = "font-mono text-xs"):
                  text ntfyTopic
                text " on ntfy.sh"
          if webhookUrl.len > 0:
            tdiv(class = "mb-3"):
              label(
                class =
                  "mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"
              ):
                text "Webhook"
              p(class = "break-all font-mono text-xs text-slate-500"):
                text webhookUrl

          tdiv(class = "border-t border-slate-100 pt-3"):
            button(
              class =
                "flex w-full items-center justify-between text-sm text-slate-600 hover:text-slate-900"
            ):
              span(class = "font-medium"):
                text "Project settings"
              span(class = "text-xs text-slate-400"):
                if showProjectSettings:
                  text "Hide"
                else:
                  text "Show"
              proc onclick(ev: Event, n: VNode) =
                showProjectSettings = not showProjectSettings

            if showProjectSettings:
              tdiv(class = "mt-3 space-y-4"):
                tdiv:
                  tdiv(class = "flex flex-wrap items-center justify-between gap-2"):
                    h3(
                      class =
                        "text-sm font-semibold uppercase tracking-wide text-slate-500"
                    ):
                      text "Project members"
                    a(
                      class =
                        "rounded bg-pink-600 px-3 py-2 text-sm font-medium text-white hover:bg-pink-500",
                      href = "#/projects/" & projectId & "/invite",
                    ):
                      text "Invite user"
                  if membersLoading:
                    p(class = "mt-3 text-sm text-slate-500"):
                      text "Loading members..."
                  elif projectMembers.len > 0:
                    tdiv(
                      class =
                        "mt-3 divide-y divide-slate-100 rounded border border-slate-200"
                    ):
                      for member in projectMembers:
                        tdiv(
                          class =
                            "flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm"
                        ):
                          tdiv(class = "min-w-0"):
                            p(class = "font-medium text-slate-900"):
                              text member.name
                              if member.owner:
                                span(
                                  class =
                                    "ml-2 rounded bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600"
                                ):
                                  text "Owner"
                            p(class = "break-all text-xs text-slate-500"):
                              text member.email
                          if not member.owner:
                            let memberId = member.id
                            button(
                              class =
                                "rounded border border-slate-300 bg-white px-2 py-1 text-xs hover:bg-slate-50"
                            ):
                              text "Remove"
                              proc onclick(ev: Event, n: VNode) =
                                removeProjectMember(projectId, memberId)

                tdiv:
                  h3(
                    class =
                      "text-sm font-semibold uppercase tracking-wide text-slate-500"
                  ):
                    text "Notifications"
                  tdiv(class = "mt-3 space-y-3"):
                    label(class = "flex items-center gap-2 text-sm text-slate-700"):
                      input(`type` = "checkbox", checked = projectEmailEnabledDraft):
                        proc onchange(ev: Event, n: VNode) =
                          projectEmailEnabledDraft = not projectEmailEnabledDraft

                      text "Send email"
                    tdiv:
                      label(
                        class =
                          "mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"
                      ):
                        text "Email recipients"
                      input(
                        class =
                          "w-full rounded border border-slate-300 px-3 py-2 text-sm",
                        placeholder = "ops@example.com, oncall@example.com",
                        `type` = "text",
                        value = projectEmailToAddrsDraft,
                      ):
                        proc oninput(ev: Event, n: VNode) =
                          projectEmailToAddrsDraft = $n.value

                    if not smtpConfigured():
                      p(class = "text-sm text-amber-700"):
                        text "SMTP must be configured in Settings before email can be sent."
                    tdiv(class = "flex flex-wrap justify-end gap-2"):
                      button(
                        class =
                          "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
                      ):
                        text "Reset"
                        proc onclick(ev: Event, n: VNode) =
                          projectEmailEnabledDraft = emailEnabled
                          projectEmailToAddrsDraft = emailToAddrs

                      button(
                        class =
                          "rounded bg-pink-600 px-3 py-2 text-sm font-medium text-white hover:bg-pink-500"
                      ):
                        if savingProjectEmailSettings:
                          text "Saving..."
                        else:
                          text "Save notifications"
                        proc onclick(ev: Event, n: VNode) =
                          if not savingProjectEmailSettings:
                            savingProjectEmailSettings = true
                            updateProjectEmailSettings(
                              projectId,
                              projectEmailEnabledDraft,
                              projectEmailToAddrsDraft,
                              proc() =
                                savingProjectEmailSettings = false,
                            )

      tdiv(class = "mb-4 flex flex-wrap items-end gap-2"):
        tdiv(class = "min-w-0 flex-1"):
          label(
            class =
              "mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"
          ):
            text "Search issues"
          input(
            class = "w-full max-w-xl rounded border border-slate-300 px-3 py-2 text-sm",
            placeholder = "Search message, type, level, platform, event id...",
            `type` = "text",
            value = eventsSearchDraft,
          ):
            proc oninput(ev: Event, n: VNode) =
              eventsSearchDraft = $n.value

        button(
          class =
            "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
        ):
          text "Search"
          proc onclick(ev: Event, n: VNode) =
            searchProjectEvents(eventsSearchDraft)

        if eventsSearch.len > 0:
          button(
            class =
              "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
          ):
            text "Clear"
            proc onclick(ev: Event, n: VNode) =
              eventsSearchDraft = ""
              searchProjectEvents("")

      if not eventsLoading and eventsTotal > 0:
        p(class = "mb-3 text-sm text-slate-600"):
          text "Page " & $eventsPage & " of " & $eventsTotalPages & " · " & $eventsTotal &
            " issues"
          if eventsSearch.len > 0:
            text " matching \"" & eventsSearch & "\""

      if eventsLoading:
        tdiv(
          class =
            "rounded border border-slate-200 bg-white p-8 text-center text-slate-500"
        ):
          text "Loading issues..."
      elif projectEvents.len == 0:
        tdiv(class = "rounded border border-slate-200 bg-white p-8 text-center"):
          p(class = "text-lg font-medium"):
            if eventsSearch.len > 0:
              text "No matching issues"
            else:
              text "No issues yet"
          p(class = "mt-2 text-sm text-slate-500"):
            if eventsSearch.len > 0:
              text "Try a different search term or clear the filter."
            else:
              text "Send an error from your app using the DSN above."
      else:
        if selectedEventIds.len > 0 or projectEvents.len > 0:
          tdiv(class = "mb-3 flex flex-wrap items-center gap-2"):
            if selectedEventIds.len > 0:
              span(class = "text-sm text-slate-600"):
                text $selectedEventIds.len & " selected"
              button(
                class =
                  "rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 hover:bg-red-100"
              ):
                if eventsDeleting:
                  text "Deleting..."
                else:
                  text "Delete selected"
                proc onclick(ev: Event, n: VNode) =
                  if not eventsDeleting:
                    deleteSelectedEvents(projectId)

              button(
                class =
                  "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
              ):
                text "Clear selection"
                proc onclick(ev: Event, n: VNode) =
                  clearEventSelection()
                  redraw()

        tdiv(class = "overflow-hidden rounded border border-slate-200 bg-white"):
          tdiv(class = "overflow-x-auto"):
            table(class = "min-w-full text-left text-sm"):
              thead(
                class =
                  "border-b border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500"
              ):
                tr:
                  th(class = "px-4 py-3 font-medium w-10"):
                    input(`type` = "checkbox", checked = allPageEventsSelected()):
                      proc onclick(ev: Event, n: VNode) =
                        {.emit: "ev.stopPropagation();".}
                        toggleSelectAllPageEvents()

                  th(class = "px-4 py-3 font-medium"):
                    text "Level"
                  th(class = "px-4 py-3 font-medium"):
                    text "Type"
                  th(class = "px-4 py-3 font-medium"):
                    text "Message"
                  th(class = "px-4 py-3 font-medium"):
                    text "Platform"
                  th(class = "px-4 py-3 font-medium"):
                    text "Received"
              tbody:
                for issue in projectEvents:
                  let issuePath = issueDetailHref(projectId, issue.eventId)
                  let eventId = issue.eventId
                  let rowSelected = isEventSelected(eventId)
                  tr(
                    class = "border-b border-slate-100 last:border-0 hover:bg-slate-50"
                  ):
                    td(class = "px-4 py-3"):
                      input(`type` = "checkbox", checked = rowSelected):
                        proc onclick(ev: Event, n: VNode) =
                          {.emit: "ev.stopPropagation();".}
                          toggleEventSelection(eventId)

                    td(class = "px-4 py-3"):
                      span(
                        class =
                          "rounded px-2 py-1 text-xs font-medium " &
                          issueLevelClass(issue.level)
                      ):
                        text issue.level
                    td(class = "px-4 py-3 font-medium"):
                      a(class = "text-pink-700 hover:underline", href = issuePath):
                        text issue.errorType
                    td(class = "px-4 py-3 text-slate-700"):
                      a(class = "block hover:text-pink-700", href = issuePath):
                        text issue.message
                    td(class = "px-4 py-3 text-slate-500"):
                      text issue.platform
                    td(class = "px-4 py-3 whitespace-nowrap text-slate-500"):
                      text issue.receivedAt

        if eventsTotalPages > 1:
          tdiv(class = "mt-4 flex flex-wrap items-center justify-between gap-3"):
            button(
              class =
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
            ):
              text "Previous"
              proc onclick(ev: Event, n: VNode) =
                if eventsPage > 1:
                  goToEventsPage(eventsPage - 1)

            span(class = "text-sm text-slate-600"):
              text "Page " & $eventsPage & " of " & $eventsTotalPages
            button(
              class =
                "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
            ):
              text "Next"
              proc onclick(ev: Event, n: VNode) =
                if eventsPage < eventsTotalPages:
                  goToEventsPage(eventsPage + 1)

      if authMessage.len > 0:
        p(class = "mt-4 text-sm text-red-700"):
          text authMessage

      if webhookModalOpen:
        tdiv(
          class =
            "fixed inset-0 z-50 flex items-center justify-center bg-slate-950/40 px-4 py-6"
        ):
          tdiv(
            class =
              "w-full max-w-lg rounded border border-slate-200 bg-white p-5 shadow-xl"
          ):
            tdiv(class = "mb-4 flex items-start justify-between gap-3"):
              tdiv:
                h3(class = "text-lg font-semibold text-slate-950"):
                  text "Webhook"
                p(class = "mt-1 text-sm text-slate-600"):
                  text "Sends JSON for new issues, logs, metrics, and uptime status changes."
              button(
                class =
                  "rounded border border-slate-300 bg-white px-2 py-1 text-sm hover:bg-slate-50"
              ):
                text "Close"
                proc onclick(ev: Event, n: VNode) =
                  webhookModalOpen = false

            label(
              class =
                "mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"
            ):
              text "Webhook URL"
            input(
              class = "w-full rounded border border-slate-300 px-3 py-2 text-sm",
              placeholder = "https://example.com/obisan-webhook",
              `type` = "url",
              value = webhookUrlDraft,
            ):
              proc oninput(ev: Event, n: VNode) =
                webhookUrlDraft = $n.value

            tdiv(class = "mt-4 flex flex-wrap justify-end gap-2"):
              if webhookUrl.len > 0:
                button(
                  class =
                    "rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"
                ):
                  text "Clear"
                  proc onclick(ev: Event, n: VNode) =
                    if not savingWebhookUrl:
                      savingWebhookUrl = true
                      updateProjectWebhookUrl(
                        projectId,
                        "",
                        proc() =
                          webhookUrlDraft = ""
                          savingWebhookUrl = false
                          webhookModalOpen = false,
                      )

              button(
                class =
                  "rounded bg-pink-600 px-3 py-2 text-sm font-medium text-white hover:bg-pink-500"
              ):
                if savingWebhookUrl:
                  text "Saving..."
                else:
                  text "Save webhook"
                proc onclick(ev: Event, n: VNode) =
                  if not savingWebhookUrl:
                    savingWebhookUrl = true
                    updateProjectWebhookUrl(
                      projectId,
                      webhookUrlDraft,
                      proc() =
                        savingWebhookUrl = false
                        webhookModalOpen = false,
                    )

    renderCopyFeedback()
