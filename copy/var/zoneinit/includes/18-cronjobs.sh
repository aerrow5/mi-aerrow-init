# create cronjob for ssl-expire script
CRON='0 9 * * 1 /opt/local/bin/ssl-expire.sh
15 * * * * /opt/local/bin/check-log /var/adm/messages "(znapzend.*ERROR)"
'
(crontab -l 2>/dev/null || true; echo "$CRON" ) | sort | uniq | crontab
