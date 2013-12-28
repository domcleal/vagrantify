#!/bin/bash -x

cp cloud-init.dat $BODI_CHROOT_PATH
DEBCONF_DB_OVERRIDE='File {/cloud-init.dat}' \
  chroot $BODI_CHROOT_PATH dpkg-reconfigure -fnoninteractive cloud-init
