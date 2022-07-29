# Package

version       = "0.1.0"
author        = "panno"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["nimweb"]


# Dependencies

requires "nim >= 1.5.1"
requires "jwt"
requires "bcrypt"

# requires "httpigeon"
requires "https://github.com/panno8M/httpigeon.git"

task deployClient, "compile client-side code with webpack":
  exec "cd client; webpack --mode development"
task runClient, "run client-side devel server":
  exec "cd client; webpack serve --content-base htdocs --mode development"

# 以下データベースのパスに依存。ただのshスクリプトなので、よしなに変えてください。
task initialize, "":
  exec """
  sudo /opt/lampp/bin/mariadb -uroot < initEnv.sql

  if [ -d works ]; then
    rm -f works/*
  else
    mkdir works
  fi

  if [ -d worksDefault ]; then
    cp worksDefault/* works
  fi
  """

task prepare, "":
  exec "sudo /opt/lampp/xampp startmysql"

task db, "":
  exec "sudo /opt/lampp/bin/mariadb -uroot"