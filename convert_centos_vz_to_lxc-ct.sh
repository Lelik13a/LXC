#!/bin/bash

if [[ x$1 == "x" ]]; then
	echo "usage: $0 /patch/to/ct_root"
	exit 0;
fi

if [[ $1 == "/" ]]; then
	echo "a you sure?"
	exit 0;
fi

rootfs_path=$1

centos_host_ver=$( sed -e '/^CentOS /!d' -e 's/CentOS.*\srelease\s*\([0-9][0-9.]*\)\s.*/\1/' < $rootfs_path/etc/centos-release )
release=$(expr $centos_host_ver : '\([0-9]\)')


echo rootfs_path: $rootfs_path
echo centos_host_ver: $centos_host_ver
echo release: $release

# --------------- configure_centos() -----------------

# disable selinux in centos
    mkdir -p $rootfs_path/selinux
    echo 0 > $rootfs_path/selinux/enforce

# Also kill it in the /etc/selinux/config file if it's there...
    if [ -f $rootfs_path/etc/selinux/config ]
    then
        sed -i '/^SELINUX=/s/.*/SELINUX=disabled/' $rootfs_path/etc/selinux/config
    fi

# Nice catch from Dwight Engen in the Oracle template.
# Wantonly plagerized here with much appreciation.
    if [ -f $rootfs_path/usr/sbin/selinuxenabled ]; then
        mv $rootfs_path/usr/sbin/selinuxenabled $rootfs_path/usr/sbin/selinuxenabled.lxcorig
        ln -s /bin/false $rootfs_path/usr/sbin/selinuxenabled
    fi

# This is a known problem and documented in RedHat bugzilla as relating
# to a problem with auditing enabled.  This prevents an error in
# the container "Cannot make/remove an entry for the specified session"
    sed -i '/^session.*pam_loginuid.so/s/^session/# session/' ${rootfs_path}/etc/pam.d/login
    sed -i '/^session.*pam_loginuid.so/s/^session/# session/' ${rootfs_path}/etc/pam.d/sshd

    if [ -f ${rootfs_path}/etc/pam.d/crond ]
    then
        sed -i '/^session.*pam_loginuid.so/s/^session/# session/' ${rootfs_path}/etc/pam.d/crond
    fi

# In addition to disabling pam_loginuid in the above config files
# we'll also disable it by linking it to pam_permit to catch any
# we missed or any that get installed after the container is built.
#
# Catch either or both 32 and 64 bit archs.
    if [ -f ${rootfs_path}/lib/security/pam_loginuid.so ]
    then
        ( cd ${rootfs_path}/lib/security/
        mv pam_loginuid.so pam_loginuid.so.disabled
        ln -s pam_permit.so pam_loginuid.so
        )
    fi

    if [ -f ${rootfs_path}/lib64/security/pam_loginuid.so ]
    then
        ( cd ${rootfs_path}/lib64/security/
        mv pam_loginuid.so pam_loginuid.so.disabled
        ln -s pam_permit.so pam_loginuid.so
        )
    fi


# Set default localtime to the host localtime if not set...
    if [ -e /etc/localtime -a ! -e ${rootfs_path}/etc/localtime ]
    then
# if /etc/localtime is a symlink, this should preserve it.
        cp -a /etc/localtime ${rootfs_path}/etc/localtime
    fi


# Deal with some dain bramage in the /etc/init.d/halt script.
# Trim it and make it our own and link it in before the default
# halt script so we can intercept it.  This also preventions package
# updates from interferring with our interferring with it.
#
# There's generally not much in the halt script that useful but what's
# in there from resetting the hardware clock down is generally very bad.
# So we just eliminate the whole bottom half of that script in making
# ourselves a copy.  That way a major update to the init scripts won't
# trash what we've set up.
    if [ -f ${rootfs_path}/etc/init.d/halt ]
    then
        sed -e '/hwclock/,$d' \
            < ${rootfs_path}/etc/init.d/halt \
            > ${rootfs_path}/etc/init.d/lxc-halt

        echo '$command -f' >> ${rootfs_path}/etc/init.d/lxc-halt
        chmod 755 ${rootfs_path}/etc/init.d/lxc-halt

# Link them into the rc directories...
        (
             cd ${rootfs_path}/etc/rc.d/rc0.d
             ln -s ../init.d/lxc-halt S00lxc-halt
             cd ${rootfs_path}/etc/rc.d/rc6.d
             ln -s ../init.d/lxc-halt S00lxc-reboot
        )
    fi


# configure the network 
    cat <<EOF > ${rootfs_path}/etc/sysconfig/network-scripts/ifcfg-eth0
DEVICE=eth0
BOOTPROTO=static
ONBOOT=yes
NM_CONTROLLED=no
TYPE=Ethernet
EOF

# fix openvz network
	
	if [ -f $rootfs_path/etc/sysconfig/network-scripts/ifcfg-venet0 ]
	then
		rm -f $rootfs_path/etc/sysconfig/network-scripts/ifcfg-venet0
	fi
	


	if [ -f $rootfs_path/etc/sysconfig/network-scripts/ifcfg-venet0:0 ]
	then
		cat $rootfs_path/etc/sysconfig/network-scripts/ifcfg-venet0:0 | grep IPADDR >> ${rootfs_path}/etc/sysconfig/network-scripts/ifcfg-eth0
		echo "PREFIX=24" >> ${rootfs_path}/etc/sysconfig/network-scripts/ifcfg-eth0

		rm -f $rootfs_path/etc/sysconfig/network-scripts/ifcfg-venet0:0
	fi

	if [ -f $rootfs_path/etc/sysconfig/network ]
	then
	        sed -i '/^GATEWAYDEV/#GATEWAYDEV/' $rootfs_path/etc/sysconfig/network
	        sed -i '/^IPV6_DEFAULTDEV/#IPV6_DEFAULTDEV/' $rootfs_path/etc/sysconfig/network
		cat $rootfs_path/etc/sysconfig/network | grep HOSTNAME >> ${rootfs_path}/etc/sysconfig/network-scripts/ifcfg-eth0
	fi


# set minimal fstab
    cat <<EOF > $rootfs_path/etc/fstab
/dev/root               /                       rootfs   defaults        0 0
EOF


# create lxc compatibility init script
    if [ "$release" = "6" ]; then
        cat <<EOF > $rootfs_path/etc/init/lxc-sysinit.conf
start on startup
env container
pre-start script
        if [ "x\$container" != "xlxc" -a "x\$container" != "xlibvirt" ]; then
                stop;
        fi
        rm -f /var/lock/subsys/*
        rm -f /var/run/*.pid
        [ -e /etc/mtab ] || ln -s /proc/mounts /etc/mtab
        mkdir -p /dev/shm
        mount -t tmpfs -o nosuid,nodev tmpfs /dev/shm
        initctl start tty TTY=console
        telinit 3
        exit 0
end script
EOF
    elif [ "$release" = "5" ]; then
        cat <<EOF > $rootfs_path/etc/rc.d/lxc.sysinit
#! /bin/bash
rm -f /etc/mtab /var/run/*.{pid,lock} /var/lock/subsys/*
rm -rf {/,/var}/tmp/*
echo "/dev/root               /                       rootfs   defaults        0 0" > /etc/mtab
exit 0
EOF


        chmod 755 $rootfs_path/etc/rc.d/lxc.sysinit
        sed -i 's|si::sysinit:/etc/rc.d/rc.sysinit|si::bootwait:/etc/rc.d/lxc.sysinit|'  $rootfs_path/etc/inittab
# prevent mingetty from calling vhangup(2) since it fails with userns.
# Same issue as oracle template: prevent mingetty from calling vhangup(2)
# commit 2e83f7201c5d402478b9849f0a85c62d5b9f1589.
        sed -i 's|^1:|co:2345:respawn:/sbin/mingetty --nohangup console\n1:|' $rootfs_path/etc/inittab
        sed -i 's|^\([56]:\)|#\1|' $rootfs_path/etc/inittab
    fi

    dev_path="${rootfs_path}/dev"
    rm -rf $dev_path
    mkdir -p $dev_path
    mknod -m 666 ${dev_path}/null c 1 3
    mknod -m 666 ${dev_path}/zero c 1 5
    mknod -m 666 ${dev_path}/random c 1 8
    mknod -m 666 ${dev_path}/urandom c 1 9
    mkdir -m 755 ${dev_path}/pts
    mkdir -m 1777 ${dev_path}/shm
    mknod -m 666 ${dev_path}/tty c 5 0
    mknod -m 666 ${dev_path}/tty0 c 4 0
    mknod -m 666 ${dev_path}/tty1 c 4 1
    mknod -m 666 ${dev_path}/tty2 c 4 2
    mknod -m 666 ${dev_path}/tty3 c 4 3
    mknod -m 666 ${dev_path}/tty4 c 4 4
    mknod -m 600 ${dev_path}/console c 5 1
    mknod -m 666 ${dev_path}/full c 1 7
    mknod -m 600 ${dev_path}/initctl p
    mknod -m 666 ${dev_path}/ptmx c 5 2

# setup console and tty[1-4] for login. note that /dev/console and
# /dev/tty[1-4] will be symlinks to the ptys /dev/lxc/console and
# /dev/lxc/tty[1-4] so that package updates can overwrite the symlinks.
# lxc will maintain these links and bind mount ptys over /dev/lxc/*
# since lxc.devttydir is specified in the config.

# allow root login on console, tty[1-4], and pts/0 for libvirt
    echo "# LXC (Linux Containers)" >>${rootfs_path}/etc/securetty
    echo "lxc/console"  >>${rootfs_path}/etc/securetty
    echo "lxc/tty1"     >>${rootfs_path}/etc/securetty
    echo "lxc/tty2"     >>${rootfs_path}/etc/securetty
    echo "lxc/tty3"     >>${rootfs_path}/etc/securetty
    echo "lxc/tty4"     >>${rootfs_path}/etc/securetty
    echo "# For libvirt/Virtual Machine Monitor" >>${rootfs_path}/etc/securetty
    echo "pts/0"        >>${rootfs_path}/etc/securetty

# prevent mingetty from calling vhangup(2) since it fails with userns.
# Same issue as oracle template: prevent mingetty from calling vhangup(2)
# commit 2e83f7201c5d402478b9849f0a85c62d5b9f1589.
    sed -i 's|mingetty|mingetty --nohangup|' $rootfs_path/etc/init/tty.conf




# ------------------------ configure_centos_init() ----------------------


    sed -i 's|.sbin.start_udev||' ${rootfs_path}/etc/rc.sysinit
    sed -i 's|.sbin.start_udev||' ${rootfs_path}/etc/rc.d/rc.sysinit
    if [ "$release" = "6" ]; then
        chroot ${rootfs_path} /sbin/chkconfig udev-post off
    fi
    chroot ${rootfs_path} /sbin/chkconfig network on

    if [ -d ${rootfs_path}/etc/init ]
    then
# This is to make upstart honor SIGPWR
        cat <<EOF >${rootfs_path}/etc/init/power-status-changed.conf
#  power-status-changed - shutdown on SIGPWR
#
start on power-status-changed
    
exec /sbin/shutdown -h now "SIGPWR received"
EOF
    fi


