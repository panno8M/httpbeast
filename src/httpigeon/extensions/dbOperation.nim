import db_mysql
import ../extensions
import options
export db_mysql

from os import sleep
import random

var
  db {.threadvar.}: DbConn
  dbHandle* {.threadvar.}: ptr DbConn

randomize()

proc startTransaction*(db: DbConn) {.inline, raises: [DbError].} =
  db.exec(sql"START TRANSACTION")
proc startTransaction*(db: ptr DbConn) {.inline, raises: [DbError].} =
  db[].exec(sql"START TRANSACTION")
proc commit*(db: DbConn) {.inline, raises: [DbError].} =
  db.exec(sql"COMMIT")
proc commit*(db: ptr DbConn) {.inline, raises: [DbError].} =
  db[].exec(sql"COMMIT")
proc rollback*(db: DbConn) {.inline, raises: [DbError].} =
  db.exec(sql"ROLLBACK")
proc rollback*(db: ptr DbConn) {.inline, raises: [DbError].} =
  db[].exec(sql"ROLLBACK")
proc selectLastInsertId*(db: DbConn): string {.inline, raises: [DbError].} =
  db.getValue(sql"SELECT LAST_INSERT_ID()")
proc selectLastInsertId*(db: ptr DbConn): string {.inline, raises: [DbError].} =
  db[].getValue(sql"SELECT LAST_INSERT_ID()")

proc dbOperationExt*(connection, user, password, database: string): Extension =
  Extension(
    perThreadInitialization: some( proc() {.gcsafe.} =
      {.gcsafe.}:
        db = try:
          sleep(rand(100))
          open(connection, user, password, database)
        except DbError:
          sleep(rand(100))
          open(connection, user, password, database)
        dbHandle = db.addr
    )
  )