# Get internal and external ip of vm
IP_EXTERNAL=$(mdata-get sdc:nics | /usr/bin/json -ag ip -c 'this.nic_tag === "external"' 2>/dev/null);
IP_INTERNAL=$(mdata-get sdc:nics | /usr/bin/json -ag ip -c 'this.nic_tag === "internal"' 2>/dev/null);

# Get mysql_password from metadata if exists, or use mysql_pw, or set one.
log "getting mysql_password"
if [[ $(mdata-get mysql_password &>/dev/null)$? -eq "0" ]]; then
    MYSQL_PW=$(mdata-get mysql_password 2>/dev/null);
    mdata-put mysql_pw ${MYSQL_PW}
elif [[ $(mdata-get mysql_pw &>/dev/null)$? -eq "0" ]]; then
    MYSQL_PW=$(mdata-get mysql_pw 2>/dev/null);
else
    MYSQL_PW=$(od -An -N8 -x /dev/random | head -1 | tr -d ' ');
    mdata-put mysql_pw ${MYSQL_PW}
fi

# Get mysql_server_id from metadata if exists
log "getting mysql_server_id"
if [[ $(mdata-get mysql_server_id &>/dev/null)$? -eq "0" ]]; then
    MYSQL_SERVER_ID=$(mdata-get mysql_server_id 2>/dev/null);
    gsed -i "/^server-id/s/server-id.*/server-id = ${MYSQL_SERVER_ID}/" /opt/local/etc/my.cnf
fi

# Generate svccfg happy password for quickbackup-percona
# (one without special characters)
log "getting qb_pw"
QB_PW=${QB_PW:-$(mdata-get mysql_qb_pw 2>/dev/null)} || \
QB_PW=$(od -An -N8 -x /dev/random | head -1 | sed 's/^[ \t]*//' | tr -d ' ');
QB_US=qb-$(zonename | awk -F\- '{ print $5 }');

# Be sure the generated MYSQL_PW password set also as mdata
# information.
mdata-put mysql_pw    "${MYSQL_PW}"
mdata-put mysql_qb_pw "${QB_PW}"

# Workaround for using DHCP so IP_INTERNAL or IP_EXTERNAL is empty
if [ -z "${IP_INTERNAL}" ] || [ -z "${IP_EXTERNAL}" ]; then
    IP_INTERNAL="127.0.0.1"
fi

# Default query to lock down access and clean up
MYSQL_INIT="DELETE from mysql.user;
DELETE FROM mysql.proxies_priv WHERE Host='base.joyent.us';
GRANT ALL on *.* to 'root'@'localhost' identified by '${MYSQL_PW}' with grant option;
GRANT ALL on *.* to 'root'@'${IP_INTERNAL:-${IP_EXTERNAL}}' identified by '${MYSQL_PW}' with grant option;
GRANT LOCK TABLES,SELECT,RELOAD,SUPER,PROCESS,REPLICATION CLIENT on *.* to '${QB_US}'@'localhost' identified by '${QB_PW}';
FLUSH PRIVILEGES;
FLUSH TABLES;"

# MySQL my.cnf tuning
MEMCAP=$(( ${RAM_IN_BYTES} / 1024 / 1024 ));

# innodb_buffer_pool_size
INNODB_BUFFER_POOL_SIZE=$(echo -e "scale=0; ${MEMCAP}/2"|bc)M

# back_log
BACK_LOG=64
[[ ${MEMCAP} -gt 8000 ]] && BACK_LOG=128

# max_connections
[[ ${MEMCAP} -lt 1000 ]] && MAX_CONNECTIONS=200
[[ ${MEMCAP} -gt 1000 ]] && MAX_CONNECTIONS=500
[[ ${MEMCAP} -gt 2000 ]] && MAX_CONNECTIONS=1000
[[ ${MEMCAP} -gt 3000 ]] && MAX_CONNECTIONS=2000
[[ ${MEMCAP} -gt 5000 ]] && MAX_CONNECTIONS=5000

# thread_cache_size
THREAD_CACHE_SIZE=$((${MAX_CONNECTIONS}/2))
[[ ${THREAD_CACHE_SIZE} -gt 1000 ]] && THREAD_CACHE_SIZE=1000

log "tuning MySQL configuration"
gsed -i \
        -e "s/bind-address = 127.0.0.1/bind-address = ${IP_INTERNAL:-${IP_EXTERNAL}}/" \
        -e "s/back_log = 64/back_log = ${BACK_LOG}/" \
        -e "s/thread_cache_size = 1000/thread_cache_size = ${THREAD_CACHE_SIZE}/" \
        -e "s/max_connections = 1000/max_connections = ${MAX_CONNECTIONS}/" \
        -e "s/net_buffer_length = 2K/net_buffer_length = 16384/" \
        -e "s/innodb_buffer_pool_size = [0-9]*M/innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE}/" \
        -e "s/#query_cache_size = 16M/query_cache_size = 16M/" \
        -e "s/#query_cache_strip_comments/query_cache_strip_comments/" \
        -e "s/query_cache_type = 0/query_cache_type = 1/" \
        /opt/local/etc/my.cnf

log "configuring Quickbackup"
svccfg -s quickbackup-percona setprop quickbackup/username = astring: ${QB_US}
svccfg -s quickbackup-percona setprop quickbackup/password = astring: ${QB_PW}
svcadm refresh quickbackup-percona
touch /var/log/mysql/quickbackup-percona.log

log "shutting down an existing instance of MySQL"
if [[ "$(svcs -Ho state percona)" == "online" ]]; then
        svcadm disable -t percona
        sleep 2
fi

log "starting the new MySQL instance"
svcadm enable percona

log "waiting for the socket to show up"
COUNT="0";
while [[ ! -e /tmp/mysql.sock ]]; do
        sleep 1
        ((COUNT=COUNT+1))
        if [[ $COUNT -eq 60 ]]; then
          log "ERROR Could not talk to MySQL after 60 seconds"
    ERROR=yes
    break 1
  fi
done
[[ -n "${ERROR}" ]] && exit 31
log "(it took ${COUNT} seconds to start properly)"

sleep 1

[[ "$(svcs -Ho state percona)" == "online" ]] || \
  ( log "ERROR MySQL SMF not reporting as 'online'" && exit 31 )

log "import zoneinfo to mysql db"
mysql_tzinfo_to_sql /usr/share/lib/zoneinfo | mysql mysql

log "running the access lockdown SQL query"
if [[ $(mysql -uroot -e "select version()" &>/dev/null)$? -eq "0" ]]; then
  mysql -u root -e "${MYSQL_INIT}" >/dev/null || ( log "ERROR MySQL query failed to execute." && exit 31; )
else
  log "Can't login with no password set, continuing.";
fi

# Create username and password file for root user
log "create my.cnf for root user"
cat > /root/.my.cnf <<EOF
[client]
host = localhost
user = root
password = ${MYSQL_PW}
EOF
