include karax/prelude

import kraut

proc render*(context: Context): VNode =
  buildHtml(tdiv):
    text "User id: " & context.urlParams["userId"]
