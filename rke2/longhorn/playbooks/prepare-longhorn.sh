#!/usr/bin/env bash

set -euo pipefail

# =========================
# Config
# =========================
LONGHORN_DISK_DEVICE="${LONGHORN_DISK_DEVICE:-/dev/sdb}"
LONGHORN_DISK_MOUNT="${LONGHORN_DISK_MOUNT:-/var/lib/longhorn}"
LONGHORN_DISK_FSTYPE="${LONGHORN_DISK_FSTYPE:-ext4}"
LONGHORN_FORMAT_DISK="${LONGHORN_FORMAT_DISK:-false}"

echo "===================================="
echo "Longhorn Disk Preparation"
echo "===================================="
echo "Device : $LONGHORN_DISK_DEVICE"
echo "Mount  : $LONGHORN_DISK_MOUNT"
echo "FS     : $LONGHORN_DISK_FSTYPE"
echo "Format : $LONGHORN_FORMAT_DISK"
echo

# =========================
# Install dependencies
# =========================
echo "[1/9] Installing Longhorn dependencies..."

apt-get update

apt-get install -y \
    open-iscsi \
    nfs-common \
    e2fsprogs \
    util-linux

# =========================
# Enable iSCSI
# =========================
echo "[2/9] Enabling iSCSI service..."

systemctl enable iscsid
systemctl restart iscsid

# =========================
# Check disk existence
# =========================
echo "[3/9] Checking disk..."

if [[ ! -b "$LONGHORN_DISK_DEVICE" ]]; then
    echo "ERROR: $LONGHORN_DISK_DEVICE does not exist"
    exit 1
fi

# =========================
# Check filesystem
# =========================
echo "[4/9] Detecting filesystem..."

CURRENT_FS=$(blkid -o value -s TYPE "$LONGHORN_DISK_DEVICE" 2>/dev/null || true)

if [[ -z "$CURRENT_FS" ]]; then

    if [[ "$LONGHORN_FORMAT_DISK" != "true" ]]; then
        echo
        echo "ERROR:"
        echo "$LONGHORN_DISK_DEVICE has no filesystem."
        echo
        echo "Re-run with:"
        echo "LONGHORN_FORMAT_DISK=true ./prepare-longhorn.sh"
        exit 1
    fi

    echo "[5/9] Formatting disk..."

    mkfs."$LONGHORN_DISK_FSTYPE" -F "$LONGHORN_DISK_DEVICE"

else

    if [[ "$CURRENT_FS" != "$LONGHORN_DISK_FSTYPE" ]]; then
        echo
        echo "ERROR:"
        echo "$LONGHORN_DISK_DEVICE already contains filesystem $CURRENT_FS"
        echo "Expected $LONGHORN_DISK_FSTYPE"
        exit 1
    fi

    echo "Filesystem already exists: $CURRENT_FS"

fi

# =========================
# Create mountpoint
# =========================
echo "[6/9] Creating mount directory..."

mkdir -p "$LONGHORN_DISK_MOUNT"

# =========================
# Get UUID
# =========================
echo "[7/9] Reading UUID..."

UUID=$(blkid -o value -s UUID "$LONGHORN_DISK_DEVICE")

if [[ -z "$UUID" ]]; then
    echo "ERROR: Cannot determine UUID"
    exit 1
fi

# =========================
# Update fstab
# =========================
echo "[8/9] Updating /etc/fstab..."

FSTAB_LINE="UUID=$UUID $LONGHORN_DISK_MOUNT $LONGHORN_DISK_FSTYPE defaults,noatime 0 2"

if grep -qE "[[:space:]]$LONGHORN_DISK_MOUNT[[:space:]]" /etc/fstab; then
    sed -i "\|$LONGHORN_DISK_MOUNT|d" /etc/fstab
fi

echo "$FSTAB_LINE" >> /etc/fstab

# =========================
# Mount
# =========================
echo "[9/9] Mounting disk..."

if ! mountpoint -q "$LONGHORN_DISK_MOUNT"; then
    mount "$LONGHORN_DISK_MOUNT"
fi

echo
echo "Mounted successfully:"
findmnt "$LONGHORN_DISK_MOUNT"

echo
echo "Disk usage:"
df -h "$LONGHORN_DISK_MOUNT"

echo
echo "Longhorn disk preparation completed."