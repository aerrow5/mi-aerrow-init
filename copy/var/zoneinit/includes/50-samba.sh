#!/usr/bin/bash
#
# Initialize the Samba server

/usr/sbin/svcadm enable samba:nmbd		
/usr/sbin/svcadm enable samba:smbd		
/usr/sbin/svcadm enable dns/multicast
