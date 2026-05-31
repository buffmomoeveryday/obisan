
type User* = object
  id: string
  name: string
  email:string


type
  LoginRequest* = object
    email*: string
    password*: string

  RegisterRequest* = object
    name*: string
    email*: string
    password*: string
