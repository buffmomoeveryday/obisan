import norm/[model, sqlite, pool]
export model, sqlite, pool

func backendSqlQuery(query: string): SqlQuery =
  SqlQuery(query)

template dbSql*(query: string): SqlQuery =
  backendSqlQuery(query)
