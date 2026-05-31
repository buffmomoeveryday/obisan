import mummy/routers

template withMiddleware(router: Router, middlewareChain: expr, body: untyped) =
  template get(r: Router, path: string, handler: HttpHandler) =
    r.get(path, middlewareChain(handler))

  template post(r: Router, path: string, handler: HttpHandler) =
    r.post(path, middlewareChain(handler))
