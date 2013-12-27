#!/bin/bash
set -e

usage() {
    cat >&2 << EOF
usage: $0 [opts] <disk>

required arguments:
  disk             path to cloud image disk

optional arguments:
  -b <os-variant>  boot, run cloud-init and replace image
                   (virt-install OS variant, see \`virt-install --os-variant list\`)
  -e               configure EPEL repo
  -l               configure Puppet Labs repo
  -p               install puppet
  -s               run virt-sparsify, ensure temp is big enough for resized disk
  -u               upgrade packages in cloud-init
  -z <size>        resize disk to size (e.g. -z 10G)
EOF
    exit 1
}

PACKAGE_UPGRADE=
PUPPET=
REBUILD=
REPO_EPEL=
REPO_PL=
RESIZE=
SPARSIFY=

while getopts ":belpsuz:" o; do
    case $o in
        b) REBUILD=yes; OS_VARIANT=$OPTARG ;;
        e) REPO_EPEL=yes ;;
        l) REPO_PL=yes ;;
        p) PUPPET=yes ;;
        s) SPARSIFY=yes ;;
        u) PACKAGE_UPGRADE=yes ;;
        z) RESIZE=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

[ $# -lt 1 ] && usage
DISK=$1

GUESTFISH_PID=
eval "`guestfish --listen -i -a $DISK`"
if [ -z "$GUESTFISH_PID" ]; then
    echo "error: guestfish didn't start up, see error messages above"
    exit 1
fi
TMPDIR=$(mktemp -d)

cleanup () {
    guestfish --remote -- exit >/dev/null 2>&1 ||:
    rm -rf $TMPDIR
}
trap cleanup EXIT ERR

guestfish --remote -- mkdir-p /var/lib/cloud/seed/nocloud-net
guestfish --remote -- touch /var/lib/cloud/seed/nocloud-net/meta-data

cat > $TMPDIR/user-data << EOF
#cloud-config
packages:
  - curl
  - rsync
  - which
EOF
[ -n "$PUPPET" ] && echo "  - puppet" >> $TMPDIR/user-data
cat >> $TMPDIR/user-data << EOF
users:
  - name: vagrant
    gecos: Vagrant User
    groups: users
    ssh-authorized-keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key
    lock-passwd: false
    passwd: \$1\$rP8l.Eft\$BPzhFx/gjhZ8lj.N7jHF30
write_files:
  - content: |
      vagrant ALL=(ALL) NOPASSWD:ALL
      Defaults:vagrant !requiretty
    path: /etc/sudoers.d/10-vagrant
    permissions: '0600'
runcmd:
  - [ sh, -c, echo DHCP_HOSTNAME=localhost >> /etc/sysconfig/network-scripts/ifcfg-eth0 ]
EOF
[ -n "$REBUILD" ] && echo "  - shutdown -h +1" >> $TMPDIR/user-data
[ -n "$PACKAGE_UPGRADE" ] && echo "package_upgrade: true" >> $TMPDIR/user-data

echo "yum_repos:" >> $TMPDIR/user-data
if [ -n "$REPO_EPEL" ]; then
    cat >> $TMPDIR/user-data << EOF
  epel:
    name: Extra Packages for Enterprise Linux 6 - \$basearch
    baseurl: http://download.fedoraproject.org/pub/epel/6/\$basearch
    mirrorlist: https://mirrors.fedoraproject.org/metalink?repo=epel-6&arch=\$basearch
    failovermethod: priority
    enabled: 1
    gpgcheck: 1
    gpgkey: https://fedoraproject.org/static/0608B895.txt
  epel-testing:
    name: Extra Packages for Enterprise Linux 6 - Testing - \$basearch
    baseurl: http://download.fedoraproject.org/pub/epel/testing/6/\$basearch
    mirrorlist: https://mirrors.fedoraproject.org/metalink?repo=testing-epel6&arch=\$basearch
    failovermethod: priority
    enabled: 1
    gpgcheck: 1
    gpgkey: https://fedoraproject.org/static/0608B895.txt
EOF
fi
if [ -n "$REPO_PL" ]; then
    cat >> $TMPDIR/user-data << EOF
  puppetlabs-products:
    name: Puppet Labs Products El 6 - \$basearch
    baseurl: http://yum.puppetlabs.com/el/6/products/\$basearch
    gpgkey: http://yum.puppetlabs.com/RPM-GPG-KEY-puppetlabs
    enabled: 1
    gpgcheck: 1
  puppetlabs-deps:
    name: Puppet Labs Dependencies El 6 - \$basearch
    baseurl: http://yum.puppetlabs.com/el/6/dependencies/\$basearch
    gpgkey: http://yum.puppetlabs.com/RPM-GPG-KEY-puppetlabs
    enabled: 1
    gpgcheck: 1
  puppetlabs-devel:
    name: Puppet Labs Devel El 6 - \$basearch
    baseurl: http://yum.puppetlabs.com/el/6/devel/\$basearch
    gpgkey: http://yum.puppetlabs.com/RPM-GPG-KEY-puppetlabs
    enabled: 1
    gpgcheck: 1
EOF
fi
guestfish --remote -- upload $TMPDIR/user-data /var/lib/cloud/seed/nocloud-net/user-data
cat > $TMPDIR/cloud.cfg << EOF
cloud_init_modules:
  - yum_add_repo
cloud_config_modules:
  - package_update_upgrade_install
  - runcmd
  - users_groups
  - write-files
EOF
guestfish --remote -- upload $TMPDIR/cloud.cfg /etc/cloud/cloud.cfg.d/10_vagrantify.cfg
guestfish --remote -- exit

[ -n "$RESIZE" ] && qemu-img resize $DISK $RESIZE

if [ -n "$REBUILD" ]; then
    virt-install --name vagrantify --ram 1024 --import \
                 --os-type linux --os-variant $OSVARIANT \
                 --disk path=${DISK},format=qcow2
    operations=$(virt-sysprep --list-operations | awk '/*/ && ! /ssh-userdir/ { printf $1 "," }')
    virt-sysprep --enable ${operations%,} --connect qemu:///session -d vagrantify
    virsh --connect qemu:///session dumpxml vagrantify > ${DISK}.xml
    virsh --connect qemu:///session undefine vagrantify
    [ -n "$SPARSIFY" ] && virt-sparsify $DISK ${DISK}.out
    mv ${DISK}.out $DISK
fi

echo Finished modifying $DISK
