import mummy

proc newHtmlHeaders*(): HttpHeaders =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  result = headers

proc newJsonHeaders*(): HttpHeaders =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  result = headers

proc newJsHeaders*(): HttpHeaders =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/javascript; charset=utf-8"
  result = headers

proc toGcsafeHandler*(h: proc(request: Request)): proc(request: Request) {.gcsafe.} =
  proc (request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      h(request)
