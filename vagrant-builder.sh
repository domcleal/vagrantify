#!/bin/bash
set -e

usage() {
    cat >&2 << EOF
usage: $0 [opts] -- [virt-builder opts] <template>

required arguments:
  template           name of virt-builder template

optional arguments:
  -e                 configure EPEL repo
  -l                 configure Puppet Labs repo
  -p                 install puppet
  virt-builder opts  options after -- are passed straight to virt-builder
EOF
    exit 1
}

PUPPET=
REPO_EPEL=
REPO_PL=

while getopts ":elp-" o; do
    case $o in
        e) REPO_EPEL=yes ;;
        l) REPO_PL=yes ;;
        p) PUPPET=yes ;;
        -) break ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

[ $# -lt 1 ] && usage

TMPDIR=$(mktemp -d)
cleanup () {
    rm -rf $TMPDIR
}
trap cleanup EXIT ERR

cat > $TMPDIR/firstboot << EOF
#!/bin/bash
set -xe

PUPPET=$PUPPET
REPO_EPEL=$REPO_EPEL
REPO_PL=$REPO_PL
PACKAGE=rpm
[ -x /usr/bin/dpkg ] && PACKAGE=deb

if [ \$PACKAGE = rpm -a -n "\$REPO_EPEL" ]; then
    rpm -q fedora-release || rpm -ivh http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm
fi
if [ -n "\$REPO_PL" ]; then
    if [ \$PACKAGE = rpm ]; then
        if rpm -q fedora-release; then
            rpm -ivh http://yum.puppetlabs.com/puppetlabs-release-fedora-\$(rpm -q --qf "%{VERSION}" fedora-release).noarch.rpm
        else
            rpm -ivh http://yum.puppetlabs.com/puppetlabs-release-el-6.noarch.rpm
        fi
    elif [ \$PACKAGE = deb ]; then
        wget -O /tmp/pl-release.deb http://apt.puppetlabs.com/puppetlabs-release-\$(lsb_release -cs).deb
        dpkg -i /tmp/pl-release.deb
        rm -f /tmp/pl-release.deb
        sed -i '/devel$/ s/^# *//' /etc/apt/sources.list.d/puppetlabs.list
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
fi

if [ \$PACKAGE = deb ]; then
    dpkg-reconfigure openssh-server
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

exit 0
EOF

virt-builder \
    --firstboot $TMPDIR/firstboot \
    --root-password password:vagrant \
    --format qcow2 \
    $*
