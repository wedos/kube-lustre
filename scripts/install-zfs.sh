#!/bin/sh
set -e
SOURCES_DIR="${SOURCES_DIR:-$CHROOT/usr/src/kube-lustre}"

cleanup_wrong_versions() {
    WRONG_PACKAGES="$(rpm -qa zfs kmod-zfs kmod-spl kmod-zfs kmod-spl-devel kmod-zfs-devel zfs-dkms zfs-dracut zfs-test libzpool2 libzfs2-devel libzfs2 libuutil1 libnvpair1 spl spl-dkms zfs-test | grep -v "$1" | xargs)"
    [ -z "$WRONG_PACKAGES" ] || yum -y remove $WRONG_PACKAGES
}

# if chroot is set, use yum and rpm from chroot
if [ ! -z "$CHROOT" ]; then
    alias rpm="chroot $CHROOT rpm"
    alias yum="chroot $CHROOT yum"
    alias dkms="chroot $CHROOT dkms"
fi

# check for distro
if [ "$(sed 's/.*release\ //'  /etc/redhat-release | cut -d. -f1)" != "7" ]; then
    >&2 echo "Error: Host system not supported"
    exit 1
fi

rpm -q --quiet epel-release || yum -y install epel-release


if [ "$MODE" == "from-repo" ]; then

    rpm -q zfs-release || yum -y install --nogpgcheck http://download.zfsonlinux.org/epel/zfs-release.el7.noarch.rpm

    case "$TYPE" in
        kmod) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs-kmod\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo ;;
        kmod-testing) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs-testing-kmod\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo && TYPE=kmod ;;
        dkms) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo ;;
        dkms-testing) sed -e 's/^enabled=.\?/enabled=0/' -e '/\[zfs-testing\]/,/^\[.*\]$/ s/^enabled=.\?/enabled=1/' -i /etc/yum.repos.d/zfs.repo && TYPE=dkms ;;
        *) 
            >&2 echo "Error: Please specify TYPE variable"
            >&2 echo "       TYPE=<dkms|kmod|dkms-testing|kmod-testing>"
            exit 1
        ;;
    esac

elif [ "$MODE" == "from-source" ]; then

    if [ "$TYPE" != "kmod" ] && [ "$TYPE" != "dkms" ]; then
        >&2 echo "Error: Please specify TYPE variable"
        >&2 echo "       TYPE=<dkms|kmod>"
        exit 1
    fi

else
    >&2 echo "Error: Please specify MODE variable"
    >&2 echo "       MODE=<from-repo|from-source>"
    exit 1
fi

# install kernel-headers
if ! ( [ "$MODE" == "from-repo" ] && [ "$TYPE" == "kmod" ] ) && [ ! -d "$CHROOT/lib/modules/$(uname -r)/build" ]; then
    if ! yum install "kernel-devel-uname-r == $(uname -r)"; then
        >&2 echo "Error: Can not found kernel-headers for current kernel"
        >&2 echo "       try to ugrade kernel then reboot your system"
        >&2 echo "       or install kernel-headers package manually"
        exit 1
    fi
fi

# install packages
if [ "$MODE" == "from-repo" ]; then

    VERSION="$(yum list zfs | tail -n 1 | awk '{print $2}' | cut -d- -f1)"

    case "$TYPE" in
        kmod )
            if [ "$AUTO_UPDATE" != "1" ] && rpm -q zfs libzfs2-devel kmod-zfs kmod-spl-devel kmod-zfs-devel; then
                echo "Info: Needed packages already installed"
            else
                yum remove -y zfs-dkms spl-dkms
                cleanup_wrong_versions "$VERSION"
                yum install -y zfs libzfs2-devel kmod-zfs kmod-spl-devel kmod-zfs-devel zfs-dracut
            fi
        ;;
        dkms )
            if [ "$AUTO_UPDATE" != "1" ] && rpm -q zfs libzfs2-devel zfs-dkms spl-dkms; then
                echo "Info: Needed packages already installed"
            else
                yum remove -y kmod-zfs kmod-spl kmod-zfs kmod-spl-devel kmod-zfs-devel zfs-dracut
                cleanup_wrong_versions "$VERSION"
                yum install -y zfs libzfs2-devel zfs-dkms spl-dkms
            fi
        ;;
    esac

elif [ "$MODE" == "from-source" ]; then

    case "$TYPE" in
        kmod ) [ "$(rpm -qa zfs libzfs2-devel kmod-zfs kmod-spl-devel kmod-zfs-devel | grep -c "$VERSION")" == "5" ] || FORCE_REBUILD=1 ;;
        dkms ) [ "$(rpm -qa zfs libzfs2-devel zfs-dkms spl-dkms | grep -c "$VERSION")" == "4" ] || FORCE_REBUILD=1 ;;
    esac

    if [ "$FORCE_REBUILD" != "1" ]; then
        echo "Info: Needed packages already installed and have version $VERSION"
    else
        yum -y groupinstall 'Development Tools'
        yum -y install git zlib-devel libattr-devel libuuid-devel libblkid-devel libselinux-devel libudev-devel

        mkdir -p "$SOURCES_DIR"
        [ -d "$SOURCES_DIR/spl" ] || git clone https://github.com/zfsonlinux/spl.git "$SOURCES_DIR/spl"
        [ -d "$SOURCES_DIR/zfs" ] || git clone https://github.com/zfsonlinux/zfs.git "$SOURCES_DIR/zfs"

        # Build and install spl packages
        pushd "$SOURCES_DIR/spl"
        git fetch --tags --force
        [ -z "$VERSION" ] && VERSION="$(git tag | head -n 1 | cut -d- -f2)"
        git checkout "spl-$VERSION"
        ./autogen.sh
        ./configure --with-spec=redhat
        rm -f *.rpm
        case "$TYPE" in
            kmod )
                make pkg-utils pkg-kmod
                yum remove -y zfs-dkms spl-dkms
                cleanup_wrong_versions "$VERSION"
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/spl/|" -e "s|^$CHROOT||" )
            ;;
            dkms )
                make pkg-utils rpm-dkms
                yum remove -y kmod-zfs kmod-spl kmod-zfs kmod-spl-devel kmod-zfs-devel
                cleanup_wrong_versions "$VERSION"
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/spl/|" -e "s|^$CHROOT||" )
            ;;
        esac
        popd

        # Build and install zfs packages
        pushd "$SOURCES_DIR/zfs"
        git fetch --tags --force
        git checkout "zfs-$VERSION"
        ./autogen.sh
        ./configure --with-spec=redhat --with-spl-obj="$SOURCES_DIR/spl"
        rm -f *.rpm
        case "$TYPE" in
            kmod )
                make pkg-utils pkg-kmod
                cleanup_wrong_versions
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/zfs/|" -e "s|^$CHROOT||" )
            ;;
            dkms )
                make pkg-utils rpm-dkms
                cleanup_wrong_versions
                yum localinstall -y $(ls -1 *.rpm | grep -v debuginfo | grep -v 'src\.rpm' | sed -e "s|^|$SOURCES_DIR/zfs/|" -e "s|^$CHROOT||" )
            ;;
        esac
        popd

    fi

fi

if [ "$TYPE" == "dkms" ]; then
    # build dkms module
    if ! (dkms install "spl/$VERSION" && dkms install "zfs/$VERSION"); then
         >&2 echo "Error: Can not build zfs dkms module"
         exit 1
    fi
fi

# check for module
if ! (find "$CHROOT/lib/modules/$(uname -r)" -name zfs.ko | grep -q "."); then
     >&2 echo "Error: Can not found installed zfs module for current kernel"
     exit 1
fi

echo "Success"
