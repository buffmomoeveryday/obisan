import kraut
import karax/[karax, karaxdsl, vdom]
import ./pages/[login]


const routes = {
  "/": login.render,
}

let renderer = routeRenderer(routes)
proc render(routerData: RouterData): VNode =
  buildHtml(tdiv):
    renderer(routerData)

setRenderer(render)
