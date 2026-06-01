include karax/prelude

import strutils
import ../utils/auth

proc renderAppHeader*(title: string, subtitle: string = ""): VNode =
  buildHtml(tdiv(class="border-b border-slate-200 bg-white")):
    tdiv(class="mx-auto flex max-w-6xl items-center justify-between px-6 py-4"):
      tdiv(class="flex items-center gap-8"):
        tdiv:
          p(class="text-sm font-semibold uppercase tracking-wide text-pink-700"):
            text "Obisan"
          h1(class="text-xl font-semibold"):
            text title
          if subtitle.len > 0:
            p(class="text-sm text-slate-500"):
              text subtitle
        tdiv(class="hidden sm:flex items-center gap-4 text-sm"):
          a(class="font-medium text-slate-950 hover:text-pink-700", href="#/dashboard"):
            text "Projects"
      tdiv(class="flex items-center gap-3"):
        if currentUser.email.len > 0:
          p(class="hidden sm:block text-sm text-slate-500"):
            text currentUser.email
        button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
          if darkMode:
            text "Light"
          else:
            text "Dark"
          proc onclick(ev: Event; n: VNode) =
            toggleTheme()
        button(class="rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
          text "Sign out"
          proc onclick(ev: Event; n: VNode) =
            logout()

proc levelBadgeClass(level: string): string =
  case level.toLowerAscii()
  of "error", "fatal":
    "bg-red-100 text-red-800"
  of "warning":
    "bg-amber-100 text-amber-800"
  of "info":
    "bg-blue-100 text-blue-800"
  else:
    "bg-slate-100 text-slate-700"

proc renderCopyFeedback*(): VNode =
  if copyFeedback.len == 0:
    buildHtml(tdiv):
      discard
  else:
    buildHtml(tdiv(class="fixed bottom-4 right-4 z-50 rounded bg-slate-900 px-3 py-2 text-sm text-white shadow-lg")):
      text copyFeedback
