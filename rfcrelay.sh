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
GITHUB_RAW="https://raw.githubusercontent.com/Unny984/po0-reinstall/refs/heads/main"

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
        # 轉完立刻刪 qcow2，節省空間
        rm -f "$IMG_PATH"
        info "  qcow2 已刪除，節省空間"
    elif [[ "$FORMAT" == "raw" ]]; then
        info "已是 raw 格式，複製..."
        cp "$IMG_PATH" "$RAW_PATH"
    else
        die "不支援的格式: $FORMAT"
    fi
fi
success "raw 轉換完成 ($(du -sh "$RAW_PATH" | cut -f1))"

# ─── loop mount：預設 root 密碼 + SSH ───────────────────────────────────────
info "注入 root 密碼 + 啟用 SSH 密碼登入（loop mount）..."

# 先初始化變數、設 trap，確保任何情況下都會清理
LOOP=""
TMP_MNT=""
cleanup_mount() {
    [[ -n "$TMP_MNT" ]] || return
    umount "$TMP_MNT/dev/pts" 2>/dev/null || true
    umount "$TMP_MNT/dev"     2>/dev/null || true
    umount "$TMP_MNT/sys"     2>/dev/null || true
    umount "$TMP_MNT/proc"    2>/dev/null || true
    umount "$TMP_MNT"         2>/dev/null || umount -l "$TMP_MNT" 2>/dev/null || true
    rmdir  "$TMP_MNT"         2>/dev/null || true
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup_mount EXIT INT TERM

LOOP=$(losetup -f --show -P "$RAW_PATH") || die "losetup 失敗"
TMP_MNT=$(mktemp -d /root/mnt_dd.XXXX)

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
    die "找不到根分區，請確認鏡像格式"
fi
info "  根分區: $ROOT_PART"

mount "$ROOT_PART" "$TMP_MNT" || die "掛載根分區失敗"

# 在 host 直接生成 SHA-512 hash，寫入 shadow（不依賴 chroot chpasswd）
info "  生成密碼 hash..."
if command -v openssl >/dev/null && openssl passwd --help 2>&1 | grep -q '\-6'; then
    PASS_HASH=$(openssl passwd -6 "$PASSWORD")
elif command -v python3 >/dev/null; then
    PASS_HASH=$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "$PASSWORD")
else
    die "找不到 openssl -6 或 python3 來生成密碼 hash"
fi

SHADOW="$TMP_MNT/etc/shadow"
if [[ -f "$SHADOW" ]]; then
    # 替換 root 的密碼欄位（第2欄）
    sed -i "s|^root:[^:]*:|root:${PASS_HASH}:|" "$SHADOW"
    # 確認有 root 行（萬一沒有就新增）
    grep -q "^root:" "$SHADOW" || echo "root:${PASS_HASH}:0:0:99999:7:::" >> "$SHADOW"
    # 解鎖 root（移除前面的 ! 或 *）
    sed -i 's|^root:!|root:|; s|^root:\*|root:|' "$SHADOW"
    success "  /etc/shadow root 密碼直寫完成"
else
    warn "  找不到 /etc/shadow"
fi

# 啟用 SSH root 登入 + 密碼認證
SSH_CFG="$TMP_MNT/etc/ssh/sshd_config"
if [[ -f "$SSH_CFG" ]]; then
    sed -i 's/^#*\s*PermitRootLogin.*/PermitRootLogin yes/'            "$SSH_CFG"
    sed -i 's/^#*\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CFG"
    grep -q "^PermitRootLogin"        "$SSH_CFG" || echo "PermitRootLogin yes"      >> "$SSH_CFG"
    grep -q "^PasswordAuthentication" "$SSH_CFG" || echo "PasswordAuthentication yes" >> "$SSH_CFG"
    success "  sshd_config 修改完成"
fi

# 處理 sshd_config.d/ 下的覆蓋檔（Ubuntu cloud image 有 60-cloudimg-settings.conf）
SSHD_CONF_D="$TMP_MNT/etc/ssh/sshd_config.d"
if [[ -d "$SSHD_CONF_D" ]]; then
    for f in "$SSHD_CONF_D"/*.conf; do
        [[ -f "$f" ]] || continue
        sed -i 's/^#*\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$f"
        sed -i 's/^#*\s*PermitRootLogin.*/PermitRootLogin yes/'               "$f"
    done
    # 加一個最高優先級覆蓋檔確保設定生效
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' \
        > "$SSHD_CONF_D/99-reinstall.conf"
    success "  sshd_config.d 處理完成"
fi

# 完全停用 cloud-init（最可靠，防止它重設密碼/SSH/亂改設定）
touch "$TMP_MNT/etc/cloud/cloud-init.disabled"
success "  cloud-init 已停用"

# 補網路設定（cloud-init 停用後靠 /etc/network/interfaces 起網路）
info "注入網路設定..."
NET_IFACE_CFG="$TMP_MNT/etc/network/interfaces"
if [[ -f "$NET_IFACE_CFG" ]] && grep -q "dhcp" "$NET_IFACE_CFG"; then
    success "  /etc/network/interfaces 已有 DHCP 設定"
else
    cat > "$NET_IFACE_CFG" << 'NETEOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto ens3
iface ens3 inet dhcp

auto ens5
iface ens5 inet dhcp

auto enp1s0
iface enp1s0 inet dhcp
NETEOF
    success "  /etc/network/interfaces 建立完成"
fi

# 注入首次開機自動擴容腳本（DD 後分區只有 cloud image 大小，需擴到磁碟實際大小）
info "注入自動擴容腳本..."
cat > "$TMP_MNT/etc/rc.local" << 'RCEOF'
#!/bin/bash
# 首次開機自動擴容 - 執行一次後自我刪除
MARKER="/etc/.disk-expanded"
if [[ ! -f "$MARKER" ]]; then
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || cat /proc/mounts | awk '$2=="/" {print $1}')
    if [[ "$ROOT_DEV" =~ nvme ]]; then
        DISK=$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')
        PART_NUM=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')
    else
        DISK=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
        PART_NUM=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')
    fi
    growpart "$DISK" "$PART_NUM" 2>&1 | logger -t rc.local
    resize2fs "$ROOT_DEV"        2>&1 | logger -t rc.local
    touch "$MARKER"
    logger -t rc.local "disk expand done: $ROOT_DEV"
fi
exit 0
RCEOF
chmod +x "$TMP_MNT/etc/rc.local"
# 確保 rc-local.service 啟用（Debian/Ubuntu 預設不啟用）
RC_LOCAL_SVC="$TMP_MNT/etc/systemd/system/rc-local.service"
if [[ ! -f "$RC_LOCAL_SVC" ]]; then
    cat > "$RC_LOCAL_SVC" << 'SVCEOF'
[Unit]
Description=Run /etc/rc.local on first boot
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/rc.local
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
fi
mkdir -p "$TMP_MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rc-local.service \
    "$TMP_MNT/etc/systemd/system/multi-user.target.wants/rc-local.service" 2>/dev/null || true
success "  自動擴容腳本注入完成（首次開機執行，之後自動停用）"

# 預生成 SSH host keys（防止新系統第一次起動時 sshd 因找不到 hostkey 而失敗）
info "預生成 SSH host keys..."
SSHD_DIR="$TMP_MNT/etc/ssh"
mkdir -p "$SSHD_DIR"
for keytype in rsa ecdsa ed25519; do
    keyfile="$SSHD_DIR/ssh_host_${keytype}_key"
    if [[ ! -f "$keyfile" ]]; then
        ssh-keygen -q -t "$keytype" -N "" -f "$keyfile" 2>/dev/null \
            && success "  生成 ssh_host_${keytype}_key" \
            || warn "  生成 ${keytype} key 失敗（跳過）"
    fi
done

# 保留 cloud.cfg 修改作為雙重保障
mkdir -p "$TMP_MNT/etc/cloud/cloud.cfg.d"
printf 'ssh_pwauth: true\ndisable_root: false\n' \
    > "$TMP_MNT/etc/cloud/cloud.cfg.d/99_dd.cfg"

CLOUD_CFG="$TMP_MNT/etc/cloud/cloud.cfg"
if [[ -f "$CLOUD_CFG" ]]; then
    sed -i 's/disable_root:\s*true/disable_root: false/'   "$CLOUD_CFG"
    sed -i 's/ssh_pwauth:\s*false/ssh_pwauth: true/'       "$CLOUD_CFG"
    sed -i 's/ssh_pwauth:\s*0/ssh_pwauth: true/'           "$CLOUD_CFG"
    sed -i '/^\s*-\s*set-passwords/d'                      "$CLOUD_CFG"
fi

# ── SSH host keys 預生成（cloud image 通常沒有，sshd 起不來）──────────────────
info "預生成 SSH host keys..."
for keytype in rsa ecdsa ed25519; do
    keyfile="$TMP_MNT/etc/ssh/ssh_host_${keytype}_key"
    if [[ ! -f "$keyfile" ]]; then
        ssh-keygen -t "$keytype" -N "" -f "$keyfile" -q \
            && success "  生成 ${keytype} host key" \
            || warn "  生成 ${keytype} key 失敗"
    fi
done

# ── apt 換騰訊雲鏡像源 ────────────────────────────────────────────────────────
info "設定騰訊雲 apt 鏡像源..."
# 偵測 codename（從 /etc/os-release 或 /etc/debian_version）
CODENAME=""
if [[ -f "$TMP_MNT/etc/os-release" ]]; then
    CODENAME=$(grep "^VERSION_CODENAME=" "$TMP_MNT/etc/os-release" | cut -d= -f2 | tr -d '"')
fi
[[ -z "$CODENAME" ]] && CODENAME="bookworm"  # fallback

info "  偵測到 codename: $CODENAME"

case "$DISTRO" in
    debian)
        cat > "$TMP_MNT/etc/apt/sources.list" << APTEOF
deb https://mirrors.cloud.tencent.com/debian/ ${CODENAME} main contrib non-free non-free-firmware
deb https://mirrors.cloud.tencent.com/debian/ ${CODENAME}-updates main contrib non-free non-free-firmware
deb https://mirrors.cloud.tencent.com/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
APTEOF
        # 清掉可能存在的 sources.list.d（cloud image 有時會放額外 sources）
        rm -f "$TMP_MNT/etc/apt/sources.list.d/debian.sources" 2>/dev/null || true
        success "  apt 已換為騰訊雲 Debian 源 ($CODENAME)"
        ;;
    ubuntu)
        cat > "$TMP_MNT/etc/apt/sources.list" << APTEOF
deb https://mirrors.cloud.tencent.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://mirrors.cloud.tencent.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb https://mirrors.cloud.tencent.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb https://mirrors.cloud.tencent.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
APTEOF
        success "  apt 已換為騰訊雲 Ubuntu 源 ($CODENAME)"
        ;;
esac

# ── 預裝 ifupdown + isc-dhcp-client（cloud image 通常沒有）────────────────────
info "預裝 ifupdown + dhclient..."
mount --bind /proc    "$TMP_MNT/proc"
mount --bind /sys     "$TMP_MNT/sys"
mount --bind /dev     "$TMP_MNT/dev"
mount --bind /dev/pts "$TMP_MNT/dev/pts" 2>/dev/null || true
rm -f "$TMP_MNT/etc/resolv.conf"
cp /etc/resolv.conf "$TMP_MNT/etc/resolv.conf"

chroot "$TMP_MNT" apt-get update -qq \
    && chroot "$TMP_MNT" apt-get install -y -q ifupdown isc-dhcp-client \
    && success "  ifupdown + dhclient 安裝完成" \
    || warn "  apt-get 失敗，開機後手動執行: apt install ifupdown isc-dhcp-client"

trap - EXIT   # 清除 trap，統一由下面 cleanup_mount 處理
cleanup_mount
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
    # 壓縮完立刻刪 raw，節省空間
    rm -f "$RAW_PATH"
fi
success "壓縮完成 ($(du -sh "$XZ_PATH" | cut -f1))"

# ─── 清理暫時檔案 ─────────────────────────────────────────────────────────────
info "清理暫時文件..."
rm -f "$RAW_PATH" "$IMG_PATH"
rmdir "$WORK_DIR" 2>/dev/null || true

# ─── 下載 po0reinstall.sh 供目標機器使用 ────────────────────────────────────
info "下載 po0reinstall.sh..."
wget -q "$GITHUB_RAW/po0reinstall.sh" -O "$SERVE_DIR/po0reinstall.sh" \
    && chmod +x "$SERVE_DIR/po0reinstall.sh" \
    && success "po0reinstall.sh 就緒" \
    || warn "下載 po0reinstall.sh 失敗，目標機器需手動下載"

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
MY_IP="${MY_IP:-<中轉機IP>}"

echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} 在目標機器 (po0) 上執行以下一行指令：${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${YELLOW}bash <(curl -s http://${MY_IP}:${HTTP_PORT}/po0reinstall.sh) -ip \"${MY_IP}\"${NC}"
echo ""
echo -e "${CYAN}HTTP 服務器啟動中 (port $HTTP_PORT)，按 Ctrl+C 停止...${NC}"
echo ""

# [FIX3] HTTP server 服務 /srv/mini-reinstall 而非 /root
cd "$SERVE_DIR"
exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0