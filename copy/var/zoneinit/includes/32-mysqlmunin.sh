#!/bin/bash
# Create extra plugin information for mysql_ munin scripts

cat >> /opt/local/etc/munin/plugin-conf.d/mysql <<EOF
[mysql_*]
user root
env.mysqluser root
env.mysqlpassword $(mdata-get mysql_pw)
env.mysqladmin /opt/local/bin/mysqladmin
env.mysqlopts --defaults-extra-file=/root/.my.cnf
EOF
