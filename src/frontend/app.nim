import kraut
import karax/[karax, karaxdsl, vdom]
import ./pages/[dashboard, home, invite, issue, login, logs, metrics, project, register, settings, uptime]
import ./utils/auth


const routes = {
  "/": home.render,
  "/register": register.render,
  "/login": login.render,
  "/dashboard": dashboard.render,
  "/settings": settings.render,
  "/invite": invite.renderWorkspace,
  "/projects/{id}": project.render,
  "/projects/{id}/invite": invite.render,
  "/projects/{id}/logs": logs.render,
  "/projects/{id}/metrics": metrics.render,
  "/projects/{id}/uptime": uptime.render,
  "/projects/{id}/issues/{eventId}": issue.render,
}

let renderer = routeRenderer(routes, home.render)
proc render(routerData: RouterData): VNode =
  buildHtml(tdiv):
    renderer(routerData)

syncThemeFromDom()
setRenderer(render)
loadSetupStatus()
bootstrapSession()
