#!/usr/bin/env bash
set -eE

# Variables
SUITE=questing
ARCH=arm64
ROOTFS_DIR=rootfs/${SUITE}-desktop
KERNEL_DIR=kernel  # Folder containing your built .deb files
PACKAGES_DIR=packages
MIRROR=http://ports.ubuntu.com/ubuntu-ports

# Install mmdebstrap + qemu
apt install -y mmdebstrap qemu-user-static binfmt-support

# =========================
# 1. Build base rootfs
# =========================
mmdebstrap --arch=${ARCH} ${SUITE} ${ROOTFS_DIR} \
  --include=ubuntu-desktop,casper,ca-certificates,netplan.io,network-manager,sudo,ssh,dbus-user-session,gnome-shell-extension-prefs \
  --components=main,universe,multiverse \
  ${MIRROR}

# Copy QEMU binary so we can chroot
cp /usr/bin/qemu-aarch64-static ${ROOTFS_DIR}/usr/bin/

# =========================
# 2. Setup chroot environment
# =========================
echo "[+] Preparing chroot networking..."

rm -f ${ROOTFS_DIR}/etc/resolv.conf
tee ${ROOTFS_DIR}/etc/resolv.conf > /dev/null <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# =========================
# 3. Copy kernel DEBs into rootfs
# =========================
mkdir -p ${ROOTFS_DIR}/tmp/kernel-debs
cp ${KERNEL_DIR}/*.deb ${ROOTFS_DIR}/tmp/kernel-debs/ || true
#cp ${PACKAGES_DIR}/*.deb ${ROOTFS_DIR}/tmp/kernel-debs/ || true

mount -t proc /proc "${ROOTFS_DIR}/proc"
mount --rbind /sys "${ROOTFS_DIR}/sys"
mount --rbind /dev "${ROOTFS_DIR}/dev"
mount --make-rslave "${ROOTFS_DIR}/sys"
mount --make-rslave "${ROOTFS_DIR}/dev"
mount --rbind /run "${ROOTFS_DIR}/run"
mount --make-rslave "${ROOTFS_DIR}/run"

# =========================
# 4. Install kernel inside chroot
# =========================
chroot ${ROOTFS_DIR} /bin/bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

echo '[+] Updating apt sources...'
apt-get update

echo '[+] Installing base packages...'
echo '[+] Installing base Ubuntu Desktop packages...'

apt-get install -y \
  initramfs-tools linux-base u-boot-menu u-boot-tools \
  plymouth plymouth-themes plymouth-theme-spinner \
  desktop-base cloud-initramfs-growroot \
  gdm3 ubuntu-desktop gnome-shell-extension-manager \
  gnome-initial-setup gnome-control-center gnome-disk-utility \
  gnome-session gnome-keyring gnome-software gnome-software-plugin-snap \
  gnome-terminal gedit gsettings-desktop-schemas gnome-online-accounts \
  gnome-bluetooth-3-common bluez bluez-obexd rfkill \
  yaru-theme-gtk yaru-theme-icon adwaita-icon-theme \
  ubuntu-settings shared-mime-info fastfetch \
  geoip-database tzdata console-setup keyboard-configuration \
  mesa-vulkan-drivers

echo '[+] Installing firefox...'
add-apt-repository -y ppa:mozillateam/ppa
apt update
apt-get install -y firefox

apt-get install -y gnome-system-monitor gnome-calculator gnome-calendar \
   gnome-characters gnome-font-viewer gnome-logs gnome-screenshot \
   gnome-weather gnome-maps gnome-contacts eog evince

apt-get install -y libreoffice libreoffice-gtk3 thunderbird simple-scan \
  rhythmbox cheese totem file-roller baobab

echo '[+] Ensuring Nautilus supports network and other locations...'
apt-get clean
apt-get install -y \
  gvfs gvfs-daemons gvfs-fuse gvfs-backends gvfs-libs \
  gvfs-common udisks2 dbus-x11 avahi-daemon \
  samba samba-common-bin nautilus-share

echo '[+] Installing custom kernel DEBs...'
dpkg -i /tmp/kernel-debs/*.deb || apt-get -f install -y

add-apt-repository -y ppa:phowe6/rockchip
apt-get update
apt-get install -y rockchip-firmware

#echo '[+] Regenerating initramfs...'
#update-initramfs -u -k all

echo '[+] Cleaning up kernel DEBs...'
rm -rf /tmp/kernel-debs

echo '[+] Kernel installation complete in rootfs.'

# # =========================
# # Create ubuntu user
# # =========================
# echo '[+] Creating default ubuntu user...'
# useradd -m -s /bin/bash ubuntu
# echo 'ubuntu:ubuntu' | chpasswd
# usermod -aG sudo,adm,video,audio,plugdev,render ubuntu

# # =========================
# # Enable GDM Auto-login (KEY FIX)
# # =========================
# mkdir -p /var/lib/AccountsService/users
# cat > /var/lib/AccountsService/users/ubuntu <<EOF
# [User]
# Language=
# XSession=ubuntu
# SystemAccount=false
# EOF

# mkdir -p /etc/gdm3
# cat > /etc/gdm3/custom.conf <<EOF
# [daemon]
# AutomaticLoginEnable = true
# AutomaticLogin = ubuntu
# EOF

# # =========================
# # Trigger GNOME Initial Setup on first boot
# # =========================
# echo '[+] Triggering GNOME Initial Setup...'
# rm -rf /var/lib/gnome-initial-setup/*  # Clears all 'seen' markers to force run
# mkdir -p /var/lib/gnome-initial-setup # Recreate empty dir
# touch /var/lib/gnome-initial-setup/force-new-user

# # Clear locale/time/keyboard to re-prompt
# rm -f /etc/default/locale
# rm -f /etc/localtime
# sed -i '/XKBLAYOUT/d' /etc/default/keyboard || true

# =========================
# First-boot GNOME Initial Setup (no pre-created users)
# =========================
echo '[+] Preparing GNOME Initial Setup environment...'

# Remove any pre-existing AccountsService users
rm -rf /var/lib/AccountsService/users/*

# Force gnome-initial-setup to run
rm -rf /var/lib/gnome-initial-setup
mkdir -p /var/lib/gnome-initial-setup
touch /var/lib/gnome-initial-setup/force-new-user

# Remove any auto-login configuration so setup runs properly
sed -i '/AutomaticLogin/d' /etc/gdm3/custom.conf || true
sed -i '/AutomaticLoginEnable/d' /etc/gdm3/custom.conf || true

# Clear locale/time/keyboard so the wizard re-asks
rm -f /etc/default/locale
rm -f /etc/localtime
sed -i '/XKBLAYOUT/d' /etc/default/keyboard || true

# =========================
# Plymouth splash & kernel overlay
# =========================
echo '[+] Configuring Plymouth and kernel overlays...'
echo 'U_BOOT_FDT="device-tree/rockchip/rk3588s-orangepi-5b.dtb"' >> /etc/default/u-boot || true
echo 'U_BOOT_FDT_OVERLAYS="device-tree/rockchip/overlay/rockchip-rk3588-panthor-gpu.dtbo"' >> /etc/default/u-boot || true


# Use Ubuntu's default plymouth theme and enable quiet splash
#update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/ubuntu-gnome-logo/ubuntu-gnome-logo.plymouth 100
#update-alternatives --set default.plymouth /usr/share/plymouth/themes/ubuntu-gnome-logo/ubuntu-gnome-logo.plymouth

# Expand rootfs on first boot
echo 'ext4' >> /etc/initramfs-tools/modules
echo 'resize' >> /etc/initramfs-tools/modules || true

echo '[+] Regenerating initramfs...'
update-initramfs -u -k all

# =========================
# Enable services
# =========================
echo '[+] Enabling system services...'
systemctl set-default graphical.target
systemctl enable gdm3 NetworkManager dbus \
  plymouth-start.service plymouth-read-write.service \
  plymouth-quit-wait.service plymouth-quit.service \
  udisks2 avahi-daemon

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/gvfs-daemon.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=GVFS Daemon
Exec=/usr/libexec/gvfsd
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
EOF

exit
"

umount -lf "${ROOTFS_DIR}/proc" || true
umount -lf "${ROOTFS_DIR}/sys" || true
umount -lf "${ROOTFS_DIR}/dev" || true
umount -lf "${ROOTFS_DIR}/run" || true

# =========================
# 5. Compress result
# =========================
echo '[+] Compressing to tar...'
tar czf rootfs/ubuntu-${SUITE}-desktop-arm64.tar.gz -C ${ROOTFS_DIR} .
