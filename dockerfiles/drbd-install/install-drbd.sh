#!/bin/sh
set -e

# default parameters
[ -z "$KERNEL_VERSION" ] && KERNEL_VERSION="$(uname -r)"
VERSION="8.4.10-1"
UTILS_VERSION="9.1.0-1"


install_drbd_dkms() {

    if ! yum -y install "kernel-devel-uname-r == $KERNEL_VERSION"; then
        >&2 echo "Error: Can not found kernel-headers for current kernel"
        >&2 echo "       try to ugrade kernel package then reboot your system"
        >&2 echo "       or install kernel-headers package manually"
        exit 1
    fi

    # install dkms
    rpm -q dkms || yum -y install dkms
    
    # install drbd-dkms module
    if ! dkms status -m drbd -v "$VERSION" | grep -q "."; then

        rm -rf "$CHROOT/usr/src/drbd-$VERSION"
        curl "http://www.linbit.com/www.linbit.com/downloads/drbd/8.4/drbd-$VERSION.tar.gz" | tar -xzf - -C "$CHROOT/usr/src"
        
        patch -d "$CHROOT/usr/src/drbd-$VERSION" -p1 < add-RHEL74-compat-hack.patch
        
        cat > "$CHROOT/usr/src/drbd-$VERSION/dkms.conf" << EOF
PACKAGE_NAME="drbd"
PACKAGE_VERSION="$VERSION"
MAKE[0]="make -C drbd"
BUILT_MODULE_NAME[0]=drbd
DEST_MODULE_LOCATION[0]=/kernel/drivers/block
BUILT_MODULE_LOCATION[0]=drbd
CLEAN="make -C drbd clean"
AUTOINSTALL=yes
EOF
    
        dkms add "drbd/$VERSION"
    fi

    dkms install "drbd/$VERSION"
}

install_drbd_utils() {
    yum -y install "http://elrepo.org/linux/elrepo/el7/x86_64/RPMS/drbd84-utils-$UTILS_VERSION.el7.elrepo.x86_64.rpm"
}

# if chroot is set, use yum and rpm from chroot
if [ ! -z "$CHROOT" ]; then
    alias rpm="chroot $CHROOT rpm"
    alias yum="chroot $CHROOT yum"
    alias dkms="chroot $CHROOT dkms"
fi

# check for distro
if [ "$(sed 's/.*release\ //' "$CHROOT/etc/redhat-release" | cut -d. -f1)" != "7" ]; then
    >&2 echo "Error: Host system not supported"
    exit 1
fi

# check for module
if ! (find "$CHROOT/lib/modules/$KERNEL_VERSION" -name drbd.ko | grep -q "."); then
    install_drbd_dkms
fi

# check for drbd-utils
if ! chroot "${CHROOT:-/}" command -v drbdadm; then
    install_drbd_utils
fi

# final check for module
if ! (find "$CHROOT/lib/modules/$KERNEL_VERSION" -name drbd.ko | grep -q "."); then
     >&2 echo "Error: Can not found installed drbd module for current kernel"
     exit 1
fi

echo "Success!"