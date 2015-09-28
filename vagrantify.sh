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
#!/bin/bash
set -xe

PUPPET=$PUPPET
REBUILD=$REBUILD
REPO_EPEL=$REPO_EPEL
REPO_PL=$REPO_PL
PACKAGE=rpm
[ -x /usr/bin/dpkg ] && PACKAGE=deb
[ \$PACKAGE = rpm ] && OSMAJ=\$(rpm -q --qf "%{VERSION}" --whatprovides redhat-release | grep -o '^[0-9]*')

if [ \$PACKAGE = rpm -a -n "\$REPO_EPEL" ] && ! rpm -q fedora-release; then
    cat <<EOM >/etc/yum.repos.d/epel-bootstrap.repo
[epel]
name=Bootstrap EPEL
mirrorlist=http://mirrors.fedoraproject.org/mirrorlist?repo=epel-\\\$releasever&arch=\\\$basearch
failovermethod=priority
enabled=0
gpgcheck=0
EOM
    yum --enablerepo=epel -y install epel-release
    rm -f /etc/yum.repos.d/epel-bootstrap.repo
fi
if [ -n "\$REPO_PL" ]; then
    if [ \$PACKAGE = rpm ]; then
        if rpm -q fedora-release; then
            rpm -ivh http://yum.puppetlabs.com/puppetlabs-release-fedora-\${OSMAJ}.noarch.rpm
        else
            rpm -ivh http://yum.puppetlabs.com/puppetlabs-release-el-\${OSMAJ}.noarch.rpm
        fi
    elif [ \$PACKAGE = deb ]; then
        wget -O /tmp/pl-release.deb http://apt.puppetlabs.com/puppetlabs-release-\$(lsb_release -cs).deb
        dpkg -i /tmp/pl-release.deb
        rm -f /tmp/pl-release.deb
        sed -i '/devel$/ s/^# *//' /etc/apt/sources.list.d/puppetlabs.list
    fi
fi

# F19 cloud image has an SELinux policy bug affecting transitions from cloud-init
if [ \$PACKAGE = rpm ]; then
    ENFORCE=\$(getenforce)
    if [ x\${OSMAJ} = x19 ]; then
        setenforce 0
    fi
fi

if [ \$PACKAGE = rpm ]; then
    yum -y install curl rsync yum-utils which sudo
elif [ \$PACKAGE = deb ]; then
    apt-get update
    apt-get install -y curl rsync sudo
fi

if [ \$PACKAGE = rpm ]; then
    yum-config-manager --enable epel-testing puppetlabs-devel
    echo DHCP_HOSTNAME=localhost >> /etc/sysconfig/network-scripts/ifcfg-eth0
    [ -n "\$PACKAGE_UPGRADE" ] && yum -y upgrade
else
    dpkg-reconfigure openssh-server
    [ -n "\$PACKAGE_UPGRADE" ] && apt-get dist-upgrade -y
fi

if [ -n "\$PUPPET" ]; then
    if [ \$PACKAGE = rpm ]; then
        yum -y install puppet
    elif [ \$PACKAGE = deb ]; then
        apt-get install -y puppet
    fi
fi

cat > /etc/sudoers.d/10-vagrant << EOS
vagrant ALL=(ALL) NOPASSWD:ALL
Defaults:vagrant !requiretty
EOS
chmod 0600 /etc/sudoers.d/10-vagrant

useradd -c "Vagrant User" \
        -G users -m \
        -p '\$1\$rP8l.Eft\$BPzhFx/gjhZ8lj.N7jHF30' \
        vagrant
mkdir -m0700 ~vagrant/.ssh
echo 'ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key' > ~vagrant/.ssh/authorized_keys
chmod 0400 ~vagrant/.ssh/authorized_keys
chown -R vagrant:vagrant ~vagrant/.ssh
restorecon -Rvv ~vagrant/.ssh || true

[ -n "\$ENFORCE" ] && setenforce \$ENFORCE

[ -n "\$REBUILD" ] && shutdown -h +1

exit 0
EOF
guestfish --remote -- upload $TMPDIR/user-data /var/lib/cloud/seed/nocloud-net/user-data

cat > $TMPDIR/cloud.cfg << EOF
# Installed by vagrantify
datasource_list: [NoCloud, NoCloudNet]
EOF
guestfish --remote -- upload $TMPDIR/cloud.cfg /etc/cloud/cloud.cfg.d/95_vagrantify.cfg

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
