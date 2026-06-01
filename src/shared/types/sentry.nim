type
  EnvelopeHeader* = object
    event_id*: string

  ItemHeader* = object
    `type`*: string
    length*: int

  SentryStackFrame* = object
    filename*: string
    function*: string
    lineno*: int
    abs_path*: string
    module*: string
    context_line*: string
    in_app*: bool

  SentryStacktrace* = object
    frames*: seq[SentryStackFrame]

  SentryExceptionDetails* = object
    `type`*: string
    value*: string
    stacktrace*: SentryStacktrace

  SentryExceptionBlock* = object
    values*: seq[SentryExceptionDetails]

  SentryBreadcrumb* = object
    timestamp*: float
    `type`*: string
    category*: string
    level*: string
    message*: string

  SentryBreadcrumbBlock* = object
    values*: seq[SentryBreadcrumb]

  SentryEventPayload* = object
    platform*: string
    level*: string
    message*: string
    exception*: SentryExceptionBlock
    breadcrumbs*: SentryBreadcrumbBlock
