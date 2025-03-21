#!/bin/bash
set -e
#set -x

# BOOT_LOADER=u-boot
# CPU_SPEED=1600,2000,2200
# SERDES=0
# CP_NUM=1,2,3
###############################################################################
# General configurations
###############################################################################
#RELEASE=cn9130-early-access-bsp_rev1.0 # Supports both rev1.0 and rev1.1
BUILDROOT_VERSION=2020.02.1
: ${BR2_PRIMARY_SITE:=} # custom buildroot mirror
#UEFI_RELEASE=DEBUG
#BOOT_LOADER=uefi
#DDR_SPEED=2400
#BOARD_CONFIG -
# 0-clearfog_cn COM express
# 1-clearfog-base (cn9130 SOM)
# 2-clearfog-pro (cn9130 SOM)
# 3-SolidWAN (cn9130 SOM)
# 4-BlDN MBV-A/B (cn9130 SOM)


#UBOOT_ENVIRONMENT -
# - spi (SPI FLash)
# - mmc:0:0 (MMC 0 Partition 0)
# - mmc:0:1 (MMC 0 Partition boot0)
# - mmc:0:2 (MMC 0 Partition boot1)
# - mmc:1:0 (MMC 1 Partition 0) <-- default, microSD on Clearfog
# - mmc:1:1 (MMC 1 Partition boot0)
# - mmc:1:2 (MMC 1 Partition boot1)
: ${UBOOT_ENVIRONMENT:=mmc:1:0}
: ${BUILD_ROOTFS:=yes} # set to no for bootloader-only build

# Ubuntu Version
# - bionic (18.04)
# - focal (20.04)
: ${UBUNTU_VERSION:=focal}

# Check if git user name and git email are configured
if [ -z "`git config user.name`" ] || [ -z "`git config user.email`" ]; then
			echo "git is not configured, please run:"
			echo "git config --global user.email \"you@example.com\""
			echo "git config --global user.name \"Your Name\""
			exit -1
fi

###############################################################################
# Misc
###############################################################################

RELEASE=${RELEASE:-v6.1.29}
DPDK_RELEASE=${DPDK_RELEASE:-v22.07}

SHALLOW=${SHALLOW:true}
	if [ "x$SHALLOW" == "xtrue" ]; then
		SHALLOW_FLAG="--depth 1"
	fi
BOOT_LOADER=${BOOT_LOADER:-u-boot}
BOARD_CONFIG=${BOARD_CONFIG:-2}
CP_NUM=${CP_NUM:-1}
mkdir -p build images
ROOTDIR=`pwd`
PARALLEL=$(getconf _NPROCESSORS_ONLN) # Amount of parallel jobs for the builds
TOOLS="wget tar git make 7z unsquashfs dd vim mkfs.ext4 parted mkdosfs mcopy dtc iasl mkimage e2cp truncate qemu-system-aarch64 cpio rsync bc bison flex python unzip depmod"

export PATH=$ROOTDIR/build/toolchain/gcc-linaro-7.5.0-2019.12-x86_64_aarch64-linux-gnu/bin:$PATH
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64

case "${BOARD_CONFIG}" in
	0)
		echo "*** Board Configuration CEx7 CN9132 based on Clearfog CN9K ***"
		if [ "x$CP_NUM" == "x1" ]; then
			DTB_UBOOT=cn9130-cex7-A
			DTB_KERNEL=cn9130-cex7
		elif [ "x$CP_NUM" == "x2" ]; then
			DTB_UBOOT=cn9131-cex7-A
			DTB_KERNEL=cn9131-cex7
		elif [ "x$CP_NUM" == "x3" ]; then
                        DTB_UBOOT=cn9132-cex7-A
			DTB_KERNEL=cn9132-cex7
		else 
			 echo "Please define a correct number of CPs [1,2,3]"
			 exit -1
		fi
	;;
	1)
                echo "*** CN9130 SOM based on Clearfog Base ***"
		CP_NUM=1
		DTB_UBOOT=cn9130-cf-base
		DTB_KERNEL=cn9130-cf-base
	;;
	2)
		echo "*** CN9130 SOM based on Clearfog Pro ***"
		CP_NUM=1
		DTB_UBOOT=cn9130-cf-pro
                DTB_KERNEL=cn9130-cf-pro
	;;

	3)
		echo "*** CN9131 SOM based on SolidWAN ***"
		CP_NUM=2
		DTB_UBOOT=cn9131-cf-solidwan
		DTB_KERNEL=cn9131-cf-solidwan
	;;
	4) 	
		echo "*** CN9131 SOM based on Bldn MBV-A/B ***"
                CP_NUM=2
                DTB_UBOOT=cn9131-bldn-mbv
                DTB_KERNEL=cn9131-bldn-mbv
        ;;


	*)
		echo "Please define board configuration"
		exit -1
	;;
esac

#########################
# checking tools 
#########################

echo "Checking all required tools are installed"

set +e
for i in $TOOLS; do
        TOOL_PATH=`which $i`
        if [ "x$TOOL_PATH" == "x" ]; then
                echo "Tool $i is not installed"
                echo "If running under apt based package management you can run -"
                echo "sudo apt install build-essential git dosfstools e2fsprogs parted sudo mtools p7zip p7zip-full device-tree-compiler acpica-tools u-boot-tools e2tools qemu-system-arm libssl-dev cpio rsync bc bison flex python unzip kmod"
                exit -1
        fi
done
set -e

if [[ ! -d $ROOTDIR/build/toolchain ]]; then
	mkdir -p $ROOTDIR/build/toolchain
	cd $ROOTDIR/build/toolchain
	wget http://releases.linaro.org/components/toolchain/binaries/7.5-2019.12/aarch64-linux-gnu/gcc-linaro-7.5.0-2019.12-x86_64_aarch64-linux-gnu.tar.xz
	tar -xvf gcc-linaro-7.5.0-2019.12-x86_64_aarch64-linux-gnu.tar.xz 
fi

echo "Building boot loader"
cd $ROOTDIR

###############################################################################
# source code cloning and building 
###############################################################################
SDK_COMPONENTS="u-boot mv-ddr-marvell arm-trusted-firmware linux dpdk"

for i in $SDK_COMPONENTS; do
	if [[ ! -d $ROOTDIR/build/$i ]]; then
		if [ "x$i" == "xlinux" ]; then
			echo "Cloing https://www.github.com/torvalds/$i release $RELEASE"
			cd $ROOTDIR/build
			git clone $SHALLOW_FLAG https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux.git linux -b $RELEASE
		elif [ "x$i" == "xarm-trusted-firmware" ]; then
			echo "Cloning atf from mainline"
			cd $ROOTDIR/build
			git clone https://github.com/ARM-software/arm-trusted-firmware.git arm-trusted-firmware
			cd arm-trusted-firmware
			# Temporary commit waiting for a release
			git checkout 00ad74c7afe67b2ffaf08300710f18d3dafebb45
		elif [ "x$i" == "xmv-ddr-marvell" ]; then
			echo "Cloning mv-ddr-marvell from mainline"
			echo "Cloing https://github.com/MarvellEmbeddedProcessors/mv-ddr-marvell.git"
			cd $ROOTDIR/build
			git clone https://github.com/MarvellEmbeddedProcessors/mv-ddr-marvell.git mv-ddr-marvell
			cd mv-ddr-marvell
			git checkout mv-ddr-devel
		elif [ "x$i" == "xu-boot" ]; then
			echo "Cloning u-boot from git://git.denx.de/u-boot.git"
			cd $ROOTDIR/build
			git clone git://git.denx.de/u-boot.git u-boot
			cd u-boot
			git checkout v2019.10 -b marvell
		elif [ "x$i" == "xdpdk" ]; then
                        echo "Cloning DPDK from https://github.com/DPDK/dpdk.git"
                        cd $ROOTDIR/build
                        git clone $SHALLOW_FLAG https://github.com/DPDK/dpdk.git dpdk -b $DPDK_RELEASE
			# Apply release specific DPDK patches
			if [ -d $ROOTDIR/patches/dpdk-$DPDK_RELEASE ]; then
				cd dpdk
				git am $ROOTDIR/patches/dpdk-${DPDK_RELEASE}/*.patch
			fi
		fi

		echo "Checking patches for $i"
		cd $ROOTDIR/build/$i
		if [ -d $ROOTDIR/patches/$i ]; then
			git am $ROOTDIR/patches/$i/*.patch
		fi
	fi
done
##############################################################################
# File System
###############################################################################

if [[ ! -f $ROOTDIR/build/ubuntu-core.ext4 ]]; then
	if [[ $UBUNTU_VERSION == bionic ]]; then
		UBUNTU_BASE_URL=http://cdimage.ubuntu.com/ubuntu-base/releases/18.04/release/ubuntu-base-18.04.5-base-arm64.tar.gz
	fi
	if [[ $UBUNTU_VERSION == focal ]]; then
		UBUNTU_BASE_URL=http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.5-base-arm64.tar.gz
	fi
	if [[ -z $UBUNTU_BASE_URL ]]; then
		echo "Error: Unknown URL for Ubuntu Version \"\${UBUNTU_VERSION}! Please provide UBUNTU_BASE_URL."
		exit 1
	fi

        echo "Building Ubuntu ${UBUNTU_VERSION} File System"
	cd $ROOTDIR/build
        mkdir -p ubuntu
        cd ubuntu
	if [ ! -d buildroot ]; then
                git clone $SHALLOW_FLAG https://github.com/buildroot/buildroot -b $BUILDROOT_VERSION
        fi
	cd buildroot	
	cp $ROOTDIR/configs/buildroot/buildroot_defconfig configs/
	printf 'BR2_PRIMARY_SITE="%s"\n' "${BR2_PRIMARY_SITE}" >> configs/buildroot_defconfig
	export FORCE_UNSAFE_CONFIGURE=1
	make buildroot_defconfig 
	mkdir -p overlay/etc/init.d/
	cat > overlay/etc/init.d/S99bootstrap-ubuntu.sh << EOF
#!/bin/sh

case "\$1" in
        start)
		resize
                mkfs.ext4 -F /dev/vda -b 4096
                mount /dev/vda /mnt
                cd /mnt/
                cat /proc/net/pnp > /etc/resolv.conf
		wget -c -P /tmp/ -O /tmp/ubuntu-base.dl "${UBUNTU_BASE_URL}"
		tar -C /mnt -xf /tmp/ubuntu-base.dl
                mount -o bind /proc /mnt/proc/
                mount -o bind /sys/ /mnt/sys/
                mount -o bind /dev/ /mnt/dev/
                mount -o bind /dev/pts /mnt/dev/pts
                mount -t tmpfs tmpfs /mnt/var/lib/apt/
                mount -t tmpfs tmpfs /mnt/var/cache/apt/
                cat /proc/net/pnp > /mnt/etc/resolv.conf
                echo "localhost" > /mnt/etc/hostname
                echo "127.0.0.1 localhost" > /mnt/etc/hosts
                export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C
                chroot /mnt apt update
                chroot /mnt apt install --no-install-recommends -y systemd-sysv apt locales less wget procps openssh-server ifupdown net-tools isc-dhcp-client ntpdate lm-sensors i2c-tools psmisc less sudo htop iproute2 iputils-ping kmod network-manager iptables rng-tools apt-utils libatomic1 ethtool
		echo -e "root\nroot" | chroot /mnt passwd
                umount /mnt/var/lib/apt/
                umount /mnt/var/cache/apt
                chroot /mnt apt clean
                chroot /mnt apt autoclean
                reboot
                ;;

esac
EOF

	chmod +x overlay/etc/init.d/S99bootstrap-ubuntu.sh
	make
	IMG=ubuntu-core.ext4.tmp
	truncate -s 500M $IMG
	qemu-system-aarch64 -m 1G -M virt -cpu cortex-a57 -nographic -smp 1 -kernel output/images/Image -append "console=ttyAMA0 ip=dhcp" -netdev user,id=eth0 -device virtio-net-device,netdev=eth0 -initrd output/images/rootfs.cpio.gz -drive file=$IMG,if=none,format=raw,id=hd0 -device virtio-blk-device,drive=hd0 -no-reboot
        mv $IMG $ROOTDIR/build/ubuntu-core.ext4

fi


###############################################################################
# Building sources u-boot / atf / mv-ddr / kernel
###############################################################################

echo "Building u-boot"
cd $ROOTDIR/build/u-boot/
cp configs/sr_cn913x_cex7_defconfig .config
[[ "${UBOOT_ENVIRONMENT}" =~ (.*):(.*):(.*) ]] || [[ "${UBOOT_ENVIRONMENT}" =~ (.*) ]]
if [ "x${BASH_REMATCH[1]}" = "xspi" ]; then
cat >> .config << EOF
CONFIG_ENV_IS_IN_MMC=n
CONFIG_ENV_IS_IN_SPI_FLASH=y
CONFIG_ENV_SIZE=0x10000
CONFIG_ENV_OFFSET=0x3f0000
CONFIG_ENV_SECT_SIZE=0x10000
EOF
elif [ "x${BASH_REMATCH[1]}" = "xmmc" ]; then
cat >> .config << EOF
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_MMC_ENV_DEV=${BASH_REMATCH[2]}
CONFIG_SYS_MMC_ENV_PART=${BASH_REMATCH[3]}
CONFIG_ENV_IS_IN_SPI_FLASH=n
EOF
else
	echo "ERROR: \$UBOOT_ENVIRONMENT setting invalid"
	exit 1
fi
make olddefconfig
make -j${PARALLEL} DEVICE_TREE=$DTB_UBOOT
install -m644 -D $ROOTDIR/build/u-boot/u-boot.bin $ROOTDIR/binaries/u-boot/u-boot.bin
export BL33=$ROOTDIR/binaries/u-boot/u-boot.bin

if [ "x$BOOT_LOADER" == "xuefi" ]; then
	echo "no support for uefi yet"
fi

echo "Building arm-trusted-firmware"
cd $ROOTDIR/build/arm-trusted-firmware
export SCP_BL2=$ROOTDIR/binaries/atf/mrvl_scp_bl2.img

echo "Compiling U-BOOT and ATF"
echo "CP_NUM=$CP_NUM"
echo "DTB=$DTB_UBOOT"

make PLAT=t9130 clean
make -j${PARALLEL} USE_COHERENT_MEM=0 LOG_LEVEL=20 PLAT=t9130 MV_DDR_PATH=$ROOTDIR/build/mv-ddr-marvell CP_NUM=$CP_NUM all fip

echo "Copying flash-image.bin to /Images folder"
cp $ROOTDIR/build/arm-trusted-firmware/build/t9130/release/flash-image.bin $ROOTDIR/images/u-boot-${DTB_UBOOT}-${UBOOT_ENVIRONMENT}.bin

if [ "x${BUILD_ROOTFS}" != "xyes" ]; then
	echo "U-Boot Ready, Skipping RootFS"
	exit 0
fi

echo "Building the kernel"
cd $ROOTDIR/build/linux
#make defconfig
./scripts/kconfig/merge_config.sh arch/arm64/configs/defconfig $ROOTDIR/configs/linux/cn913x_additions.config
make -j${PARALLEL} all #Image dtbs modules

rm -rf $ROOTDIR/images/tmp
mkdir -p $ROOTDIR/images/tmp/
mkdir -p $ROOTDIR/images/tmp/boot
make INSTALL_MOD_PATH=$ROOTDIR/images/tmp/ INSTALL_MOD_STRIP=1 modules_install
cp $ROOTDIR/build/linux/arch/arm64/boot/Image $ROOTDIR/images/tmp/boot
cp $ROOTDIR/build/linux/arch/arm64/boot/dts/marvell/cn913*.dtb $ROOTDIR/images/tmp/boot


###############################################################################
# build MUSDK
###############################################################################
if [[ ! -d $ROOTDIR/build/musdk-marvell-SDK11.22.07 ]]; then
	cd $ROOTDIR/build/
	wget https://solidrun-common.sos-de-fra-1.exo.io/cn913x/marvell/SDK11.22.07/sources-musdk-marvell-SDK11.22.07.tar.bz2
	tar -vxf sources-musdk-marvell-SDK11.22.07.tar.bz2
	rm -f sources-musdk-marvell-SDK11.22.07.tar.bz2
	cd musdk-marvell-SDK11.22.07
	for i in `find $ROOTDIR/patches/musdk/*.patch`; do
		patch -p1 < $i
	done

fi

cd $ROOTDIR/build/musdk-marvell-SDK11.22.07
./bootstrap
./configure --host=aarch64-linux-gnu CFLAGS="-fPIC -O2"
make -j${PARALLEL}
make install
cd $ROOTDIR/build/musdk-marvell-SDK11.22.07/modules/cma
make -j${PARALLEL} -C "$ROOTDIR/build/linux" M="$PWD" modules
cd $ROOTDIR/build/musdk-marvell-SDK11.22.07/modules/pp2
make -j${PARALLEL} -C "$ROOTDIR/build/linux" M="$PWD" modules

###############################################################################
# build DPDK
###############################################################################
export PKG_CONFIG_PATH=$ROOTDIR/build/musdk-marvell-SDK11.22.07/usr/local/lib/pkgconfig/:$PKG_CONFIG_PATH
cd $ROOTDIR/build/dpdk
meson build -Dexamples=all --cross-file $ROOTDIR/configs/dpdk/arm64_armada_solidrun_linux_gcc
ninja -C build

###############################################################################
# assembling images
###############################################################################
echo "Assembling kernel image"
cd $ROOTDIR
mkdir -p $ROOTDIR/images/tmp/extlinux/
cat > $ROOTDIR/images/tmp/extlinux/extlinux.conf << EOF
  TIMEOUT 30
  DEFAULT linux
  MENU TITLE linux-cn913x boot options
  LABEL primary
    MENU LABEL primary kernel
    LINUX /boot/Image
    FDTDIR /boot
    APPEND console=ttyS0,115200 root=PARTUUID=30303030-01 rw rootwait cma=256M
EOF

# blkid images/tmp/ubuntu-core.img | cut -f2 -d'"'
cp $ROOTDIR/build/ubuntu-core.ext4 $ROOTDIR/images/tmp/
e2mkdir -G 0 -O 0 $ROOTDIR/images/tmp/ubuntu-core.ext4:extlinux
e2cp -G 0 -O 0 $ROOTDIR/images/tmp/extlinux/extlinux.conf $ROOTDIR/images/tmp/ubuntu-core.ext4:extlinux/
e2mkdir -G 0 -O 0 $ROOTDIR/images/tmp/ubuntu-core.ext4:boot
e2cp -G 0 -O 0 $ROOTDIR/images/tmp/boot/Image $ROOTDIR/images/tmp/ubuntu-core.ext4:boot/
e2mkdir -G 0 -O 0 $ROOTDIR/images/tmp/ubuntu-core.ext4:boot/marvell
e2cp -G 0 -O 0 $ROOTDIR/images/tmp/boot/*.dtb $ROOTDIR/images/tmp/ubuntu-core.ext4:boot/marvell/

# Copy DPDK applications
e2cp -G 0 -O 0 -p $ROOTDIR/build/dpdk/build/app/dpdk-testpmd $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/bin/
e2cp -G 0 -O 0 -p $ROOTDIR/build/dpdk/build/examples/dpdk-l2fwd $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/bin/
e2cp -G 0 -O 0 -p $ROOTDIR/build/dpdk/build/examples/dpdk-l3fwd $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/bin/

# Copy MUSDK
cd $ROOTDIR/build/musdk-marvell-SDK11.22.07/usr/local/
for i in `find .`; do
	if [ -d $i ]; then
		e2mkdir -v -G 0 -O 0 $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/$i
	fi
	if [ -f $i ] && ! [ -L $i ]; then
		DIR=`dirname $i`
		e2cp -v -G 0 -O 0 -p $ROOTDIR/build/musdk-marvell-SDK11.22.07/usr/local/$i $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/$DIR
	fi
done
for i in `find .`; do
       if [ -L $i ]; then
               DIR=`dirname $i`
               DEST=`readlink -qn $i`
               e2ln -vf $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/$DIR/$DEST /usr/$i
       fi
done

# Copy over kernel image
echo "Copying kernel modules"
cd $ROOTDIR/images/tmp/
for i in `find lib`; do
        if [ -d $i ]; then
                e2mkdir -G 0 -O 0 $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/$i
        fi
        if [ -f $i ]; then
                DIR=`dirname $i`
                e2cp -G 0 -O 0 -p $ROOTDIR/images/tmp/$i $ROOTDIR/images/tmp/ubuntu-core.ext4:usr/$DIR
        fi
done
cd -

# Copy MUSDK modules
e2mkdir -G 0 -O 0 $ROOTDIR/images/tmp/ubuntu-core.ext4:root/musdk_modules
e2cp -G 0 -O 0 $ROOTDIR/build/musdk-marvell-SDK11.22.07/modules/cma/musdk_cma.ko $ROOTDIR/images/tmp/ubuntu-core.ext4:root/musdk_modules
e2cp -G 0 -O 0 $ROOTDIR/build/musdk-marvell-SDK11.22.07/modules/pp2/mv_pp_uio.ko $ROOTDIR/images/tmp/ubuntu-core.ext4:root/musdk_modules

# ext4 ubuntu partition is ready
cp $ROOTDIR/build/arm-trusted-firmware/build/t9130/release/flash-image.bin $ROOTDIR/images
cp $ROOTDIR/build/linux/arch/arm64/boot/Image $ROOTDIR/images
cd $ROOTDIR/
truncate -s 570M $ROOTDIR/images/tmp/ubuntu-core.img
parted --script $ROOTDIR/images/tmp/ubuntu-core.img mklabel msdos mkpart primary 64MiB 567MiB
# Generate the above partuuid 3030303030 which is the 4 characters of '0' in ascii
echo "0000" | dd of=$ROOTDIR/images/tmp/ubuntu-core.img bs=1 seek=440 conv=notrunc
dd if=$ROOTDIR/images/tmp/ubuntu-core.ext4 of=$ROOTDIR/images/tmp/ubuntu-core.img bs=1M seek=64 conv=notrunc
dd if=$ROOTDIR/build/arm-trusted-firmware/build/t9130/release/flash-image.bin of=$ROOTDIR/images/tmp/ubuntu-core.img bs=512 seek=4096 conv=notrunc
mv $ROOTDIR/images/tmp/ubuntu-core.img $ROOTDIR/images/ubuntu-${DTB_KERNEL}-${UBOOT_ENVIRONMENT}.img

echo "Images are ready at $ROOTDIR/image/"
