import db_mysql
import ../extensions
import options
export db_mysql


var
  db {.threadvar.}: DbConn
  dbHandle* {.threadvar.}: ptr DbConn

proc dbOperationExt*(connection, user, password, database: string): Extension = 
  Extension(
    perThreadInitialization: some( proc() {.gcsafe.} =
      db = open(connection, user, password, database)
      dbHandle = db.addr
    )
  )