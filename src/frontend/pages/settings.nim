include karax/prelude

import kraut
import ../utils/auth
import ../components/layout

var
  draftLoaded = false
  accountDraftLoaded = false
  accountNameDraft = ""
  accountEmailDraft = ""
  accountCurrentPasswordDraft = ""
  accountNewPasswordDraft = ""
  ntfyServerUrlDraft = "https://ntfy.sh"
  ntfyUsernameDraft = ""
  ntfyPasswordDraft = ""
  ntfyTokenDraft = ""
  clearNtfyPasswordDraft = false
  clearNtfyTokenDraft = false
  smtpHostDraft = ""
  smtpPortDraft = ""
  smtpUsernameDraft = ""
  smtpPasswordDraft = ""
  smtpFromAddrDraft = ""
  smtpUseTlsDraft = true
  clearSmtpPasswordDraft = false

proc seedDrafts() =
  ntfyServerUrlDraft = appSettings.ntfyServerUrl
  if ntfyServerUrlDraft.len == 0:
    ntfyServerUrlDraft = "https://ntfy.sh"
  ntfyUsernameDraft = appSettings.ntfyUsername
  ntfyPasswordDraft = ""
  ntfyTokenDraft = ""
  clearNtfyPasswordDraft = false
  clearNtfyTokenDraft = false
  smtpHostDraft = appSettings.smtpHost
  smtpPortDraft = if appSettings.smtpPort > 0: $appSettings.smtpPort else: ""
  smtpUsernameDraft = appSettings.smtpUsername
  smtpPasswordDraft = ""
  smtpFromAddrDraft = appSettings.smtpFromAddr
  smtpUseTlsDraft = appSettings.smtpUseTls
  clearSmtpPasswordDraft = false
  draftLoaded = true

proc seedAccountDrafts() =
  accountNameDraft = currentUser.name
  accountEmailDraft = currentUser.email
  accountCurrentPasswordDraft = ""
  accountNewPasswordDraft = ""
  accountDraftLoaded = true

proc ensureSettingsPage() =
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
  if currentUser.email.len > 0 and not accountDraftLoaded:
    seedAccountDrafts()
  if not settingsLoaded and not settingsLoading:
    loadAppSettings()
  if settingsLoaded and not draftLoaded:
    seedDrafts()

proc renderSecretState(configured: bool, clearDraft: bool): VNode =
  buildHtml(p(class="mt-1 text-xs text-slate-500")):
    if clearDraft:
      text "Saved secret will be cleared."
    elif configured:
      text "A secret is already saved. Leave blank to keep it."
    else:
      text "No secret saved."

proc render*(context: Context): VNode =
  discard context
  ensureSettingsPage()

  if savedToken().len == 0:
    return buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
      renderAppHeader("Settings", "Redirecting...")

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950")):
    renderAppHeader("Settings", "Global notification delivery")

    tdiv(class="mx-auto max-w-6xl px-6 py-8"):
      if authMessage.len > 0:
        tdiv(class="mb-4 rounded border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900"):
          text authMessage

      if settingsLoading and not settingsLoaded:
        tdiv(class="rounded border border-slate-200 bg-white p-8 text-center text-slate-500"):
          text "Loading settings..."
      else:
        section(class="mb-6 rounded border border-slate-200 bg-white p-5"):
          h2(class="text-lg font-semibold"):
            text "Account"
          tdiv(class="mt-4 grid gap-4 lg:grid-cols-2"):
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "Name"
              input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="text", value=accountNameDraft, placeholder="Your name"):
                proc onchange(ev: Event; n: VNode) =
                  accountNameDraft = $n.value
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "Email"
              input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="email", value=accountEmailDraft, placeholder="you@example.com"):
                proc onchange(ev: Event; n: VNode) =
                  accountEmailDraft = $n.value
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "Current password"
              input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="password", value=accountCurrentPasswordDraft, placeholder="Required for email or password changes"):
                proc onchange(ev: Event; n: VNode) =
                  accountCurrentPasswordDraft = $n.value
            tdiv:
              label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                text "New password"
              input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="password", value=accountNewPasswordDraft, placeholder="Leave blank to keep current password"):
                proc onchange(ev: Event; n: VNode) =
                  accountNewPasswordDraft = $n.value
          tdiv(class="mt-4 flex flex-wrap gap-2"):
            button(class="rounded bg-pink-600 px-4 py-2 text-sm font-medium text-white hover:bg-pink-500"):
              if profileSaving:
                text "Saving..."
              else:
                text "Save account"
              proc onclick(ev: Event; n: VNode) =
                updateProfile(accountNameDraft, accountEmailDraft, accountCurrentPasswordDraft, accountNewPasswordDraft, proc() =
                  seedAccountDrafts()
                )
            button(class="rounded border border-slate-300 bg-white px-4 py-2 text-sm hover:bg-slate-50"):
              text "Reset account"
              proc onclick(ev: Event; n: VNode) =
                seedAccountDrafts()

        tdiv(class="grid gap-6 lg:grid-cols-2"):
          section(class="rounded border border-slate-200 bg-white p-5"):
            h2(class="text-lg font-semibold"):
              text "ntfy"
            tdiv(class="mt-4 space-y-4"):
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "Server URL"
                input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="url", value=ntfyServerUrlDraft, placeholder="https://ntfy.sh"):
                  proc oninput(ev: Event; n: VNode) =
                    ntfyServerUrlDraft = $n.value
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "Username"
                input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="text", value=ntfyUsernameDraft, placeholder="optional"):
                  proc oninput(ev: Event; n: VNode) =
                    ntfyUsernameDraft = $n.value
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "Password"
                input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="password", value=ntfyPasswordDraft, placeholder="leave blank to keep saved password"):
                  proc oninput(ev: Event; n: VNode) =
                    ntfyPasswordDraft = $n.value
                renderSecretState(appSettings.ntfyPasswordConfigured, clearNtfyPasswordDraft)
                label(class="mt-2 flex items-center gap-2 text-sm text-slate-600"):
                  input(`type`="checkbox", checked=clearNtfyPasswordDraft):
                    proc onchange(ev: Event; n: VNode) =
                      clearNtfyPasswordDraft = not clearNtfyPasswordDraft
                  text "Clear saved password"
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "Access token"
                input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="password", value=ntfyTokenDraft, placeholder="optional bearer token"):
                  proc oninput(ev: Event; n: VNode) =
                    ntfyTokenDraft = $n.value
                renderSecretState(appSettings.ntfyTokenConfigured, clearNtfyTokenDraft)
                label(class="mt-2 flex items-center gap-2 text-sm text-slate-600"):
                  input(`type`="checkbox", checked=clearNtfyTokenDraft):
                    proc onchange(ev: Event; n: VNode) =
                      clearNtfyTokenDraft = not clearNtfyTokenDraft
                  text "Clear saved token"

          section(class="rounded border border-slate-200 bg-white p-5"):
            h2(class="text-lg font-semibold"):
              text "SMTP"
            tdiv(class="mt-4 space-y-4"):
              tdiv(class="grid gap-3 sm:grid-cols-[1fr_120px]"):
                tdiv:
                  label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                    text "Host"
                  input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="text", value=smtpHostDraft, placeholder="smtp.example.com"):
                    proc oninput(ev: Event; n: VNode) =
                      smtpHostDraft = $n.value
                tdiv:
                  label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                    text "Port"
                  input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="number", value=smtpPortDraft, placeholder="587"):
                    proc oninput(ev: Event; n: VNode) =
                      smtpPortDraft = $n.value
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "Username"
                input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="text", value=smtpUsernameDraft, placeholder="optional"):
                  proc oninput(ev: Event; n: VNode) =
                    smtpUsernameDraft = $n.value
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "Password"
                input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="password", value=smtpPasswordDraft, placeholder="leave blank to keep saved password"):
                  proc oninput(ev: Event; n: VNode) =
                    smtpPasswordDraft = $n.value
                renderSecretState(appSettings.smtpPasswordConfigured, clearSmtpPasswordDraft)
                label(class="mt-2 flex items-center gap-2 text-sm text-slate-600"):
                  input(`type`="checkbox", checked=clearSmtpPasswordDraft):
                    proc onchange(ev: Event; n: VNode) =
                      clearSmtpPasswordDraft = not clearSmtpPasswordDraft
                  text "Clear saved password"
              tdiv:
                label(class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500"):
                  text "From address"
                input(class="w-full rounded border border-slate-300 px-3 py-2 text-sm", `type`="email", value=smtpFromAddrDraft, placeholder="alerts@example.com"):
                  proc oninput(ev: Event; n: VNode) =
                    smtpFromAddrDraft = $n.value
              label(class="flex items-center gap-2 text-sm text-slate-600"):
                input(`type`="checkbox", checked=smtpUseTlsDraft):
                  proc onchange(ev: Event; n: VNode) =
                    smtpUseTlsDraft = not smtpUseTlsDraft
                text "Use TLS"

        tdiv(class="mt-6 flex flex-wrap gap-2"):
          button(class="rounded bg-pink-600 px-4 py-2 text-sm font-medium text-white hover:bg-pink-500"):
            if settingsSaving:
              text "Saving..."
            else:
              text "Save settings"
            proc onclick(ev: Event; n: VNode) =
              updateAppSettings(
                ntfyServerUrlDraft,
                ntfyUsernameDraft,
                ntfyPasswordDraft,
                ntfyTokenDraft,
                clearNtfyPasswordDraft,
                clearNtfyTokenDraft,
                smtpHostDraft,
                smtpPortDraft,
                smtpUsernameDraft,
                smtpPasswordDraft,
                smtpFromAddrDraft,
                smtpUseTlsDraft,
                clearSmtpPasswordDraft,
                proc() =
                  seedDrafts()
              )
          button(class="rounded border border-slate-300 bg-white px-4 py-2 text-sm hover:bg-slate-50"):
            text "Reset"
            proc onclick(ev: Event; n: VNode) =
              seedDrafts()
