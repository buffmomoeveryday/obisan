include karax/prelude

import kraut
import ../utils/auth

var
  name = ""
  email = ""
  password = ""

proc render*(context: Context): VNode =
  if setupLoaded and not needsSetup:
    navigate("/login")

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950 flex items-center justify-center px-6")):
    button(class="fixed right-6 top-6 rounded border border-slate-300 bg-white px-3 py-2 text-sm hover:bg-slate-50"):
      if darkMode:
        text "Light"
      else:
        text "Dark"
      proc onclick(ev: Event; n: VNode) =
        toggleTheme()
    tdiv(class="w-full max-w-md rounded border border-slate-200 bg-white p-6 shadow-sm"):
      tdiv(class="mb-8"):
        p(class="text-sm text-pink-700 font-semibold uppercase tracking-wide"):
          text "Obisan setup"
        h1(class="text-3xl font-semibold mt-2"):
          text "Create the first user"
        p(class="text-slate-600 mt-2"):
          text "This initializes the workspace. Future visits go to sign in."

      tdiv(class="space-y-4"):
        label(class="block"):
          span(class="block text-sm text-slate-600 mb-2"):
            text "Name"
          input(class="w-full rounded border border-slate-300 bg-white px-3 py-2 text-slate-950 outline-none focus:border-pink-500", value=name):
            proc oninput(ev: Event; n: VNode) =
              name = $n.value

        label(class="block"):
          span(class="block text-sm text-slate-600 mb-2"):
            text "Email"
          input(class="w-full rounded border border-slate-300 bg-white px-3 py-2 text-slate-950 outline-none focus:border-pink-500", value=email):
            proc oninput(ev: Event; n: VNode) =
              email = $n.value

        label(class="block"):
          span(class="block text-sm text-slate-600 mb-2"):
            text "Password"
          input(class="w-full rounded border border-slate-300 bg-white px-3 py-2 text-slate-950 outline-none focus:border-pink-500", `type`="password", value=password):
            proc oninput(ev: Event; n: VNode) =
              password = $n.value

        if authMessage.len > 0:
          p(class="text-sm text-red-700"):
            text authMessage

        button(class="w-full rounded bg-pink-600 px-4 py-2 font-medium text-white hover:bg-pink-500"):
          text "Create user"
          proc onclick(ev: Event; n: VNode) =
            register(name, email, password)
