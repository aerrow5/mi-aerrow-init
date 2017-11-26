if [ ! -d /var/mysql/mysql ]; then
	cd /var/mysql && mysqld --initialize-insecure
fi
