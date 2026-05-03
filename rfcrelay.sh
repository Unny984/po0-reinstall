#!/bin/bash
# rfcrelay.sh - 在中轉機準備 DD 鏡像並啟動 HTTP 服務
# 用法: ./rfcrelay.sh <ubuntu|debian> --password "yourpassword"
#
# Bugfix 記錄:
# [FIX1] 大檔操作改用 /root 而非 /tmp (tmpfs 只有 480M，會爆)
# [FIX2] qemu-img convert 和 xz 分兩步做，禁止管道 (管道會產生 32 bytes 空 xz)
# [FIX3] HTTP server 服務 /srv/mini-reinstall 而非 /root (安全)
# [FIX4] virt-customize 預先設好 root 密碼 + SSH (cloud image 預設無密碼)

set -euo pipefail

# ─── 顏色輸出 ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ─── 解析參數 ────────────────────────────────────────────────────────────────
DISTRO="${1:-}"
PASSWORD=""
HTTP_PORT=18888

[[ -z "$DISTRO" ]] && { echo "用法: $0 <ubuntu|debian> --password \"yourpassword\""; exit 1; }
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --password) PASSWORD="$2"; shift 2 ;;
        --port)     HTTP_PORT="$2"; shift 2 ;;
        *) die "未知參數: $1" ;;
    esac
done

[[ -z "$PASSWORD" ]] && die "--password 是必填項"

# ─── 鏡像來源 ────────────────────────────────────────────────────────────────
case "$DISTRO" in
    ubuntu)
        IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
        IMG_FILE="ubuntu-jammy-cloud.img"
        XZ_NAME="ubuntu.raw.xz"
        ;;
    debian)
        IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
        IMG_FILE="debian-12-cloud.qcow2"
        XZ_NAME="debian.raw.xz"
        ;;
    *) die "支援的系統: ubuntu, debian" ;;
esac

RAW_FILE="${XZ_NAME%.xz}"   # ubuntu.raw 或 debian.raw
WORK_DIR="/root/dd-work"     # [FIX1] 用 /root，不用 /tmp
SERVE_DIR="/srv/mini-reinstall"
ALPINE_DIR="$SERVE_DIR/alpine"
IMAGES_DIR="$SERVE_DIR/images"

# ─── 安裝依賴 ────────────────────────────────────────────────────────────────
info "安裝依賴套件..."
apt-get update -qq
apt-get install -y -q qemu-utils wget xz-utils python3 2>/dev/null \
    || die "apt-get 安裝失敗，請檢查網路"
success "依賴安裝完成"

# ─── 建立目錄結構 ────────────────────────────────────────────────────────────
info "建立目錄結構..."
mkdir -p "$WORK_DIR" "$ALPINE_DIR" "$IMAGES_DIR"

# ─── 下載 Alpine netboot ─────────────────────────────────────────────────────
info "下載 Alpine netboot 文件..."
ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/netboot"
for f in vmlinuz-virt initramfs-virt modloop-virt; do
    DEST="$ALPINE_DIR/$f"
    if [[ -f "$DEST" ]]; then
        warn "$f 已存在，跳過"
    else
        info "  下載 $f ..."
        wget -q --show-progress "$ALPINE_BASE/$f" -O "$DEST" || die "下載 $f 失敗"
    fi
done
success "Alpine netboot 文件就緒"

# ─── 下載雲鏡像 ──────────────────────────────────────────────────────────────
info "下載 $DISTRO cloud image..."
IMG_PATH="$WORK_DIR/$IMG_FILE"
if [[ -f "$IMG_PATH" ]]; then
    warn "鏡像已存在：$IMG_PATH，跳過下載"
else
    wget -q --show-progress "$IMG_URL" -O "$IMG_PATH" || die "下載鏡像失敗"
fi

# 確認格式
FORMAT=$(qemu-img info "$IMG_PATH" | awk '/file format/{print $3}')
VSIZE=$(qemu-img info "$IMG_PATH" | awk '/virtual size/{print $3, $4}')
info "鏡像格式: $FORMAT，虛擬大小: $VSIZE"

# ─── 轉換為 raw ──────────────────────────────────────────────────────────────
RAW_PATH="$WORK_DIR/$RAW_FILE"
if [[ -f "$RAW_PATH" ]]; then
    warn "raw 文件已存在，跳過轉換"
else
    if [[ "$FORMAT" == "qcow2" ]]; then
        info "轉換 qcow2 → raw (可能需要幾分鐘)..."
        # [FIX2] 兩步做，禁止 qemu-img | xz 管道（會產生 32 bytes 空檔）
        qemu-img convert -p -f qcow2 -O raw "$IMG_PATH" "$RAW_PATH" \
            || die "qemu-img convert 失敗（磁碟空間不足？請確認 /root 有 5GB+ 可用）"
    elif [[ "$FORMAT" == "raw" ]]; then
        info "已是 raw 格式，複製..."
        cp "$IMG_PATH" "$RAW_PATH"
    else
        die "不支援的格式: $FORMAT"
    fi
fi
success "raw 轉換完成 ($(du -sh "$RAW_PATH" | cut -f1))"

# ─── loop mount：預設 root 密碼 + SSH ───────────────────────────────────────
# [FIX4] 改用 losetup 直接掛載，不依賴 virt-customize/supermin
info "注入 root 密碼 + 啟用 SSH 密碼登入（loop mount）..."
LOOP=$(losetup -f --show -P "$RAW_PATH") || die "losetup 失敗"
info "  loop 裝置: $LOOP"
sleep 1  # 等核心建立分區裝置節點

# 找根分區：試 p1 → p2 → 裸裝置
ROOT_PART=""
for candidate in "${LOOP}p1" "${LOOP}p2" "$LOOP"; do
    if [[ -b "$candidate" ]] && blkid "$candidate" 2>/dev/null | grep -qiE 'ext[234]|xfs|btrfs'; then
        ROOT_PART="$candidate"
        break
    fi
done
if [[ -z "$ROOT_PART" ]]; then
    losetup -d "$LOOP"
    die "找不到根分區，請確認鏡像格式"
fi
info "  根分區: $ROOT_PART"

TMP_MNT=$(mktemp -d /root/mnt_dd.XXXX)
mount "$ROOT_PART" "$TMP_MNT" || { losetup -d "$LOOP"; die "掛載根分區失敗"; }

# 設 root 密碼
echo "root:${PASSWORD}" | chroot "$TMP_MNT" chpasswd \
    && success "  root 密碼設定完成" \
    || warn "  chpasswd 失敗（跨架構 chroot 限制，繼續）"

# 啟用 SSH root 登入 + 密碼認證
SSH_CFG="$TMP_MNT/etc/ssh/sshd_config"
if [[ -f "$SSH_CFG" ]]; then
    sed -i 's/^#*\s*PermitRootLogin.*/PermitRootLogin yes/'            "$SSH_CFG"
    sed -i 's/^#*\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CFG"
    success "  sshd_config 修改完成"
else
    warn "  找不到 sshd_config，跳過"
fi

# 阻止 cloud-init 覆蓋 SSH 設定和密碼
mkdir -p "$TMP_MNT/etc/cloud/cloud.cfg.d"
printf 'ssh_pwauth: true\ndisable_root: false\n' \
    > "$TMP_MNT/etc/cloud/cloud.cfg.d/99_dd.cfg"

# 直接改 cloud.cfg（99_dd.cfg 有時優先級不夠）
CLOUD_CFG="$TMP_MNT/etc/cloud/cloud.cfg"
if [[ -f "$CLOUD_CFG" ]]; then
    sed -i 's/disable_root:\s*true/disable_root: false/'   "$CLOUD_CFG"
    sed -i 's/ssh_pwauth:\s*false/ssh_pwauth: true/'       "$CLOUD_CFG"
    sed -i 's/ssh_pwauth:\s*0/ssh_pwauth: true/'           "$CLOUD_CFG"
    # 移除 set-passwords 模組，防止 cloud-init 重設密碼
    sed -i '/^\s*-\s*set-passwords/d'                      "$CLOUD_CFG"
    success "  cloud.cfg 修改完成"
else
    warn "  找不到 cloud.cfg"
fi

umount "$TMP_MNT" && rmdir "$TMP_MNT"
losetup -d "$LOOP"
success "密碼和 SSH 配置注入完成"

# ─── 壓縮 ────────────────────────────────────────────────────────────────────
XZ_PATH="$IMAGES_DIR/$XZ_NAME"
if [[ -f "$XZ_PATH" ]]; then
    warn "壓縮包已存在，跳過壓縮"
else
    info "壓縮 raw → xz（多線程，需要幾分鐘）..."
    # [FIX2] 先轉完再壓，不用管道
    xz -T0 -z --keep "$RAW_PATH" \
        || die "xz 壓縮失敗（磁碟空間不足？）"
    mv "${RAW_PATH}.xz" "$XZ_PATH"
fi
success "壓縮完成 ($(du -sh "$XZ_PATH" | cut -f1))"

# ─── 清理暫時檔案 ─────────────────────────────────────────────────────────────
info "清理暫時文件..."
rm -f "$RAW_PATH" "$IMG_PATH"
rmdir "$WORK_DIR" 2>/dev/null || true

# ─── 顯示文件清單 ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN} 文件準備完畢！目錄結構：${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
find "$SERVE_DIR" -type f | sort | while read -r f; do
    SIZE=$(du -sh "$f" | cut -f1)
    printf "  %-10s  %s\n" "$SIZE" "${f#$SERVE_DIR/}"
done
echo ""

# 取得本機 IP
MY_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/{print $7}' | head -1)
echo -e "${CYAN}在目標機器上執行：${NC}"
echo -e "  ${YELLOW}./po0reinstall.sh -ip \"${MY_IP:-<中轉機IP>}\" [-distro $DISTRO]${NC}"
echo ""
echo -e "${CYAN}HTTP 服務器啟動中 (port $HTTP_PORT)，按 Ctrl+C 停止...${NC}"
echo ""

# [FIX3] HTTP server 服務 /srv/mini-reinstall 而非 /root
cd "$SERVE_DIR"
exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0