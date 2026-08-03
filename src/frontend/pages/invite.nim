include karax/prelude

import options
import kraut
import ../utils/auth
import ../components/layout

var
  inviteNameDraft = ""
  inviteEmailDraft = ""
  inviteSaved = false

const
  inviteNameInputId = "invite-name"
  inviteEmailInputId = "invite-email"

proc clearInviteInputs() =
  getVNodeById(inviteNameInputId).setInputText ""
  getVNodeById(inviteEmailInputId).setInputText ""

proc ensureInvitePage(projectId: string) =
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

  if not settingsLoaded and not settingsLoading:
    loadAppSettings()

  if profileLoading or projectsLoading or not projectsLoaded:
    return

  if projectId.len > 0 and findProject(projectId).isNone:
    return

  if projectId.len > 0 and membersProjectId != projectId and not membersLoading:
    loadProjectMembers(projectId)

proc renderLoadingState(title, message: string): VNode =
  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader(title, message)
    tdiv(class="mx-auto max-w-3xl px-6 py-8"):
      tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
        text message

proc renderInvitePage(projectId: string): VNode =
  ensureInvitePage(projectId)

  if savedToken().len == 0:
    return renderLoadingState("Invite", "Redirecting...")

  if profileLoading or projectsLoading or not projectsLoaded:
    return renderLoadingState("Invite", "Loading...")

  if projectId.len > 0 and findProject(projectId).isNone:
    return renderLoadingState("Invite", "Project not found")

  if settingsLoading and not settingsLoaded:
    return renderLoadingState("Invite", "Loading settings...")

  let project = if projectId.len > 0: findProject(projectId) else: none(Project)
  let projectName =
    if project.isSome:
      displayProjectName(projectId, project.get.name)
    else:
      "Workspace invite"
  let backHref =
    if projectId.len > 0:
      projectEventsHref(projectId, eventsSearch, eventsPage)
    else:
      "#/dashboard"
  let backLabel =
    if projectId.len > 0:
      "Back to project"
    else:
      "Back to projects"
  let inviteReady = smtpConfigured()

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Invite", projectName)

    tdiv(class="mx-auto max-w-3xl px-6 py-8"):
      tdiv(class="mb-6"):
        a(class="text-sm text-pink-700 hover:underline", href=backHref):
          text backLabel
        h2(class="mt-2 text-2xl font-semibold"):
          text "Invite user"
        p(class="mt-2 text-sm text-slate-600"):
          if projectId.len > 0:
            text projectName
          else:
            text "Invite a user so they can sign in and create their own projects."

      tdiv(class="rounded border border-slate-200 bg-white p-5"):
        if not inviteReady:
          tdiv(class="mb-4 rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900"):
            text "Configure SMTP before inviting users."
            a(class="ml-2 font-medium text-amber-950 underline", href="#/settings"):
              text "Open settings"
        tdiv(class="grid gap-3"):
          tdiv:
            label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
              text "Name"
            input(
              class="w-full rounded border border-slate-300 px-3 py-2 text-sm",
              id=inviteNameInputId,
              placeholder="Name",
              `type`="text"
            ):
              proc oninput(ev: Event; n: VNode) =
                inviteNameDraft = $n.value
                inviteSaved = false
          tdiv:
            label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
              text "Email"
            input(
              class="w-full rounded border border-slate-300 px-3 py-2 text-sm",
              id=inviteEmailInputId,
              placeholder="email@example.com",
              `type`="email"
            ):
              proc oninput(ev: Event; n: VNode) =
                inviteEmailDraft = $n.value
                inviteSaved = false

        tdiv(class="mt-4 flex flex-wrap items-center justify-between gap-2"):
          if inviteSaved:
            span(class="text-sm text-emerald-700"):
              text "Invite sent."
          else:
            span()
          button(class=if inviteReady: "rounded bg-pink-600 px-3 py-2 text-sm font-medium text-white hover:bg-pink-500" else: "rounded bg-slate-300 px-3 py-2 text-sm font-medium text-white"):
            if membersSaving:
              text "Saving..."
            else:
              text "Invite user"
            proc onclick(ev: Event; n: VNode) =
              if membersSaving:
                return
              if not smtpConfigured():
                authMessage = "Configure SMTP before inviting users."
                return
              if projectId.len > 0:
                saveProjectMember(projectId, inviteNameDraft, inviteEmailDraft, proc() =
                  inviteNameDraft = ""
                  inviteEmailDraft = ""
                  inviteSaved = true
                  clearInviteInputs()
                )
              else:
                inviteUser(inviteNameDraft, inviteEmailDraft, proc() =
                  inviteNameDraft = ""
                  inviteEmailDraft = ""
                  inviteSaved = true
                  clearInviteInputs()
                )

      if projectId.len > 0:
        tdiv(class="mt-5 rounded border border-slate-200 bg-white p-5"):
          tdiv(class="flex flex-wrap items-center justify-between gap-2"):
            h3(class="text-sm font-semibold uppercase tracking-wide text-slate-500"):
              text "Project members"
            if membersLoading:
              span(class="text-sm text-slate-500"):
                text "Loading..."
          if projectMembers.len > 0:
            tdiv(class="mt-3 divide-y divide-slate-100 rounded border border-slate-200"):
              for member in projectMembers:
                tdiv(class="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm"):
                  tdiv(class="min-w-0"):
                    p(class="font-medium text-slate-900"):
                      text member.name
                      if member.owner:
                        span(class="ml-2 rounded bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600"):
                          text "Owner"
                    p(class="break-all text-xs text-slate-500"):
                      text member.email
                  if not member.owner:
                    let memberId = member.id
                    button(class="rounded border border-slate-300 bg-white px-2 py-1 text-xs hover:bg-slate-50"):
                      text "Remove"
                      proc onclick(ev: Event; n: VNode) =
                        removeProjectMember(projectId, memberId)
          elif not membersLoading:
            p(class="mt-3 text-sm text-slate-500"):
              text "No members yet."

      if authMessage.len > 0:
        p(class="mt-4 text-sm text-red-700"):
          text authMessage

proc render*(context: Context): VNode =
  renderInvitePage(context.urlParams.getOrDefault("id", ""))

proc renderWorkspace*(context: Context): VNode =
  discard context
  renderInvitePage("")
