include karax/prelude

import kraut
import ../utils/auth

proc render*(context: Context): VNode =
  if not setupLoaded:
    loadSetupStatus()

  if setupLoaded:
    if needsSetup:
      navigate("/register")
    elif savedToken().len > 0:
      navigate("/dashboard")
    else:
      navigate("/login")

  buildHtml(tdiv(class="min-h-screen hanami-bg text-slate-950 flex items-center justify-center")):
    text "Loading..."
