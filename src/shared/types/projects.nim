type
  ProjectResponse* = object
    id*: string
    name*: string
    publicKey*: string
    dsn*: string

  ProjectsListResponse* = object
    projects*: seq[ProjectResponse]
