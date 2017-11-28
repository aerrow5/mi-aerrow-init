# Disable unused service
# Tip from http://blog.brianewell.com/the-base-smartos-zone/
/usr/sbin/svcadm disable svc:/network/inetd:default
/usr/sbin/svcadm disable svc:/system/sac:default
