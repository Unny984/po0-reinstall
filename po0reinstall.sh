#!/bin/bash
# po0reinstall.sh - 在目標機器上配置 Alpine DD 重裝環境
# 用法: ./po0reinstall.sh -ip "relay_ip" [-distro ubuntu|debian] [-port 18888]
#
# Bugfix 記錄:
# [FIX1] GRUB 用 search 動態找分區，不寫死 hd0,gpt2（不同機器分區不同）
# [FIX2] 自動 lsblk 偵測根分區，不寫死 /dev/vda2（可能是 vda1 / sda1 等）
# [FIX3] insmod 按依賴順序加載 ext4，不用 modprobe（initramfs 無 modules.dep）
# [FIX4] 先 cp 鏡像到 tmpfs 再 DD，不能邊讀磁碟邊 DD 同一塊磁碟

set -euo pipefail

# ─── 顏色輸出 ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ─── 解析參數 ────────────────────────────────────────────────────────────────
RELAY_IP=""
DISTRO=""
HTTP_PORT=18888

while [[ $# -gt 0 ]]; do
    case "$1" in
        -ip)     RELAY_IP="$2";   shift 2 ;;
        -distro) DISTRO="$2";     shift 2 ;;
        -port)   HTTP_PORT="$2";  shift 2 ;;
        *) echo "用法: $0 -ip <relay_ip> [-distro ubuntu|debian] [-port 18888]"; exit 1 ;;
    esac
done

[[ -z "$RELAY_IP" ]] && { echo "用法: $0 -ip <relay_ip> [-distro ubuntu|debian]"; exit 1; }
RELAY_BASE="http://$RELAY_IP:$HTTP_PORT"

# ─── 必須 root ────────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || die "請用 root 執行此腳本"

# ─── 自動偵測 / 驗證 distro ──────────────────────────────────────────────────
if [[ -z "$DISTRO" ]]; then
    info "未指定 -distro，自動偵測 relay 上的鏡像..."
    AVAILABLE=$(wget -qO- "$RELAY_BASE/images/" 2>/dev/null \
        | grep -oP '(?<=href=")[^"]+\.raw\.xz(?=")' || true)
    COUNT=$(echo "$AVAILABLE" | grep -c '\S' 2>/dev/null || echo 0)
    if [[ "$COUNT" -eq 0 ]]; then
        die "在 $RELAY_BASE/images/ 找不到任何 .raw.xz，請確認 rfcrelay.sh 正在運行"
    elif [[ "$COUNT" -eq 1 ]]; then
        XZ_NAME="$AVAILABLE"
        DISTRO="${XZ_NAME%.raw.xz}"
        success "自動選擇: $XZ_NAME"
    else
        echo "relay 上有多個鏡像，請選擇："
        select XZ_NAME in $AVAILABLE; do
            [[ -n "$XZ_NAME" ]] && break
        done
        DISTRO="${XZ_NAME%.raw.xz}"
        success "已選擇: $XZ_NAME"
    fi
else
    XZ_NAME="${DISTRO}.raw.xz"
    wget -q --spider "$RELAY_BASE/images/$XZ_NAME" 2>/dev/null \
        || die "relay 上找不到 $XZ_NAME，請確認 rfcrelay.sh 已備好該鏡像"
fi

# ─── [FIX2] 自動偵測磁碟和根分區 ─────────────────────────────────────────────
info "偵測目前磁碟配置..."
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || lsblk -no MOUNTPOINT,NAME | awk '$1=="/" {print "/dev/"$2}')

# 取得父磁碟（去掉分區號）
if [[ "$ROOT_DEV" =~ nvme ]]; then
    # nvme0n1p1 → nvme0n1
    ROOT_DISK=$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')
else
    # vda1 / sda2 → vda / sda
    ROOT_DISK=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
fi

TARGET_DISK="$ROOT_DISK"
OLD_ROOT="$ROOT_DEV"

echo ""
echo -e "${YELLOW}偵測結果：${NC}"
echo "  根分區 (OLD_ROOT):  $OLD_ROOT"
echo "  目標磁碟 (DD 到):   $TARGET_DISK"
echo ""
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK" 2>/dev/null || lsblk
echo ""

read -rp "$(echo -e "${RED}警告：DD 會覆蓋 $TARGET_DISK 全部資料！確認繼續？[y/N] ${NC}")" confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }

# ─── 測試中轉機連接 ──────────────────────────────────────────────────────────
info "測試中轉機連接 ($RELAY_IP:$HTTP_PORT)..."
wget -q --spider "$RELAY_BASE/alpine/vmlinuz-virt" 2>/dev/null \
    || die "無法連接中轉機 $RELAY_IP:$HTTP_PORT，請確認 rfcrelay.sh 正在運行"
success "中轉機連接正常"

# ─── 下載 Alpine netboot ─────────────────────────────────────────────────────
NETBOOT_DIR="/root/alpine_netboot"
mkdir -p "$NETBOOT_DIR"
info "下載 Alpine netboot 文件..."
for f in vmlinuz-virt initramfs-virt modloop-virt; do
    info "  $f ..."
    wget -q --show-progress "$RELAY_BASE/alpine/$f" -O "$NETBOOT_DIR/$f" \
        || die "下載 $f 失敗"
done
success "Alpine netboot 就緒"

# ─── 下載 DD 鏡像 ────────────────────────────────────────────────────────────
info "下載 $DISTRO 鏡像 (${XZ_NAME})..."
wget -q --show-progress "$RELAY_BASE/images/$XZ_NAME" -O "/root/dd-image.raw.xz" \
    || die "下載鏡像失敗"
IMG_SIZE=$(du -sh /root/dd-image.raw.xz | cut -f1)
success "鏡像下載完成 ($IMG_SIZE)"

# 驗證 xz 檔案（不是 32 bytes 空檔）
RAW_SIZE=$(xz --robot --list /root/dd-image.raw.xz 2>/dev/null | awk '/^totals/{print $5}' || echo "0")
[[ "$RAW_SIZE" -gt 1000000 ]] || die "鏡像可能損壞（解壓後大小異常: ${RAW_SIZE} bytes），請重新從中轉機下載"
success "鏡像驗證通過（解壓後約 $(( RAW_SIZE / 1024 / 1024 / 1024 )) GB）"

# ─── 建立 initramfs 工作目錄 ─────────────────────────────────────────────────
info "解包 Alpine initramfs..."
INITRD_WORK="/root/initrd_work"
rm -rf "$INITRD_WORK"
mkdir -p "$INITRD_WORK"
cd "$INITRD_WORK"
gzip -d < "$NETBOOT_DIR/initramfs-virt" | cpio -idm 2>/dev/null
success "initramfs 解包完成"

# ─── 提取 ext4 模塊 ──────────────────────────────────────────────────────────
info "從 modloop 提取 ext4 模塊..."
MODLOOP_MNT="/root/modloop_mnt"
mkdir -p "$MODLOOP_MNT"
mount -o loop "$NETBOOT_DIR/modloop-virt" "$MODLOOP_MNT" \
    || die "掛載 modloop-virt 失敗"

# [FIX2] grep -v firmware 過濾，避免取到 firmware 目錄名
KVER=$(ls "$MODLOOP_MNT/modules/" | grep -v firmware | head -1)
[[ -n "$KVER" ]] || die "無法取得內核版本號"
info "  Alpine 內核版本: $KVER"

# ext4 依賴鏈: crc16 → mbcache → jbd2 → ext4
# [FIX3] 必須用 insmod，initramfs 無 modules.dep，modprobe 無法解析依賴
mkdir -p \
    "$INITRD_WORK/lib/modules/$KVER/kernel/lib/crc" \
    "$INITRD_WORK/lib/modules/$KVER/kernel/fs/jbd2" \
    "$INITRD_WORK/lib/modules/$KVER/kernel/fs/ext4"

cp "$MODLOOP_MNT/modules/$KVER/kernel/lib/crc/crc16.ko" \
   "$INITRD_WORK/lib/modules/$KVER/kernel/lib/crc/"
cp "$MODLOOP_MNT/modules/$KVER/kernel/fs/mbcache.ko" \
   "$INITRD_WORK/lib/modules/$KVER/kernel/fs/"
cp "$MODLOOP_MNT/modules/$KVER/kernel/fs/jbd2/jbd2.ko" \
   "$INITRD_WORK/lib/modules/$KVER/kernel/fs/jbd2/"
cp "$MODLOOP_MNT/modules/$KVER/kernel/fs/ext4/ext4.ko" \
   "$INITRD_WORK/lib/modules/$KVER/kernel/fs/ext4/"

umount "$MODLOOP_MNT"
rmdir "$MODLOOP_MNT"
success "ext4 模塊提取完成"

# ─── 寫入自定義 init 腳本 ─────────────────────────────────────────────────────
info "生成 init 腳本..."
cd "$INITRD_WORK"
mv init init.orig

# 把偵測到的分區值嵌入 init 腳本（$OLD_ROOT / $TARGET_DISK 在此展開）
# 其他 $VAR 用 \$ 轉義，保留到 initramfs 執行時再求值
cat > init << INIT_HEREDOC
#!/bin/sh
# ── Alpine DD init script (auto-generated by po0reinstall.sh) ──
/bin/busybox mkdir -p /bin /sbin /usr/bin /usr/sbin /proc /sys /dev /tmp /mnt /mnt/old
/bin/busybox --install -s
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
# [FIX4] tmpfs 放鏡像，大小要夠（壓縮後 ~500M）
mount -t tmpfs -o size=700m tmpfs /tmp

echo "==> Loading virtio drivers (KVM 虛擬化必需)"
modprobe virtio_pci 2>/dev/null || true
modprobe virtio_blk 2>/dev/null || true

echo "==> Loading ext4 (insmod 依賴順序: crc16 → mbcache → jbd2 → ext4)"
# [FIX3] 必須 insmod，不能 modprobe（無 modules.dep）
KVER=\$(ls /lib/modules/ | grep -v firmware | head -1)
insmod /lib/modules/\$KVER/kernel/lib/crc/crc16.ko  2>/dev/null || true
insmod /lib/modules/\$KVER/kernel/fs/mbcache.ko
insmod /lib/modules/\$KVER/kernel/fs/jbd2/jbd2.ko
insmod /lib/modules/\$KVER/kernel/fs/ext4/ext4.ko

sleep 3
mdev -s

# ── 安全檢查 ──
grep -q ext4 /proc/filesystems || { echo "FATAL: ext4 未加載"; exec sh; }

# 偵測到的值（由 po0reinstall.sh 在此機器上自動填入）
OLD_ROOT="${OLD_ROOT}"
TARGET_DISK="${TARGET_DISK}"

[ -b "\$TARGET_DISK" ] || {
    echo "FATAL: \$TARGET_DISK 不存在，可用磁碟："
    ls /dev/vd* /dev/sd* /dev/nvme* 2>/dev/null
    exec sh
}
echo "==> 根分區: \$OLD_ROOT | 目標磁碟: \$TARGET_DISK"

# ── 掛載舊分區，把鏡像複製到 RAM ──
# [FIX4] 鏡像和 DD 目標是同一塊磁碟，必須先 cp 到 tmpfs 再 DD
echo "==> 掛載舊分區 \$OLD_ROOT (唯讀)"
mount -t ext4 -o ro "\$OLD_ROOT" /mnt/old || { echo "FATAL: 掛載失敗"; exec sh; }

echo "==> 複製鏡像到 RAM (tmpfs)..."
cp /mnt/old/root/dd-image.raw.xz /tmp/image.xz || { echo "FATAL: 複製失敗（空間不足？）"; exec sh; }
umount /mnt/old
echo "==> 鏡像已加載到 RAM"

# ── 執行 DD ──
echo "==> DD 開始..."
xzcat /tmp/image.xz | dd of=\$TARGET_DISK bs=4M 2>&1
sync
echo ""

# ── DD 後自動擴容（cloud image 分區通常只有 2-3G）──
echo "==> 擴容分區到磁碟最大..."
# 找到第一個分區號
PART_NUM=\$(ls \${TARGET_DISK}* 2>/dev/null | grep -oE '[0-9]+$' | head -1)
if [ -n "\$PART_NUM" ]; then
    growpart \$TARGET_DISK \$PART_NUM 2>&1 && echo "==> growpart 完成" || echo "==> growpart 失敗（跳過）"
    PART_DEV="\${TARGET_DISK}\${PART_NUM}"
    # nvme 格式是 p1
    [ -b "\$PART_DEV" ] || PART_DEV="\${TARGET_DISK}p\${PART_NUM}"
    resize2fs \$PART_DEV 2>&1 && echo "==> resize2fs 完成" || echo "==> resize2fs 失敗（跳過）"
else
    echo "==> 找不到分區號，跳過擴容"
fi
sync

echo "==> 完成！5 秒後重啟..."
sleep 5
reboot -f
INIT_HEREDOC

chmod +x init

# ─── 重打包 initramfs ─────────────────────────────────────────────────────────
info "打包新 initramfs..."
cd "$INITRD_WORK"
ORIG_SIZE=$(du -sh "$NETBOOT_DIR/initramfs-virt" | cut -f1)
find . | cpio -o -H newc 2>/dev/null | gzip > /boot/initramfs-dd.img
NEW_SIZE=$(du -sh /boot/initramfs-dd.img | cut -f1)
info "  原始 initramfs: $ORIG_SIZE  →  新 initramfs: $NEW_SIZE（含 ext4 模塊）"
# 模塊約 +0.5MB，若大小一樣代表打包失敗
cp "$NETBOOT_DIR/vmlinuz-virt" /boot/vmlinuz-dd
success "initramfs 打包完成"

# 清理工作目錄
cd /
rm -rf "$INITRD_WORK"

# ─── 配置 GRUB ───────────────────────────────────────────────────────────────
info "配置 GRUB..."

# [FIX1] 用 search 動態找 /boot/vmlinuz-dd 所在分區，不寫死 hd0,gpt2
cat > /etc/grub.d/99_dd << 'GRUB_EOF'
#!/bin/sh
cat << 'MENUENTRY'
menuentry "DD Reinstall" {
    insmod gzio
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    search --no-floppy --file --set=root /boot/vmlinuz-dd
    linux /boot/vmlinuz-dd
    initrd /boot/initramfs-dd.img
}
MENUENTRY
GRUB_EOF
chmod +x /etc/grub.d/99_dd

# GRUB 參數
GRUB_CFG="/etc/default/grub"
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/'       "$GRUB_CFG"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/'           "$GRUB_CFG"
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_CFG"
grep -q "^GRUB_SAVEDEFAULT" "$GRUB_CFG" && sed -i '/^GRUB_SAVEDEFAULT/d' "$GRUB_CFG"

update-grub 2>&1 | grep -E "Found|Generating" || true
grub-reboot "DD Reinstall" \
    || die "grub-reboot 失敗（請確認 GRUB_DEFAULT=saved 已寫入）"
success "GRUB 配置完成，下次啟動自動進入 DD 模式"

# ─── 最終摘要 ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN} 配置完成！重啟後將自動執行 DD              ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "  系統:         ${YELLOW}${DISTRO}${NC}"
echo -e "  鏡像位置:     ${YELLOW}/root/dd-image.raw.xz (${IMG_SIZE})${NC}"
echo -e "  DD 目標:      ${YELLOW}${TARGET_DISK}${NC}"
echo -e "  來源分區:     ${YELLOW}${OLD_ROOT}${NC}"
echo -e "  initramfs:    ${YELLOW}/boot/initramfs-dd.img (${NEW_SIZE})${NC}"
echo ""
echo -e "${CYAN}流程：重啟 → GRUB 自動選 'DD Reinstall' → Alpine init → DD → 重啟 → 新系統${NC}"
echo -e "${CYAN}如有 VNC/IPMI，可觀察進度；無人值守也會自動完成。${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}現在重啟？[y/N] ${NC}")" do_reboot
if [[ "$do_reboot" =~ ^[Yy]$ ]]; then
    info "正在重啟..."
    reboot
else
    echo "準備好後執行 'reboot' 即可。"
fi