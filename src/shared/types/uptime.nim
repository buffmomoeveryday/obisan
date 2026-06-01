type
  UptimeMonitorRequest* = object
    name*: string
    url*: string
    timeoutMs*: int
    retryCount*: int
    intervalSecs*: int
    enabled*: bool

  UptimeMonitorUpdateRequest* = object
    name*: string
    url*: string
    timeoutMs*: int
    retryCount*: int
    intervalSecs*: int
    enabled*: bool
