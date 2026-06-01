import mummy
import std/[strformat, strutils]

proc requestHost*(request: Request): string =
  if "Host" in request.headers:
    request.headers["Host"]
  else:
    "localhost:8080"

proc requestProtocol*(request: Request): string =
  if "X-Forwarded-Proto" in request.headers:
    let proto = request.headers["X-Forwarded-Proto"].toLowerAscii()
    if proto == "https":
      return "https"
  "http"

proc requestHeader*(request: Request, name: string): string =
  if name in request.headers:
    result = request.headers[name]

proc buildProjectDsn*(request: Request, publicKey, projectId: string): string =
  &"{requestProtocol(request)}://{publicKey}@{requestHost(request)}/{projectId}"
