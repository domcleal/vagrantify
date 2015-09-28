# vagrant-builder

Wrapper script around [virt-builder](http://libguestfs.org/virt-builder.1.html)
from the libguestfs suite.

This generates a vagrant-libvirt compatible image based on the pre-built
templates that virt-builder can consume (and publishes).

Unfortunately many of the images are bigger than the cloud images, so if you're
trying to minimise the image sizes, then this may not be best.

# vagrantify

Contains scripts to create Vagrant boxes for vagrant-libvirt.  I'm only
interested in:

* RHEL, CentOS
* Fedora
* Debian stable, oldstable
* Ubuntu LTS
* Puppet and non-Puppet

## Converting "cloud" images

Fedora, RHEL and other distros [produce qcow2
images](http://cloud.fedoraproject.org/) suitable for OpenStack or
libvirt, but they don't contain the vagrant user and are set up to run
cloud-init on boot.

Instead of altering the cloud images, the Vagrant-specific changes are be
applied via cloud-init when the image boots up.  While this minimises changes
to the image, the downside is boot speed (if needing to install Puppet).

The problem is that libvirt has no cloud-init support itself.  Rich Jones
[describes](http://rwmj.wordpress.com/2013/12/10/creating-a-cloud-init-config-disk-for-non-cloud-boots/#content)
how to boot a cloud image under libvirt using a cloud-init config disk, but
this would involve changes to vagrant-libvirt to configure the libvirt domain
correctly.

Instead, vagrantify injects cloud user-data into the image's filesystem and
cloud-init picks this up at boot as a first class datasource.

### Compatibility

Tested with:

* Fedora 19, 20 images: [cloud.fedoraproject.org](http://cloud.fedoraproject.org/)
* RHEL 6.5 image: [Customer Portal](https://rhn.redhat.com/rhn/software/channel/downloads/Download.do?cid=16952)
* CentOS 6.4 OpenStack image: [centos.org](http://dev.centos.org/centos/hvm/)
* Debian 8 (Jessie) image: [debian.org](http://cdimage.debian.org/cdimage/openstack/current/)
* Debian 7 (Wheezy) image: [openstack-debian-images](http://packages.debian.org/openstack-debian-images)
* Ubuntu 12.04 image: [cloud-images.ubuntu.com](http://cloud-images.ubuntu.com/precise/current/)

### Building Debian images

Copy `debian/*` to `/root/` and run:

    build-openstack-debian-image -r wheezy -u http://ftp.uk.debian.org/debian -s http://ftp.uk.debian.org/debian -hs /root/cloud-init.sh

The hook script reconfigures cloud-init to use a NoCloud datasource.
