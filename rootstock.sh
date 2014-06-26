#!/bin/sh -ex

if [ "$LOGNAME" = "root" ] \
|| [ "$USER" = "root" ] \
|| [ "$USERNAME" = "root" ] \
|| [ "$SUDO_COMMAND" != "" ] \
|| [ "$SUDO_USER" != "" ] \
|| [ "$SUDO_UID" != "" ] \
|| [ "$SUDO_GID" != "" ]; then
	echo "don't run this script as root - there is no need to"
	exit
fi

if [ "$FAKEROOTKEY" = "" ]; then
        echo "re-executing script inside fakeroot"
        fakeroot $0;
        exit
fi

DIST="sid"
ROOTDIR="debian-$DIST-multistrap"
MIRROR="http://127.0.0.1:3142/ftp.de.debian.org/debian"
MIRROR_REAL="http://ftp.de.debian.org/debian"
#MIRROR="http://127.0.0.1:3142/ftp.debian-ports.org/debian"
#MIRROR_REAL="http://ftp.debian-ports.org/debian"

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C

rm -rf $ROOTDIR $ROOTDIR.tar

PACKAGES="locales udev module-init-tools procps mtd-utils curl wget ntpdate"
PACKAGES=$PACKAGES" screen less vim-tiny console-tools vpnc rsync conspy"
PACKAGES=$PACKAGES" man-db fbset input-utils openssh-server wpasupplicant"
PACKAGES=$PACKAGES" bluez bluez-utils bluez-alsa bluez-gstreamer iputils-ping"
PACKAGES=$PACKAGES" iproute dnsutils nodm xserver-xorg-input-evdev xterm"
PACKAGES=$PACKAGES" xserver-xorg xserver-xorg-video-fbdev"

cat > multistrap.conf << __END__
[General]
#arch=armhf
arch=armel
directory=$ROOTDIR
cleanup=true
unpack=true
noauth=true
#bootstrap=Debian_bootstrap Debian_unreleased
bootstrap=Debian_bootstrap
aptsources=Debian
allowrecommends=false
addimportant=false

[Debian_bootstrap]
packages=$PACKAGES
source=$MIRROR
suite=$DIST
omitdebsrc=true

#[Debian_unreleased]
#packages=$PACKAGES
#source=$MIRROR
#suite=unreleased
#omitdebsrc=true

[Debian]
source=$MIRROR_REAL
keyring=debian-archive-keyring
suite=$DIST
omitdebsrc=true
__END__

multistrap -f multistrap.conf

cp /usr/bin/qemu-arm-static $ROOTDIR/usr/bin

# stop invoke-rc.d from starting services
cat > $ROOTDIR/usr/sbin/policy-rc.d << __END__
#!/bin/sh
echo "sysvinit: All runlevel operations denied by policy" >&2
exit 101
__END__
chmod +x $ROOTDIR/usr/sbin/policy-rc.d

# fix for ldconfig inside fakechroot
mv $ROOTDIR/sbin/ldconfig $ROOTDIR/sbin/ldconfig.REAL
mv $ROOTDIR/usr/bin/ldd $ROOTDIR/usr/bin/ldd.REAL
ln -s ../bin/true $ROOTDIR/sbin/ldconfig

# get fake ldd (needs objdump from binutils) for mkinitramfs
# https://github.com/fakechroot/fakechroot/raw/master/scripts/ldd.pl
curl http://mister-muffin.de/p/a3Dt > $ROOTDIR/usr/bin/ldd
chmod +x $ROOTDIR/usr/bin/ldd

# supply ld.so.conf for fake ldd (running libc6 postinst script will fail)
echo "include /etc/ld.so.conf.d/*.conf" > $ROOTDIR/etc/ld.so.conf

# do not generate ssh host keys
mkdir -p $ROOTDIR/etc/ssh/
touch "$ROOTDIR/etc/ssh/ssh_host_rsa_key"
touch "$ROOTDIR/etc/ssh/ssh_host_dsa_key"
touch "$ROOTDIR/etc/ssh/ssh_host_ecdsa_key"

cat > $ROOTDIR/tmp/debconfseed.txt << __END__
# put debconf options here
__END__
fakechroot chroot $ROOTDIR debconf-set-selections /tmp/debconfseed.txt
rm $ROOTDIR/tmp/debconfseed.txt

# run preinst scripts
for script in $ROOTDIR/var/lib/dpkg/info/*.preinst; do
	[ "$script" = "$ROOTDIR/var/lib/dpkg/info/bash.preinst" ] && continue
	fakechroot chroot $ROOTDIR ${script##$ROOTDIR} install
done

# run dpkg --configure -a twice because of errors during the first run
fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a || fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a

fakechroot chroot $ROOTDIR update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en
echo en_US.UTF-8 UTF-8 > $ROOTDIR/etc/locale.gen
fakechroot chroot $ROOTDIR locale-gen

cat > $ROOTDIR/etc/fstab << __END__
# <file system> <mount point>    <type> <options>                          <dump> <pass>
rootfs          /                auto   defaults,errors=remount-ro,noatime 0      1
/dev/mmcblk0p2  /home            auto   defaults,errors=remount-ro,noatime 0      2
proc            /proc            proc   defaults                           0      0
tmpfs           /tmp             tmpfs  defaults,noatime                   0      0
tmpfs           /var/lock        tmpfs  defaults,noatime                   0      0
tmpfs           /var/run         tmpfs  defaults,noatime                   0      0
tmpfs           /var/log         tmpfs  defaults,noatime                   0      0
tmpfs           /etc/network/run tmpfs  defaults,noatime                   0      0
__END__

echo openmoko > $ROOTDIR/etc/hostname

cat > $ROOTDIR/etc/hosts << __END__
127.0.0.1 localhost
127.0.0.1 openmoko
__END__

cat > $ROOTDIR/etc/default/nodm << __END__
NODM_ENABLED=true
NODM_USER=user
NODM_XINIT=/usr/bin/xinit
NODM_FIRST_VT=7
NODM_XSESSION=/etc/X11/Xsession
NODM_X_OPTIONS='-nolisten tcp'
NODM_MIN_SESSION_TIME=60
__END__

# activate a tty on serial
echo "T0:23:respawn:/sbin/getty -L ttyS0 115200 vt100" >> $ROOTDIR/etc/inittab

fakechroot chroot $ROOTDIR useradd user -p `openssl passwd -crypt -salt // ""` -s /bin/bash --create-home
fakechroot chroot $ROOTDIR usermod -a -G audio,dialout user

sed -i 's/\(root:\)[^:]*\(:\)/\1'`openssl passwd -crypt -salt // "" | sed 's/\(\/\|\\\|&\)/\\&/g'`'\2/' $ROOTDIR/etc/shadow
sed -i 's/\(PermitEmptyPasswords\) no/\1 yes/' $ROOTDIR/etc/ssh/sshd_config
echo 'APT::Install-Recommends "0";' > $ROOTDIR/etc/apt/apt.conf.d/99no-install-recommends
echo 'Acquire::PDiffs "0";' > $ROOTDIR/etc/apt/apt.conf.d/99no-pdiffs

#cleanup
rm $ROOTDIR/sbin/ldconfig $ROOTDIR/usr/bin/ldd
mv $ROOTDIR/sbin/ldconfig.REAL $ROOTDIR/sbin/ldconfig
mv $ROOTDIR/usr/bin/ldd.REAL $ROOTDIR/usr/bin/ldd
rm $ROOTDIR/usr/sbin/policy-rc.d
rm $ROOTDIR/etc/ssh/ssh_host_*
cp /etc/resolv.conf $ROOTDIR/etc/resolv.conf

# need to generate tar inside fakechroot so that absolute symlinks are correct
fakechroot chroot $ROOTDIR tar -cf $ROOTDIR.tar -C / .
mv $ROOTDIR/$ROOTDIR.tar .

tar --delete -f $ROOTDIR.tar ./usr/bin/qemu-arm-static
rm $ROOTDIR/usr/bin/qemu-arm-static
