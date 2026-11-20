#!/usr/bin/env bash
# =============================================================================
# Waydroid One-Click Installer / Uninstaller  (optimized for BigLinux)
# Trình cài đặt / gỡ bỏ Waydroid một chạm (tối ưu cho BigLinux)
#
# Logic / Logic:
#   - Waydroid NOT installed -> install everything automatically (uninstall disabled)
#   - Waydroid installed     -> uninstall only (install disabled)
#   No questions are asked. / Không hỏi ý kiến người dùng.
#
# Reference / Tham khảo: https://github.com/casualsnek/waydroid_script
# Runs as the current logged-in user; root parts use sudo.
# Does NOT autostart, does NOT touch login/boot configuration.
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------- bootstrap --
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# If started as root via sudo, drop back to the real user.
# Nếu chạy bằng sudo, quay lại tài khoản người dùng thật.
if [ "$EUID" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        exec sudo -u "$SUDO_USER" -H bash "$SCRIPT_PATH" "$@"
    fi
    echo "Please run as a normal user. | Hãy chạy bằng tài khoản người dùng thường." >&2
    exit 1
fi

# Double-click from a file manager (no terminal) -> reopen inside a terminal.
# Nhấp đúp từ trình quản lý tệp (không có terminal) -> mở lại trong terminal.
if [ ! -t 1 ] && [ -z "${WAYDROID_INSTALLER_TTY:-}" ]; then
    export WAYDROID_INSTALLER_TTY=1
    for t in konsole gnome-terminal xfce4-terminal kgx alacritty xterm; do
        if command -v "$t" >/dev/null 2>&1; then
            case "$t" in
                gnome-terminal|kgx) exec "$t" -- bash "$SCRIPT_PATH" "$@" ;;
                *)                  exec "$t" -e bash "$SCRIPT_PATH" "$@" ;;
            esac
        fi
    done
fi

# ------------------------------------------------------------------ logging --
# Log folder next to the script; fall back to user state dir if not writable.
# Thư mục log cùng vị trí script; nếu không ghi được thì dùng thư mục của người dùng.
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
if [ ! -w "$LOG_DIR" ]; then
    LOG_DIR="$HOME/.local/state/waydroid-installer/log"
    mkdir -p "$LOG_DIR"
fi
LOG_FILE="$LOG_DIR/waydroid-installer_$(date +%Y%m%d_%H%M%S).log"
FIX_HISTORY="$LOG_DIR/fix-history.log"   # errors + applied fixes across all runs
exec > >(tee -a "$LOG_FILE") 2>&1        # one session only, no autostart

# ------------------------------------------------------------------ state ---
TMP_DIR="$(mktemp -d /tmp/waydroid-installer.XXXXXX)"
ERR_COUNT=0
ERR_LIST=()
STEP=0
TOTAL_STEPS=0
LAST_NOTIFY=""
declare -A DONE_ONCE=()                  # never repeat the same check/fix
HELPER_DIR="$HOME/.local/share/waydroid-helper"
APK_DESKTOP="$HOME/.local/share/applications/waydroid-apk-installer.desktop"
APK_MIME="application/vnd.android.package-archive"
SUDO_KEEPALIVE_PID=""
WD_DATA="${WD_DATA:-/var/lib/waydroid}"
STATE_DIR="$HOME/.local/state/waydroid-installer"
STATE_FILE="$STATE_DIR/install.state"    # "incomplete" after a failed/partial install
DONE_FILE="$STATE_DIR/done.keys"         # install steps already completed OK
SESSION_LOG="$LOG_DIR/waydroid-session_$(date +%Y%m%d_%H%M%S).log"
RESUME=0
mkdir -p "$STATE_DIR"

# "store": every file downloaded from the internet is kept here and reused on later runs.
# "store": mọi tệp tải từ internet được lưu tại đây và dùng lại ở các lần cài sau.
STORE_DIR="$SCRIPT_DIR/store"
mkdir -p "$STORE_DIR" 2>/dev/null || true
if [ ! -w "$STORE_DIR" ]; then
    STORE_DIR="$HOME/.local/share/waydroid-installer/store"
    mkdir -p "$STORE_DIR"
fi
WS_ARCHIVE="$STORE_DIR/waydroid_script.tar.gz"   # snapshot of waydroid_script
WS_URL="https://github.com/casualsnek/waydroid_script"
SIGNER_JAR_NAME="uber-apk-signer-1.3.0.jar"
SIGNER_URL="https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/$SIGNER_JAR_NAME"

cleanup() {
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    # waydroid_script runs as root, so some temp files are root-owned.
    sudo -n rm -rf "$TMP_DIR" 2>/dev/null || rm -rf "$TMP_DIR"   # remove temp files / dọn tệp tạm
}
trap cleanup EXIT

# ---------------------------------------------------------------- messaging --
# say "English" "Tiếng Việt"  -> bilingual line (English first)
say() { echo "[$(date +%H:%M:%S)] $1 | $2"; }

# Desktop notification. Same id replaces the previous one (no spam) and an
# identical message is never shown twice.
# Thông báo; cùng id thì thay thế, thông báo trùng nội dung không hiện lại.
notify() {
    local msg="$1 | $2"
    [ "$msg" = "$LAST_NOTIFY" ] && return 0
    LAST_NOTIFY="$msg"
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "Waydroid Installer" -i waydroid \
        -h string:x-canonical-private-synchronous:waydroid-installer \
        "Waydroid Installer" "$msg" 2>/dev/null || true
}

step() {
    STEP=$((STEP + 1))
    say "[$STEP/$TOTAL_STEPS] $1" "[$STEP/$TOTAL_STEPS] $2"
    notify "[$STEP/$TOTAL_STEPS] $1" "$2"
}

# Run an external command so its own progress bars show live on the terminal (a pty is used
# even though stdout is piped to the log); only a cleaned copy goes into the log file.
# Chạy lệnh ngoài để thanh tiến trình hiện trực tiếp trên terminal; log chỉ lưu bản đã làm sạch.
run_progress() {
    local out="${PROGRESS_TTY:-/dev/tty}" raw rc
    local -a pre=()
    if command -v script >/dev/null 2>&1 && ( : >> "$out" ) 2>/dev/null; then
        raw="$(mktemp "$TMP_DIR/progress.XXXXXX")"
        # "sudo cmd" becomes "sudo script cmd": sudo keeps using this terminal's cached credentials
        # (a new pty would ask for the password again). / Giữ sudo bên ngoài để không hỏi lại mật khẩu.
        if [ "${1:-}" = sudo ]; then pre=(sudo); shift; fi
        "${pre[@]}" script -qefc "$(printf '%q ' "$@")" "$raw" > "$out"
        rc=$?
        tr '\r' '\n' < "$raw" | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's/^\[Downloading\] [^[]*//' -e 's/[[:space:]]*$//' -e '/^Script \(started\|done\) on /d' |
            awk 'length($0) > 0 && !($0 ~ /[0-9]+%/ && $0 !~ /100%/) && index($0, "━") == 0 && $0 !~ /^[#O= -]+$/ && !seen[$0]++' >> "$LOG_FILE"
        rm -f "$raw"
        return $rc
    fi
    "$@"
}

record_fix() { echo "$(date '+%F %T') | $1 | $2" >> "$FIX_HISTORY"; }

# Count an error, keep a one-line summary, remember it in the fix history.
fail() {
    ERR_COUNT=$((ERR_COUNT + 1))
    ERR_LIST+=("$1 | $2")
    say "ERROR: $1" "LỖI: $2"
    record_fix "ERROR" "$1"
}

# Run a command once per key. A key is remembered only after SUCCESS, also across
# runs of an unfinished install, so completed steps are never repeated.
# Chạy mỗi bước một lần; chỉ ghi nhớ khi THÀNH CÔNG (kể cả giữa các lần chạy lại).
once() {
    local key="$1"; shift
    [ -n "${DONE_ONCE[$key]:-}" ] && return 0
    if grep -qx "$key" "$DONE_FILE" 2>/dev/null; then
        DONE_ONCE[$key]=1
        say "Step already done, skipping: $key" "Bước đã xong, bỏ qua: $key"
        return 0
    fi
    "$@" || return 1
    DONE_ONCE[$key]=1
    echo "$key" >> "$DONE_FILE"
}

# ------------------------------------------------------------------ helpers --
detect_pm() {
    if   command -v pacman  >/dev/null 2>&1; then PM=pacman
    elif command -v apt-get >/dev/null 2>&1; then PM=apt
    elif command -v dnf     >/dev/null 2>&1; then PM=dnf
    else PM=unknown; fi
}

waydroid_installed() { command -v waydroid >/dev/null 2>&1; }

get_root() {
    say "Requesting administrator rights..." "Đang yêu cầu quyền quản trị..."
    sudo -v || return 1
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
}

session_running() { waydroid status 2>/dev/null | grep -Eq 'Session:[[:space:]]+RUNNING'; }

start_session() {
    session_running && return 0
    if ! systemctl is-active --quiet waydroid-container.service; then
        say "Container service is not active" "Dịch vụ container chưa chạy"
        return 1
    fi
    nohup waydroid session start >"$SESSION_LOG" 2>&1 &
    local pid=$! i
    for i in $(seq 1 60); do
        session_running && return 0
        if ! kill -0 "$pid" 2>/dev/null; then       # exited early -> fail fast
            sleep 2; session_running && return 0
            say "Session process exited early (see session log below)" \
                "Tiến trình phiên thoát sớm (xem log phiên bên dưới)"
            return 1
        fi
        sleep 1
    done
    return 1
}

# ------------------------------------------------------------ kernel check --
# XanMod (and other tuned kernels) differ from the stock BigLinux kernel in config/params: detect it up front.
# XanMod (và các kernel tinh chỉnh khác) khác kernel mặc định của BigLinux: nhận biết ngay từ đầu.
KERNEL_FLAVOR=default
NEEDS_REBOOT=0
detect_kernel_flavor() {
    case "$(uname -r) $(cat /proc/version 2>/dev/null)" in
        *[Xx]an[Mm]od*) KERNEL_FLAVOR=xanmod ;;
    esac
}

# Running kernel's build config (empty when the kernel does not expose it).
kernel_cfg() {
    if   [ -r /proc/config.gz ]; then zcat /proc/config.gz 2>/dev/null
    elif [ -r "/boot/config-$(uname -r)" ]; then cat "/boot/config-$(uname -r)"
    elif [ -r "/usr/lib/modules/$(uname -r)/build/.config" ]; then cat "/usr/lib/modules/$(uname -r)/build/.config"
    fi
}

# One "CONFIG_X=value" line per option Waydroid/Android cares about (absent / not set shown explicitly).
kernel_compat_report() {
    local cfg opt v
    cfg="$(kernel_cfg)"
    if [ -z "$cfg" ]; then echo "kernel config: not available (no /proc/config.gz)"; return 0; fi
    for opt in ANDROID_BINDER_IPC ANDROID_BINDERFS ANDROID_BINDER_DEVICES PSI PSI_DEFAULT_DISABLED MEMCG CGROUPS \
               CGROUP_DEVICE CGROUP_PIDS CGROUP_FREEZER CPUSETS USER_NS PID_NS NET_NS IPC_NS UTS_NS OVERLAY_FS \
               SQUASHFS EROFS_FS DMABUF_HEAPS DMABUF_HEAPS_SYSTEM BRIDGE NF_NAT NETFILTER_XT_TARGET_MASQUERADE \
               SECURITY_SELINUX SECURITY_APPARMOR LSM; do
        v="$(printf '%s\n' "$cfg" | sed -n "s/^CONFIG_${opt}=//p;s/^# CONFIG_${opt} is not set/not set/p" | head -n1)"
        echo "CONFIG_$opt=${v:-absent}"
    done
}

# XanMod branch: report what the kernel lacks for Waydroid before anything is installed. Information only:
# the install itself then runs exactly as on the stock kernel.
# Nhánh XanMod: báo kernel còn thiếu gì cho Waydroid trước khi cài. Chỉ báo thông tin, việc cài vẫn như bình thường.
xanmod_preflight() {
    local cfg opt miss=""
    say "XanMod kernel detected ($(uname -r)): running Waydroid compatibility checks" \
        "Phát hiện kernel XanMod ($(uname -r)): kiểm tra tương thích với Waydroid"
    cfg="$(kernel_cfg)"
    if [ -n "$cfg" ]; then
        for opt in ANDROID_BINDER_IPC ANDROID_BINDERFS MEMCG CGROUPS USER_NS PID_NS NET_NS IPC_NS UTS_NS OVERLAY_FS \
                   DMABUF_HEAPS_SYSTEM BRIDGE NF_NAT; do
            grep -qE "^CONFIG_${opt}=[ym]$" <<<"$cfg" || miss="$miss $opt"      # here-string: no pipe, no SIGPIPE under pipefail
        done
        if [ -n "$miss" ]; then
            say "WARNING: this kernel is missing options Waydroid needs:$miss" \
                "CẢNH BÁO: kernel này thiếu tùy chọn Waydroid cần:$miss"
        else
            say "Kernel config has every option Waydroid needs" "Cấu hình kernel có đủ tùy chọn Waydroid cần"
        fi
    fi
    echo "--- XanMod kernel report:"; kernel_compat_report
    echo "lsm: $(cat /sys/kernel/security/lsm 2>/dev/null)"; echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
    return 0
}

# Shown when Android's init stops early on a XanMod kernel (the stock kernel installs fine with the same images).
# Android's lmkd is a critical process and exits at once when the kernel has no PSI (memory pressure info);
# init then reboots Android in a loop ("critical process 'lmkd' exited 4 times"). Some kernels (XanMod) are built with
# PSI_DEFAULT_DISABLED, so /proc/pressure/memory is missing. It can only be switched on with the boot parameter psi=1.
# lmkd của Android là tiến trình "critical", thoát ngay khi kernel không có PSI nên init khởi động lại Android liên tục.
# Một số kernel (XanMod) tắt PSI mặc định; chỉ bật lại được bằng tham số khởi động psi=1.
GRUB_DEFAULT_FILE=/etc/default/grub
GRUB_BACKUP="$GRUB_DEFAULT_FILE.waydroid-installer.bak"

grub_regen() {
    if   command -v update-grub    >/dev/null 2>&1; then sudo update-grub
    elif command -v grub-mkconfig  >/dev/null 2>&1 && [ -d /boot/grub ]; then sudo grub-mkconfig -o /boot/grub/grub.cfg
    else return 1
    fi
}

# Returns 0 when PSI works now or the fix was applied (reboot needed: sets NEEDS_REBOOT=1); 1 when it cannot be fixed.
ensure_psi() {
    [ -r /proc/pressure/memory ] && return 0
    local cfg; cfg="$(kernel_cfg)"
    if [ -n "$cfg" ] && ! grep -qE '^CONFIG_PSI=y$' <<<"$cfg"; then
        say "This kernel was built without PSI, which Android needs: use another kernel (e.g. linux72)" \
            "Kernel này được biên dịch không có PSI, Android cần nó: hãy dùng kernel khác (ví dụ linux72)"
        return 1
    fi
    if grep -qw 'psi=1' /proc/cmdline 2>/dev/null; then       # already requested but the running kernel still has it off
        say "psi=1 is on the kernel command line but PSI is still off: use another kernel (e.g. linux72)" \
            "psi=1 đã có trong dòng lệnh kernel nhưng PSI vẫn tắt: hãy dùng kernel khác (ví dụ linux72)"
        return 1
    fi
    say "PSI (memory pressure) is OFF on this kernel: Android's lmkd cannot run, so Android would reboot in a loop. Adding psi=1 to the boot parameters." \
        "PSI (áp lực bộ nhớ) đang TẮT trên kernel này: lmkd của Android không chạy được nên Android sẽ khởi động lại liên tục. Thêm psi=1 vào tham số khởi động."
    if ! grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT=[\"']" "$GRUB_DEFAULT_FILE" 2>/dev/null; then
        say "Cannot edit the boot parameters automatically (no GRUB_CMDLINE_LINUX_DEFAULT in $GRUB_DEFAULT_FILE). Add psi=1 to your bootloader's kernel command line, reboot and run this script again." \
            "Không tự sửa được tham số khởi động (không có GRUB_CMDLINE_LINUX_DEFAULT trong $GRUB_DEFAULT_FILE). Hãy thêm psi=1 vào dòng lệnh kernel của bootloader, khởi động lại rồi chạy lại script."
        return 1
    fi
    if ! grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT=.*\bpsi=1\b" "$GRUB_DEFAULT_FILE"; then
        [ -e "$GRUB_BACKUP" ] || sudo cp "$GRUB_DEFAULT_FILE" "$GRUB_BACKUP" || return 1
        sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=[\"'])/\1psi=1 /" "$GRUB_DEFAULT_FILE" || return 1
        mkdir -p "$HELPER_DIR" && : > "$HELPER_DIR/.psi-grub-by-installer"        # reverted on uninstall
    fi
    if ! grub_regen >/dev/null 2>&1; then
        say "GRUB changed but its menu could not be regenerated: run  sudo update-grub  then reboot." \
            "Đã sửa GRUB nhưng chưa tạo lại menu: hãy chạy  sudo update-grub  rồi khởi động lại."
        return 1
    fi
    record_fix "FIXED" "psi=1 added to GRUB_CMDLINE_LINUX_DEFAULT (reboot needed)"
    NEEDS_REBOOT=1
    return 0
}

boot_failed_hint() {
    [ "$KERNEL_FLAVOR" = xanmod ] || return 0
    say "XanMod: Android stopped early. Waydroid is known to work on the stock BigLinux kernel (linux72): restart, pick it in the boot menu (Advanced options) and run this script again - stored files are reused. To get it fixed on XanMod, send this log." \
        "XanMod: Android dừng sớm. Waydroid chạy được trên kernel mặc định của BigLinux (linux72): khởi động lại, chọn nó trong menu khởi động (Advanced options) rồi chạy lại script - tệp đã lưu được dùng lại. Muốn sửa cho XanMod, hãy gửi log này."
}

# Kernel log without the binder "ping" flood (the host pings Android's service manager every second
# and a stopped container used to hide the real Android init messages behind those lines).
# Log kernel không có đống dòng binder "ping" (làm chìm các thông báo init của Android).
dmesg_clean() {
    sudo -n dmesg 2>/dev/null | grep -vE 'binder_linux: [0-9]+:[0-9]+ (cannot find target node|transaction call to 0:0 failed)|binder_debug: [0-9]+ callbacks suppressed'
}

# Dump everything useful for debugging into the log.
# Ghi toàn bộ thông tin hữu ích cho việc gỡ lỗi vào log.
collect_diag() {
    say "---- Diagnostics ----" "---- Chẩn đoán ----"
    echo "env: XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} DISPLAY=${DISPLAY:-} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-} DESKTOP=${XDG_CURRENT_DESKTOP:-}"
    echo "kernel: $(uname -r)"
    echo "--- binder:"; grep -i binder /proc/filesystems 2>&1; ls -l /dev/*binder* 2>&1 | head -n 5
    echo "--- $WD_DATA:"; sudo -n ls -l "$WD_DATA" "$WD_DATA/images" 2>&1 | head -n 30
    echo "--- waydroid status:"
    if command -v waydroid >/dev/null 2>&1; then waydroid status 2>&1 | head -n 20; else echo "waydroid command not found (package not installed)"; fi
    echo "--- container service:"; systemctl status waydroid-container.service --no-pager -l 2>&1 | tail -n 20
    echo "--- journal:"; sudo -n journalctl -u waydroid-container.service -n 40 --no-pager 2>&1 | tail -n 40
    # The container manager polls "lxc-info ... STOPPED" every 5 s and floods the file: drop those lines.
    echo "--- waydroid.log (without status polling):"
    sudo -n grep -vE 'lxc-info|\] (STOPPED|RUNNING|FROZEN)$' "$WD_DATA/waydroid.log" 2>&1 | tail -n 70
    echo "--- lxc logs:"
    local lf
    while IFS= read -r lf; do echo "# $lf"; sudo -n tail -n 30 "$lf" 2>&1; done < <(sudo -n find "$WD_DATA/lxc" -maxdepth 3 -name '*.log' 2>/dev/null)
    echo "--- kernel messages (binder ping flood removed):"
    dmesg_clean | grep -iE 'binder|lxc|loop[0-9]|squashfs|erofs|ext4|waydroid|init:|avc:|lmkd|selinux|apparmor|audit|cgroup|psi|reboot|critical|servicemanager|oom|segfault|Oops|BUG:|WARNING:' | tail -n 120
    echo "--- last kernel lines (flood removed):"
    dmesg_clean | tail -n 40
    echo "--- kernel/LSM/PSI/cgroup facts:"
    echo "flavor: $KERNEL_FLAVOR | cmdline: $(cat /proc/cmdline 2>/dev/null)"
    echo "lsm: $(cat /sys/kernel/security/lsm 2>/dev/null) | selinux enforce: $(cat /sys/fs/selinux/enforce 2>/dev/null || echo n/a)"
    echo "psi: $(head -n1 /proc/pressure/memory 2>&1)"
    echo "cgroup controllers: $(cat /sys/fs/cgroup/cgroup.controllers 2>&1)"
    mount 2>/dev/null | grep -E 'binderfs|cgroup' | head -n 5
    kernel_compat_report
    echo "--- session log:"; tail -n 30 "$SESSION_LOG" 2>&1
    echo "--- launcher log ($HOME/.local/state/waydroid-installer/launcher.log):"
    tail -n 80 "$HOME/.local/state/waydroid-installer/launcher.log" 2>&1
    echo "--- image files:"; sudo -n ls -l --time-style=long-iso "$WD_DATA/images" /etc/waydroid-extra/images 2>&1 | head -n 12
    echo "--- waydroid-container journal:"; sudo -n journalctl -u waydroid-container -b --no-pager 2>&1 | tail -n 25
    echo "--- waydroid.log (last 40, status polling removed):"
    sudo -n grep -vE 'status|^\s*$' "$WD_DATA/waydroid.log" 2>&1 | tail -n 40
    echo "--- cage / compositor:"; command -v cage 2>&1; pgrep -af 'cage|waydroid' 2>&1 | cut -c1-200 | head -n 8
    say "---- End diagnostics ----" "---- Hết chẩn đoán ----"
}

# Scripts started through sudo/terminal wrappers often lose the graphical session
# variables; Waydroid's session needs WAYLAND_DISPLAY. Recover them when possible.
# Biến môi trường phiên đồ họa hay bị mất khi chạy qua sudo; khôi phục nếu được.
ensure_session_env() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        local sock
        sock="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)"
        [ -n "$sock" ] && export WAYLAND_DISPLAY="$sock"
    fi
    if [ -z "${XDG_SESSION_TYPE:-}" ]; then
        if   [ -n "${WAYLAND_DISPLAY:-}" ]; then export XDG_SESSION_TYPE=wayland
        elif [ -n "${DISPLAY:-}" ];         then export XDG_SESSION_TYPE=x11
        fi
    fi
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
}

# Wait until Android reports boot_completed. Returns 1 on timeout, 2 when the container itself
# stays STOPPED (it crashed or never started: waiting longer is pointless).
# Chờ Android khởi động xong. Trả về 2 nếu chính container vẫn ở trạng thái STOPPED (không cần chờ thêm).
wait_android_boot() {
    local i stopped_n=0 step="${WAYDROID_WAIT_STEP:-2}"
    for i in $(seq 1 120); do
        [ "$(sudo waydroid shell -- getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ')" = "1" ] && return 0
        if waydroid status 2>/dev/null | grep -Eq 'Container:[[:space:]]+STOPPED'; then
            stopped_n=$((stopped_n + 1))
            [ "$stopped_n" -ge 25 ] && return 2         # ~50 s without a running container
        else
            stopped_n=0
        fi
        sleep "$step"
    done
    return 1
}

# The stored images did not boot (corrupted or incompatible): drop the copy, download fresh GAPPS
# images and try once more. Only when this run used images from the store.
# Ảnh trong kho không khởi động được (hỏng/không tương thích): bỏ bản chép, tải ảnh mới và thử lại một lần.
retry_with_fresh_images() {
    [ -f "$HELPER_DIR/.extra-images-by-installer" ] || return 1
    local k; k="$(sudo -n dmesg 2>/dev/null | tail -n 500)"
    if ! echo "$k" | grep -qiE 'EXT4-fs.*(error|corrupt)|SQUASHFS error|EROFS.*(error|corrupt)|Buffer I/O error|I/O error, dev loop'; then
        say "No sign of damaged images in the kernel log, so nothing is re-downloaded: Android's init stopped early (kernel/Android compatibility?). See the diagnostics. To force a fresh image, delete the store/images folder and run the script again." \
            "Kernel không báo ảnh bị hỏng nên không tải lại: init của Android dừng sớm (kernel/Android không tương thích?). Xem phần chẩn đoán. Muốn ép tải ảnh mới, hãy xóa thư mục store/images rồi chạy lại script."
        return 1
    fi
    say "Android did not boot with the stored images: switching to a fresh download..." \
        "Android không khởi động với ảnh trong kho: chuyển sang tải ảnh mới..."
    record_fix "RETRY" "stored images did not boot; downloading fresh images"
    collect_diag                                   # keep the evidence of the first failure in the log
    timeout 25 waydroid session stop >/dev/null 2>&1
    sudo systemctl stop waydroid-container.service
    sudo rm -f /etc/waydroid-extra/images/system.img /etc/waydroid-extra/images/vendor.img
    sudo rmdir /etc/waydroid-extra/images /etc/waydroid-extra 2>/dev/null
    rm -f "$HELPER_DIR/.extra-images-by-installer"
    # ignore the stored images from now on; the fresh download replaces them in the store
    [ -f "$STORE_DIR/images/type.txt" ] && mv -f "$STORE_DIR/images/type.txt" "$STORE_DIR/images/type.txt.bad"
    init_waydroid || return 1
    sudo systemctl restart waydroid-container.service
    start_session && wait_android_boot
}

# ------------------------------------------------------------- install part --
install_packages() {
    detect_pm
    mkdir -p "$HELPER_DIR"
    command -v cage >/dev/null 2>&1 || : > "$HELPER_DIR/.cage-by-installer"
    local want=waydroid
    local -a lp=()
    case "$PM" in
        apt)    lp=("$STORE_DIR"/packages/*.deb) ;;
        dnf)    lp=("$STORE_DIR"/packages/*.rpm) ;;
        pacman) lp=("$STORE_DIR"/packages/*.pkg.tar.*) ;;
    esac
    if [ -e "${lp[0]:-}" ]; then          # packages kept in the store are used before the online repos
        say "Installing Waydroid packages found in the store" "Cài gói Waydroid có sẵn trong kho lưu trữ"
        case "$PM" in
            apt)    sudo apt-get install -y "${lp[@]}" ;;
            dnf)    sudo dnf install -y "${lp[@]}" ;;
            pacman) sudo pacman -U --needed --noconfirm "${lp[@]}" ;;
        esac || say "WARNING: stored packages failed, using the online repositories" \
                    "CẢNH BÁO: gói trong kho lỗi, chuyển sang kho trực tuyến"
    fi
    command -v waydroid >/dev/null 2>&1 && want=""
    case "$PM" in
        pacman)  # BigLinux / Manjaro / Arch
            local -a pk=(waydroid cage python python-pip git curl lzip unzip)
            # Distro-maintained GApps image (no OTA link that can break), where the repo has it.
            if pacman -Si waydroid-image-gapps >/dev/null 2>&1; then
                pacman -Q waydroid-image-gapps >/dev/null 2>&1 || : > "$HELPER_DIR/.gapps-image-by-installer"
                pk+=(waydroid-image-gapps)
            fi
            run_progress sudo pacman -S --needed --noconfirm "${pk[@]}" ;;
        apt)     # Debian / Ubuntu / Mint / Deepin / Zorin
            if [ -n "$want" ] && ! apt-cache show waydroid >/dev/null 2>&1; then
                say "Adding official Waydroid repository" "Thêm kho Waydroid chính thức"
                : > "$HELPER_DIR/.waydroid-repo-by-installer"      # removed again on uninstall
                curl -fsSL https://repo.waydro.id | sudo bash || return 1
            fi
            run_progress sudo apt-get update -y &&
            run_progress sudo apt-get install -y $want cage python3 python3-venv python3-pip git curl lzip unzip ;;
        dnf)     # Fedora
            run_progress sudo dnf install -y waydroid cage python3 python3-pip git curl lzip unzip ;;
        *)
            say "Unsupported package manager (SteamOS read-only root or other)." \
                "Trình quản lý gói không được hỗ trợ (SteamOS khóa hệ thống hoặc khác)."
            return 1 ;;
    esac || return 1
    # The step counts as done only when the waydroid command really exists now.
    # Bước chỉ được tính là xong khi lệnh waydroid thật sự tồn tại.
    hash -r
    waydroid_installed || {
        say "The package manager finished but the waydroid command is still missing" \
            "Trình quản lý gói đã chạy xong nhưng vẫn không có lệnh waydroid"
        return 1
    }
}

# Step marks saved by an earlier run can be wrong today (package removed by hand, /var/lib/waydroid
# deleted...). Drop every mark that is no longer true, so the step runs again instead of being skipped.
# Dấu bước xong của lần chạy trước có thể đã sai (gói bị gỡ tay, /var/lib/waydroid bị xóa...): bỏ dấu sai.
validate_done_marks() {
    [ -s "$DONE_FILE" ] || return 0
    hash -r
    if ! waydroid_installed; then
        say "Saved step marks are stale (the waydroid package is missing): all steps will run again" \
            "Dấu bước đã lưu đã cũ (thiếu gói waydroid): chạy lại tất cả các bước"
        record_fix "FIXED" "stale step marks cleared (waydroid package missing)"
        : > "$DONE_FILE"; DONE_ONCE=()
        return 0
    fi
    if ! sudo test -f "$WD_DATA/waydroid.cfg"; then   # no init done: Android-level steps cannot be valid
        if grep -qxE 'ws|props|pp' "$DONE_FILE" 2>/dev/null; then
            say "Saved Android-level step marks are stale (no Waydroid data): those steps will run again" \
                "Dấu bước mức Android đã cũ (không có dữ liệu Waydroid): chạy lại các bước đó"
            record_fix "FIXED" "stale Android-level step marks cleared (no $WD_DATA/waydroid.cfg)"
            sed -i -E '/^(ws|props|pp)$/d' "$DONE_FILE"
        fi
    fi
    return 0
}

check_kernel_binder() {
    grep -q binder /proc/filesystems 2>/dev/null && return 0
    sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null && return 0
    sudo modprobe binder_linux 2>/dev/null && return 0
    [ -e /dev/binderfs ] || [ -e /dev/binder ] && return 0
    return 1
}

# Images may live in $WD_DATA/images OR in a pre-installed image package
# (e.g. Manjaro/BigLinux "waydroid-image-gapps" -> /usr/share/waydroid-extra/images).
# Ảnh có thể nằm trong $WD_DATA/images HOẶC trong gói ảnh cài sẵn (waydroid-image-gapps).
waydroid_images_dir() {
    local d
    for d in "$WD_DATA/images" /etc/waydroid-extra/images /usr/share/waydroid-extra/images; do
        if sudo test -f "$d/system.img" && sudo test -f "$d/vendor.img"; then echo "$d"; return 0; fi
    done
    return 1
}

# Verify stored files against MANIFEST.sha256 (if present); corrupted/modified ones are set aside.
# Kiểm tra tệp trong kho theo MANIFEST.sha256; tệp hỏng/bị sửa sẽ bị bỏ qua.
store_verify() {
    [ -f "$STORE_DIR/MANIFEST.sha256" ] || return 0
    local mode="${WAYDROID_VERIFY:-quick}" line h f sz want
    local -A SZ=()
    if [ -f "$STORE_DIR/MANIFEST.size" ]; then
        while read -r sz f; do SZ["$f"]="$sz"; done < "$STORE_DIR/MANIFEST.size"
    fi
    say "Verifying stored files ($mode; full check: WAYDROID_VERIFY=full)..." \
        "Đang kiểm tra tệp trong kho ($mode; kiểm tra đầy đủ: WAYDROID_VERIFY=full)..."
    while IFS= read -r line; do
        h="${line%% *}"; f="${line#*  }"
        [ -f "$STORE_DIR/$f" ] || continue
        sz="$(stat -c %s "$STORE_DIR/$f")"
        if [ "$mode" != full ] && [ "$sz" -gt 67108864 ]; then      # big file: compare the size only (no heavy disk/CPU use)
            want="${SZ[$f]:-}"
            { [ -z "$want" ] || [ "$want" = "$sz" ]; } && continue
        else
            [ "$(nice -n 19 sha256sum "$STORE_DIR/$f" | cut -d' ' -f1)" = "$h" ] && continue
        fi
        say "Stored file is corrupted/modified, ignoring it: $f" "Tệp trong kho bị hỏng/bị sửa, bỏ qua: $f"
        mv -f "$STORE_DIR/$f" "$STORE_DIR/$f.bad"
    done < "$STORE_DIR/MANIFEST.sha256"
}

# Regenerate the checksum list so the store can be shared as-is.
# Tạo lại danh sách mã băm để có thể chia sẻ nguyên thư mục kho.
store_manifest() {
    local f sz h line
    local -A OH=() OS=()
    if [ -f "$STORE_DIR/MANIFEST.sha256" ] && [ -f "$STORE_DIR/MANIFEST.size" ]; then
        while IFS= read -r line; do OH["${line#*  }"]="${line%% *}"; done < "$STORE_DIR/MANIFEST.sha256"
        while read -r sz f; do OS["$f"]="$sz"; done < "$STORE_DIR/MANIFEST.size"
    fi
    : > "$STORE_DIR/MANIFEST.sha256.tmp"; : > "$STORE_DIR/MANIFEST.size.tmp"
    while IFS= read -r -d '' f; do
        sz="$(stat -c %s "$STORE_DIR/$f")"
        if [ -n "${OH[$f]:-}" ] && [ "${OS[$f]:-}" = "$sz" ]; then
            h="${OH[$f]}"                                           # unchanged file: keep the known hash
        else
            h="$(cd "$STORE_DIR" && nice -n 19 sha256sum "$f" | cut -d' ' -f1)"
        fi
        echo "$h  $f" >> "$STORE_DIR/MANIFEST.sha256.tmp"; echo "$sz $f" >> "$STORE_DIR/MANIFEST.size.tmp"
    done < <(cd "$STORE_DIR" && find images downloads packages waydroid_script.tar.gz -type f ! -name '*.bad' -print0 2>/dev/null | sort -z)
    mv -f "$STORE_DIR/MANIFEST.sha256.tmp" "$STORE_DIR/MANIFEST.sha256"
    mv -f "$STORE_DIR/MANIFEST.size.tmp" "$STORE_DIR/MANIFEST.size"
}

store_readme() {
    [ -f "$STORE_DIR/README.txt" ] && return 0
    cat > "$STORE_DIR/README.txt" <<'README'
WAYDROID STORE / KHO LƯU TRỮ WAYDROID
=====================================
EN: Put the files below in this folder, then run waydroid-installer.sh. Files found here are used
    instead of downloading (links break, files get outdated or discontinued).
VI: Bỏ các tệp dưới đây vào thư mục này rồi chạy waydroid-installer.sh. Tệp có sẵn sẽ được dùng thay
    vì tải (link hỏng, tệp lỗi thời hoặc ngừng phát hành).

  images/system.img, images/vendor.img   Waydroid system/vendor images / ảnh hệ thống Waydroid
  waydroid_script.tar.gz                 snapshot of github.com/casualsnek/waydroid_script
  downloads/*                            GApps / ARM-translation archives used by waydroid_script
                                         (tệp GApps / lớp dịch ARM do waydroid_script tải)
  packages/*.deb|*.rpm|*.pkg.tar.*       optional Waydroid packages for your distro, installed
                                         before the online repositories (tùy chọn)
  MANIFEST.sha256                        checksums (auto-generated); files that do not match are ignored
                                         (mã băm tự tạo; tệp không khớp sẽ bị bỏ qua)

NOT stored / KHÔNG lưu: distro packages from repositories, Python (PyPI) packages, Java.
README
}

# Keep a copy of freshly downloaded Waydroid images (only if there is enough free space).
cache_images_to_store() {   # $1 = image type (GAPPS / VANILLA), saved as images/type.txt
    local src="$WD_DATA/images" dst="$STORE_DIR/images" need avail
    sudo test -f "$src/system.img" && sudo test -f "$src/vendor.img" || return 0
    [ -f "$dst/system.img" ] && [ -f "$dst/vendor.img" ] && [ "$(cat "$dst/type.txt" 2>/dev/null)" = "$1" ] && return 0
    need="$(sudo du -cb "$src/system.img" "$src/vendor.img" | tail -n1 | cut -f1)"
    avail="$(df -B1 --output=avail "$STORE_DIR" | tail -n1 | tr -d ' ')"
    if [ "${avail:-0}" -lt $(( need + 500*1024*1024 )) ]; then
        say "Not enough free space to keep the images in the store; skipped" \
            "Không đủ dung lượng để lưu ảnh vào kho; bỏ qua"
        return 0
    fi
    say "Saving Waydroid images ($1) to the store for faster reinstall..." "Đang lưu ảnh Waydroid ($1) vào kho để cài lại nhanh hơn..."
    mkdir -p "$dst" && sudo nice -n 19 cp -f "$src/system.img" "$src/vendor.img" "$dst/" || return 1
    sudo chown -R "$(id -u):$(id -g)" "$dst" 2>/dev/null || true    # not permitted on NTFS/exFAT mounts: harmless
    echo "$1" > "$dst/type.txt"                                      # always record the image type
}

# The Google Play (GAPPS) image is requested directly; the vanilla image + GApps added by
# waydroid_script is only a fallback if the GAPPS channel is unreachable.
# Tải thẳng ảnh có Google Play (GAPPS); chỉ khi lỗi mới dùng ảnh vanilla rồi thêm GApps sau.
# Copy the stored images to /etc/waydroid-extra/images (Waydroid's folder for pre-installed images).
use_store_images() {
    local extra=/etc/waydroid-extra/images need avail
    if sudo test -f "$extra/system.img" && sudo test -f "$extra/vendor.img"; then return 0; fi   # already there
    need="$(du -cb "$STORE_DIR/images/system.img" "$STORE_DIR/images/vendor.img" | tail -n1 | cut -f1)"
    avail="$(df -B1 --output=avail /etc | tail -n1 | tr -d ' ')"
    if [ "${avail:-0}" -lt $(( need + 1024*1024*1024 )) ]; then
        say "Not enough free space in /etc for the stored images" "Không đủ dung lượng trống trong /etc cho ảnh trong kho"
        return 1
    fi
    say "Copying the stored images (about 3 GB)..." "Đang chép ảnh trong kho (khoảng 3 GB)..."
    sudo mkdir -p "$extra" && sudo nice -n 19 cp -f "$STORE_DIR/images/system.img" "$STORE_DIR/images/vendor.img" "$extra/" || return 1
    mkdir -p "$HELPER_DIR" && : > "$HELPER_DIR/.extra-images-by-installer"     # removed again on uninstall
}

init_waydroid() {
    local where rc=1 img_type=GAPPS cfgdir pkg=/usr/share/waydroid-extra/images
    hash -r
    if ! waydroid_installed; then            # nothing to init: a retry/vanilla fallback would only repeat exit code 127
        say "The waydroid command is missing: the package is not installed" \
            "Thiếu lệnh waydroid: gói chưa được cài"
        return 2
    fi
    # Waydroid mounts the folder named in waydroid.cfg (images_path): that exact folder must have the images.
    cfgdir="$(sudo sed -n 's/^images_path[[:space:]]*=[[:space:]]*//p' "$WD_DATA/waydroid.cfg" 2>/dev/null | head -n1)"
    if [ -n "$cfgdir" ] && sudo test -f "$cfgdir/system.img" && sudo test -f "$cfgdir/vendor.img"; then
        say "Existing Waydroid image found in $cfgdir, reusing it" "Đã có ảnh Waydroid trong $cfgdir, dùng lại"
        return 0
    fi
    # Image package of the distribution (matched to its kernels): preferred over stored/downloaded images.
    if sudo test -f "$pkg/system.img" && sudo test -f "$pkg/vendor.img"; then
        say "Using the image package of the distribution" "Dùng ảnh từ gói của bản phân phối"
        run_progress sudo waydroid init -s GAPPS -f; rc=$?
        say "waydroid init exit code: $rc" "Mã thoát của waydroid init: $rc"
        [ "$rc" -eq 0 ] && return 0
    fi
    if [ -f "$STORE_DIR/images/system.img" ] && [ -f "$STORE_DIR/images/vendor.img" ]; then
        if [ "$(cat "$STORE_DIR/images/type.txt" 2>/dev/null)" = "GAPPS" ]; then
            say "Using Waydroid GAPPS images from the store (no download)" "Dùng ảnh Waydroid GAPPS trong kho lưu trữ (không cần tải)"
            # Images in /etc/waydroid-extra/images count as pre-installed for Waydroid: no download.
            # (--images_path pointing at the default folder made it download them again.)
            if use_store_images; then
                run_progress sudo waydroid init -s GAPPS -f; rc=$?
            fi
            [ "$rc" -eq 0 ] || say "Stored images could not be used, downloading instead" "Không dùng được ảnh trong kho, chuyển sang tải mới"
        else
            say "Images in the store are not the GAPPS type, ignoring them" "Ảnh trong kho không phải loại GAPPS, bỏ qua"
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        say "Running waydroid init with the GAPPS image (may download, several minutes)..." \
            "Đang chạy waydroid init với ảnh GAPPS (có thể tải, mất vài phút)..."
        run_progress sudo waydroid init -s GAPPS -f; rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ]; then
            img_type=VANILLA
            say "GAPPS image unavailable; using the vanilla image (GApps are added afterwards)" \
                "Không có ảnh GAPPS; dùng ảnh vanilla (sẽ thêm GApps sau)"
            run_progress sudo waydroid init -f; rc=$?
        fi
    fi
    say "waydroid init exit code: $rc" "Mã thoát của waydroid init: $rc"
    [ "$rc" -eq 0 ] || return 1
    if where="$(waydroid_images_dir)"; then
        say "Using images ($img_type) in: $where" "Dùng ảnh ($img_type) trong: $where"
        [ "$where" = "$WD_DATA/images" ] && cache_images_to_store "$img_type"
        return 0
    fi
    say "No system.img/vendor.img found after init" "Không thấy system.img/vendor.img sau khi init"
    return 1
}

# Services listening on port 53 on ALL interfaces (or on the Waydroid bridge address). They block
# Waydroid's own dnsmasq ("Address already in use") and the container cannot start.
# Dịch vụ đang nghe cổng 53 trên mọi giao diện: chúng chặn dnsmasq của Waydroid nên container không khởi động được.
port53_holders() {
    sudo ss -H -lntup 'sport = :53' 2>/dev/null | awk '
        { a = $5; sub(/:53$/, "", a)
          if (a == "0.0.0.0" || a == "*" || a == "[::]" || a == "192.168.240.1") {
              p = "?"; if (match($0, /\(\("[^"]+"/)) p = substr($0, RSTART + 3, RLENGTH - 4)
              print p } }' | sort -u | paste -sd, -
}

# Full picture of who listens on port 53 (address, pid, command line, systemd unit) - goes into the log.
# Toàn cảnh ai đang nghe cổng 53 (địa chỉ, pid, dòng lệnh, unit systemd) - ghi vào log.
port53_details() {
    local pid
    echo "--- port 53 listeners:"
    sudo -n ss -lntup 'sport = :53' 2>&1 | head -n 15
    for pid in $(sudo -n ss -H -lntup 'sport = :53' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
        echo "# pid $pid: $(ps -o user=,args= -p "$pid" 2>/dev/null | cut -c1-300)"
        echo "#   unit: $(ps -o unit= -p "$pid" 2>/dev/null)"
    done
}

# The system dnsmasq.service listens on 0.0.0.0:53 and blocks Waydroid's own dnsmasq (bridge waydroid0).
# Fix with a reversible systemd drop-in: same command line + "--bind-dynamic --except-interface=waydroid0".
# dnsmasq.service hệ thống nghe 0.0.0.0:53 nên chặn dnsmasq của Waydroid. Sửa bằng drop-in systemd có thể hoàn tác:
# giữ nguyên dòng lệnh cũ + "--bind-dynamic --except-interface=waydroid0".
DNSMASQ_DROPIN_DIR=/etc/systemd/system/dnsmasq.service.d
DNSMASQ_DROPIN="$DNSMASQ_DROPIN_DIR/waydroid.conf"
fix_port53_dnsmasq() {
    local pid unit args
    pid="$(sudo -n ss -H -lntup 'sport = :53' 2>/dev/null | awk '$5 ~ /^(0\.0\.0\.0|\*|\[::\]):53$/ && /"dnsmasq"/' | grep -o 'pid=[0-9]*' | head -n1 | cut -d= -f2)"
    [ -n "$pid" ] || return 1
    unit="$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ "$unit" = dnsmasq.service ] || return 1                 # only the stock systemd service is touched
    args="$(ps -o args= -p "$pid" 2>/dev/null)"
    case "$args" in /usr/bin/dnsmasq\ -k*) ;; *) return 1 ;; esac
    say "System dnsmasq.service blocks port 53: making it skip the Waydroid bridge (drop-in $DNSMASQ_DROPIN)" \
        "dnsmasq.service của hệ thống chiếm cổng 53: cho nó bỏ qua cầu nối Waydroid (drop-in $DNSMASQ_DROPIN)"
    sudo mkdir -p "$DNSMASQ_DROPIN_DIR" &&
        printf '[Service]\nExecStart=\nExecStart=%s --bind-dynamic --except-interface=waydroid0\n' "$args" |
        sudo tee "$DNSMASQ_DROPIN" >/dev/null || return 1
    mkdir -p "$HELPER_DIR" && : > "$HELPER_DIR/.dnsmasq-dropin-by-installer"   # removed again on uninstall
    if sudo systemctl daemon-reload && sudo systemctl restart dnsmasq.service && sleep 1 && [ -z "$(port53_holders)" ]; then
        record_fix "FIXED" "dnsmasq.service now skips waydroid0 (drop-in)"
        return 0
    fi
    say "The dnsmasq change did not work: undoing it" "Thay đổi dnsmasq không hiệu quả: hoàn tác"
    sudo rm -f "$DNSMASQ_DROPIN"; sudo rmdir "$DNSMASQ_DROPIN_DIR" 2>/dev/null
    sudo systemctl daemon-reload; sudo systemctl restart dnsmasq.service
    rm -f "$HELPER_DIR/.dnsmasq-dropin-by-installer"
    return 1
}

precheck_port53() {
    local h pat='^(/usr/bin/)?dnsmasq .*(waydroid|192\.168\.240\.1)'
    h="$(port53_holders)"; [ -z "$h" ] && return 0
    if sudo pgrep -f "$pat" >/dev/null 2>&1; then          # a leftover Waydroid dnsmasq: stop it
        say "Stopping a leftover Waydroid dnsmasq" "Dừng dnsmasq của Waydroid còn sót lại"
        sudo pkill -f "$pat"; sleep 1
        h="$(port53_holders)"; [ -z "$h" ] && return 0
    fi
    port53_details
    fix_port53_dnsmasq && return 0
    say "WARNING: port 53 is used by: $h. Waydroid's network (dnsmasq) needs it on its own bridge, so the container may not start. Fix: make that service skip the interface waydroid0 (dnsmasq: 'except-interface=waydroid0' and 'bind-dynamic') or stop it while using Waydroid." \
        "CẢNH BÁO: cổng 53 đang bị chiếm bởi: $h. Mạng của Waydroid (dnsmasq) cần cổng này trên cầu nối riêng nên container có thể không khởi động. Cách sửa: cho dịch vụ đó bỏ qua giao diện waydroid0 (dnsmasq: 'except-interface=waydroid0' và 'bind-dynamic') hoặc tạm dừng nó khi dùng Waydroid."
    return 1
}

# Turn the container's start failure into a clear cause. Returns 0 if a known cause was found.
explain_start_failure() {
    local j h
    j="$(sudo -n journalctl -u waydroid-container.service -n 80 --no-pager 2>&1)"
    if echo "$j" | grep -qi 'address already in use'; then
        h="$(port53_holders)"
        port53_details
        fail "Waydroid network could not start: port 53 is used by ${h:-another service}" \
             "Mạng Waydroid không khởi động được: cổng 53 đang bị ${h:-dịch vụ khác} chiếm"
        return 0
    fi
    return 1
}

# Starting Android (GPU + RAM) next to a running game can freeze or blank the game on modest PCs:
# wait (up to 10 minutes) until the GPU is idle and enough RAM is free, then go on anyway.
# Khởi động Android cạnh một game đang chạy có thể làm game đứng/đen màn hình trên máy cấu hình vừa:
# chờ (tối đa 10 phút) đến khi GPU rảnh và đủ RAM trống rồi mới tiếp tục.
wait_for_quiet() {
    local i f b busy mem warned=0
    for i in $(seq 1 120); do
        busy=0
        for f in ${WAYDROID_GPU_GLOB:-/sys/class/drm/card*/device/gpu_busy_percent}; do
            [ -r "$f" ] || continue
            b="$(cat "$f" 2>/dev/null)"; [ "${b:-0}" -gt "$busy" ] && busy="$b"
        done
        mem="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
        if [ "$busy" -lt 25 ] && [ "${mem:-9999}" -ge 2500 ]; then return 0; fi
        if [ "$warned" -eq 0 ]; then
            warned=1
            say "A game or heavy application seems to be running (GPU ${busy}%, free RAM ${mem} MB): waiting before starting Android..." \
                "Có vẻ đang chạy game hoặc ứng dụng nặng (GPU ${busy}%, RAM trống ${mem} MB): chờ trước khi khởi động Android..."
            notify "Close your game: Waydroid waits until the GPU and RAM are free" "Hãy đóng game: Waydroid chờ cho tới khi GPU và RAM rảnh"
        fi
        sleep "${WAYDROID_QUIET_STEP:-5}"
    done
    say "Still busy after 10 minutes: continuing anyway" "Vẫn bận sau 10 phút: tiếp tục"
    return 0
}

enable_container() {
    sudo systemctl enable --now waydroid-container.service
}

pick_translation_layer() {
    case "$(uname -m)" in
        x86_64|amd64)
            if grep -qi AuthenticAMD /proc/cpuinfo; then echo libndk; else echo libhoudini; fi ;;
        *) echo "" ;;                    # ARM host: no translation needed
    esac
}

has_play_store() {
    sudo waydroid shell -- pm list packages com.android.vending 2>/dev/null | grep -q 'com.android.vending'
}

# waydroid_script is kept in the store as a tar.gz snapshot (the project could vanish).
prepare_ws() {
    if [ -s "$WS_ARCHIVE" ]; then
        say "Using stored waydroid_script snapshot" "Dùng bản waydroid_script đã lưu"; return 0
    fi
    say "Downloading waydroid_script..." "Đang tải waydroid_script..."
    rm -rf "$TMP_DIR/ws-clone"
    run_progress git clone --progress --depth 1 "$WS_URL" "$TMP_DIR/ws-clone" || return 1
    git -C "$TMP_DIR/ws-clone" rev-parse HEAD > "$STORE_DIR/waydroid_script.commit" 2>/dev/null
    rm -rf "$TMP_DIR/ws-clone/.git"
    tar -czf "$WS_ARCHIVE.part" -C "$TMP_DIR/ws-clone" . && mv -f "$WS_ARCHIVE.part" "$WS_ARCHIVE"
}

prepare_store() {
    mkdir -p "$STORE_DIR/images" "$STORE_DIR/downloads" "$STORE_DIR/packages"
    store_readme
    store_verify
    prepare_ws || say "WARNING: could not prepare waydroid_script (will retry later)" \
                      "CẢNH BÁO: chưa chuẩn bị được waydroid_script (sẽ thử lại sau)"
    say "Store: $STORE_DIR" "Kho lưu trữ: $STORE_DIR"
}

# Safety net: waydroid_script normally writes into store/downloads through the symlinks made
# below; if it used another HOME/cache folder, copy its own "downloads" folder content here.
# Only waydroid_script folders are scanned (never Waydroid's Android data under ~/.local/share/waydroid).
# Dự phòng: chỉ quét thư mục "downloads" của waydroid_script (không quét dữ liệu Android của Waydroid).
collect_ws_downloads() {
    local f n=0
    while IFS= read -r -d '' f; do
        [ -e "$STORE_DIR/downloads/$(basename "$f")" ] && continue       # already stored
        sudo cp -n "$f" "$STORE_DIR/downloads/" 2>/dev/null &&
            { say "Saved to store: $f" "Đã lưu vào kho: $f"; n=$((n+1)); }
    done < <(sudo find /root "$HOME" -xdev -type f -path '*waydroid[-_]script*/downloads/*' -size +50k \
                 -not -path "$STORE_DIR/*" -print0 2>/dev/null)
    say "Store downloads folder now has $(ls -1 "$STORE_DIR/downloads" 2>/dev/null | wc -l) file(s) ($n copied from other places)" \
        "Thư mục downloads trong kho hiện có $(ls -1 "$STORE_DIR/downloads" 2>/dev/null | wc -l) tệp ($n tệp chép từ nơi khác)"
    true
}

run_waydroid_script() {
    local layer items rc; layer="$(pick_translation_layer)"
    if has_play_store; then
        say "Google Play already in the image; adding translation layer only" \
            "Ảnh đã có Google Play; chỉ thêm lớp dịch"
        items="$layer"
    else
        items="gapps $layer"
    fi
    [ -n "${items// /}" ] || return 0
    [ -s "$WS_ARCHIVE" ] || prepare_ws || return 1
    rm -rf "$TMP_DIR/ws"; mkdir -p "$TMP_DIR/ws" && tar -xzf "$WS_ARCHIVE" -C "$TMP_DIR/ws" || return 1
    # Make waydroid_script download straight into store/downloads (and reuse what is there).
    mkdir -p "$STORE_DIR/downloads"
    local d
    for d in waydroid-script waydroid_script; do        # the real folder name is waydroid-script
        mkdir -p "$TMP_DIR/cache/$d"
        ln -sfn "$STORE_DIR/downloads" "$TMP_DIR/cache/$d/downloads"
    done
    rm -rf "$TMP_DIR/ws/downloads"; ln -sfn "$STORE_DIR/downloads" "$TMP_DIR/ws/downloads"
    python3 -m venv "$TMP_DIR/venv" || return 1
    : > "$TMP_DIR/.ws-start"
    run_progress "$TMP_DIR/venv/bin/pip" install --disable-pip-version-check -r "$TMP_DIR/ws/requirements.txt" || return 1
    # shellcheck disable=SC2086
    run_progress sudo env PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=ignore::SyntaxWarning XDG_CACHE_HOME="$TMP_DIR/cache" \
        "$TMP_DIR/venv/bin/python" "$TMP_DIR/ws/main.py" install $items; rc=$?
    collect_ws_downloads "$TMP_DIR/.ws-start"
    sudo chown -R "$(id -u):$(id -g)" "$STORE_DIR/downloads" 2>/dev/null
    return $rc
}

set_properties() {
    # Fake touch for apps/games that insist on a touchscreen; multi-window; cursor workaround.
    # Must run as the CURRENT USER (no sudo) while the session is running: as root Waydroid looks
    # for root's own session and only prints "session is stopped".
    # Phải chạy bằng tài khoản người dùng (không sudo): chạy bằng root sẽ không thấy phiên của người dùng.
    local kv key val out rc=0
    # persist.waydroid.fake_touch (mouse -> touch) takes exact package names: the APK handler adds
    # every app it installs; "--fake-touch <package>" adds others (e.g. installed from Google Play).
    for kv in 'persist.waydroid.multi_windows=true'; do
        key="${kv%%=*}"; val="${kv#*=}"
        if ! out="$(waydroid prop set "$key" "$val" 2>&1)" || echo "$out" | grep -qi 'session is stopped'; then
            say "Property not applied: $key ($out)" "Chưa áp dụng thuộc tính: $key ($out)"; rc=1
        else
            say "Property set: $key=$val" "Đã đặt thuộc tính: $key=$val"
        fi
    done
    return $rc
}

disable_play_protect() {
    sudo waydroid shell -- settings put global package_verifier_enable 0
    sudo waydroid shell -- settings put global verifier_verify_adb_installs 0
    sudo waydroid shell -- settings put global package_verifier_user_consent -1
}

# KDE's compositor (KWin) only repaints damaged parts of the Waydroid window, so games
# look frozen/garbled. Running Waydroid inside a nested compositor (cage) avoids it.
# KWin của KDE chỉ vẽ lại từng phần cửa sổ Waydroid nên game bị đứng hình/vỡ hình;
# chạy Waydroid trong compositor lồng (cage) sẽ hết lỗi.
setup_cage_launcher() {
    mkdir -p "$HELPER_DIR" "$(dirname "$APK_DESKTOP")" || return 1
    cat > "$HELPER_DIR/waydroid-cage.sh" <<'LAUNCH'
#!/usr/bin/env bash
# Opens Waydroid inside a nested compositor (cage). / Mở Waydroid trong compositor lồng (cage).
DIR="$(dirname "$(readlink -f "$0")")"
LOGD="$HOME/.local/state/waydroid-installer"; mkdir -p "$LOGD"
LOG="$LOGD/launcher.log"; LOCK="$LOGD/launcher.lock"
MIN_RUN="${WAYDROID_MIN_RUN:-20}"
CAGE_PAT="^cage -- waydroid show-full-ui"
log()  { echo "[$(date +%T)] $*" >> "$LOG"; }
note() {
    command -v notify-send >/dev/null 2>&1 &&
    notify-send -a "Waydroid" -i waydroid \
        -h string:x-canonical-private-synchronous:waydroid-launch "Waydroid" "$1 | $2" >/dev/null 2>&1
    return 0
}
running() { waydroid status 2>/dev/null | grep -Eq 'Session:[[:space:]]+RUNNING'; }
stopped() { waydroid status 2>/dev/null | grep -Eq 'Session:[[:space:]]+STOPPED'; }

# Restarting the container needs root: passwordless through the rule made at install time,
# otherwise a graphical password prompt (pkexec).
# Khởi động lại container cần root: không cần mật khẩu nếu có quy tắc tạo lúc cài, nếu không thì hỏi mật khẩu.
restart_container() {
    local ctl; ctl="$(cat "$DIR/systemctl.path" 2>/dev/null)"; [ -n "$ctl" ] || ctl="$(command -v systemctl)"
    log "restarting waydroid-container.service"
    sudo -n "$ctl" restart waydroid-container.service >>"$LOG" 2>&1 && return 0
    log "no passwordless rule: asking for authorization (pkexec)"
    pkexec "$ctl" restart waydroid-container.service >>"$LOG" 2>&1
}

# Stop the session COMPLETELY. A session whose window was closed (especially while Android was
# still booting) can stay half-alive and blocks every later start; restarting the container
# (hard mode, or when the session will not stop) clears it.
# Dừng phiên hoàn toàn. Phiên có cửa sổ bị đóng (nhất là khi Android đang khởi động) có thể kẹt nửa chừng
# và chặn mọi lần mở sau; khởi động lại container sẽ xử lý.
clean_session() {   # $1 = 1: always restart the container too
    local hard="${1:-0}" i wait=15
    [ "$hard" = 1 ] && wait=6                    # hard mode restarts the container anyway
    timeout 25 waydroid session stop >/dev/null 2>&1      # never hang on a half-started session
    for i in $(seq 1 "$wait"); do stopped && break; sleep 1; done
    if ! stopped; then
        log "session still running after ${wait} s: killing leftover processes"
        pkill -u "$(id -u)" -f '^(/usr/bin/)?python[0-9.]* .*/waydroid (session|show-full-ui)' 2>/dev/null
        sleep 2
    fi
    if [ "$hard" = 1 ] || ! stopped; then restart_container; sleep 3; fi
    stopped
}

# ---- KWin helpers (KDE only, best effort) / Hàm hỗ trợ KWin (chỉ KDE, cố gắng hết mức) ----
kwin_run_js() {   # $1 = script file, $2 = plugin name
    local q id
    for q in qdbus6 qdbus-qt6 qdbus; do command -v "$q" >/dev/null 2>&1 && break; q=""; done
    [ -n "$q" ] || return 1
    id="$("$q" org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$1" "$2" 2>/dev/null)"
    [ -n "$id" ] || return 1
    "$q" org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 1
    "$q" org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$2" >/dev/null 2>&1
    return 0
}

# Un-minimize and focus the (nested cage) Waydroid window.
raise_window() {   # $1 = pid of the cage process
    local js="$LOGD/raise.js" pid="$1"
    [ -n "$pid" ] || return 1
    cat > "$js" <<JS
(function () {
    var list = workspace.windowList ? workspace.windowList() : workspace.clientList();
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        if (Number(w.pid) === $pid) {
            w.minimized = false;
            if (workspace.activeWindow !== undefined) { workspace.activeWindow = w; } else { workspace.activeClient = w; }
            return;
        }
    }
})();
JS
    kwin_run_js "$js" waydroid-raise
}

# While Android is still booting, hide the window's title bar and its taskbar entry so it cannot be closed by accident
# (closing mid-boot is what leaves the container stuck); show it again when Android is ready.
# Trong lúc Android khởi động, ẩn thanh tiêu đề để không đóng nhầm cửa sổ; hiện lại khi Android sẵn sàng.
guard_window() {   # $1 = on | off, $2 = pid of the cage process
    local js="$LOGD/guard.js" v=false pid="$2"
    [ -n "$pid" ] || return 1
    [ "$1" = on ] && v=true
    cat > "$js" <<JS
(function () {
    var list = workspace.windowList ? workspace.windowList() : workspace.clientList();
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        if (Number(w.pid) === $pid) { w.noBorder = $v; w.skipTaskbar = $v; w.skipSwitcher = $v; w.skipPager = $v; }
    }
})();
JS
    kwin_run_js "$js" waydroid-guard
}

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && { tail -n 200 "$LOG" > "$LOG.tmp"; mv "$LOG.tmp" "$LOG"; }
log "---- launch requested"
if pgrep -f "$CAGE_PAT" >/dev/null 2>&1; then
    if running; then
        age=$(( $(date +%s) - $(cat "$LOGD/started_at" 2>/dev/null || echo 0) ))
        log "cage already running with a live session (started ${age}s ago)"
        raise_window "$(pgrep -f "$CAGE_PAT" | head -n1)" && log "asked KWin to raise the window" || log "could not raise the window"
        if [ "$age" -lt 60 ]; then
            note "Waydroid is still starting (about 30 s): the window shows Android when ready" \
                 "Waydroid đang khởi động (khoảng 30 giây): cửa sổ sẽ hiện Android khi sẵn sàng"
        else
            note "Waydroid is already running - bringing its window to the front" \
                 "Waydroid đang chạy - đưa cửa sổ lên phía trước"
        fi
        exit 0
    fi
    log "cage is running without a live session: closing the stale cage"
    pkill -f "$CAGE_PAT"; sleep 1
fi
command -v cage >/dev/null 2>&1 || { note "cage is not installed (1 error)" "Chưa cài cage (1 lỗi)"; exit 1; }

# One launcher at a time: a second click waits while the previous window is being cleaned up.
exec 9>"$LOCK"
if ! flock -n 9; then
    log "waiting for the previous launcher to finish its cleanup"
    note "Waydroid is finishing the previous session; the window opens in a few seconds" \
         "Waydroid đang dọn phiên trước, cửa sổ sẽ mở sau vài giây"
    flock -w 120 9 || { note "Waydroid is still cleaning up, try again (1 error)" "Waydroid đang dọn dẹp, hãy thử lại (1 lỗi)"; exit 1; }
fi

failed=1
for attempt in 1 2; do
    note "Starting Waydroid... please do not close the window until the Android home screen appears" \
         "Đang khởi động Waydroid... vui lòng không đóng cửa sổ cho đến khi thấy màn hình chính Android"
    log "attempt $attempt: session before = $(waydroid status 2>/dev/null | tr '\n\t' '  ')"
    if [ "$attempt" -eq 2 ]; then
        clean_session 1 || log "WARNING: could not reach a clean state"
    else
        stopped || clean_session 0 || log "WARNING: the old session could not be stopped"
    fi
    start=$(date +%s); echo "$start" > "$LOGD/started_at"; rm -f "$LOGD/ready"
    startline=$(( $(wc -l < "$LOG") + 1 ))
    cage -- waydroid show-full-ui >>"$LOG" 2>&1 &
    CAGE_PID=$!
    sleep 3
    if kill -0 "$CAGE_PID" 2>/dev/null; then
        # While cage runs, point Waydroid's per-app menu shortcuts at cage too.
        "$DIR/waydroid-fix-shortcuts.sh" >/dev/null 2>&1 &
        # Until Android is ready: no title bar (cannot be closed by accident); then say it is safe.
        (
            guard_window on "$CAGE_PID"; sleep 3; guard_window on "$CAGE_PID"
            for t in $(seq 1 60); do
                tail -n +"$startline" "$LOG" | grep -q "Android with user 0 is ready" && break
                [ -n "$(timeout 5 waydroid app list 2>/dev/null | head -n1)" ] && break
                kill -0 "$CAGE_PID" 2>/dev/null || exit 0
                sleep 2
            done
            kill -0 "$CAGE_PID" 2>/dev/null || exit 0
            guard_window off "$CAGE_PID"
            : > "$LOGD/ready"
            log "Android is ready"
            note "Waydroid is ready - the window can be closed safely" "Waydroid đã sẵn sàng - có thể đóng cửa sổ an toàn"
        ) >/dev/null 2>&1 &
        WATCH_PID=$!
        wait "$CAGE_PID"; rc=$?
        kill "$WATCH_PID" 2>/dev/null
        dur=$(( $(date +%s) - start ))
        log "cage exited (code $rc) after ${dur}s"
        # Closing the window normally ends with code 0; an error exit soon after the start is a failure.
        if [ "$rc" -eq 0 ] || [ "$dur" -ge "$MIN_RUN" ]; then failed=0; break; fi
    else
        wait "$CAGE_PID"; rc=$?
        log "cage exited within 3 s (code $rc)"
    fi
    log "start failed: retrying once after a full recovery"
done
# Window closed (or start failed): stop everything so the next launch starts from a clean state,
# also when the window was closed while Android was still booting.
if [ ! -f "$LOGD/ready" ]; then          # closed while Android was still booting: that state needs the hard clean
    log "window closed after ${dur:-0}s before Android was ready: hard clean"
    clean_session 1 || log "WARNING: session not stopped cleanly"
else
    clean_session 0 || log "WARNING: session not stopped cleanly"
fi
if [ "$failed" -eq 1 ]; then
    note "Waydroid window could not be opened (1 error) - see $LOG" \
         "Không mở được cửa sổ Waydroid (1 lỗi) - xem $LOG"
    exit 1
fi
LAUNCH
    chmod +x "$HELPER_DIR/waydroid-cage.sh"
    cat > "$HELPER_DIR/waydroid-fix-shortcuts.sh" <<'FIXER'
#!/usr/bin/env bash
# Waydroid (re)creates ~/.local/share/applications/waydroid.<package>.desktop files that
# launch apps on the desktop compositor. Rewrite them to use the cage wrapper while cage runs.
# Waydroid tạo lại các lối tắt ứng dụng chạy bằng KWin; sửa chúng sang cage trong lúc cage chạy.
DIR="$(dirname "$(readlink -f "$0")")"
once=0; [ "${1:-}" = "--once" ] && once=1          # --once: single pass (used after install)
while [ "$once" -eq 1 ] || pgrep -f "cage -- waydroid show-full-ui" >/dev/null 2>&1; do
    for f in "$HOME"/.local/share/applications/waydroid.*.desktop; do
        [ -f "$f" ] || continue
        grep -q '^Exec=waydroid app launch ' "$f" &&
            sed -i "s|^Exec=waydroid app launch |Exec=$DIR/waydroid-app.sh |" "$f"
    done
    [ "$once" -eq 1 ] && break
    sleep 15
done
FIXER
    cat > "$HELPER_DIR/waydroid-app.sh" <<'APPW'
#!/usr/bin/env bash
# Launch one Android app (package name in $1) inside the cage-based Waydroid window.
DIR="$(dirname "$(readlink -f "$0")")"
pkg="${1:-}"
[ -n "$pkg" ] || exit 1
if ! pgrep -f "cage -- waydroid show-full-ui" >/dev/null 2>&1; then
    nohup "$DIR/waydroid-cage.sh" >/dev/null 2>&1 &
    for _ in $(seq 1 90); do
        pgrep -f "cage -- waydroid show-full-ui" >/dev/null 2>&1 &&
            waydroid status 2>/dev/null | grep -Eq 'Session:[[:space:]]+RUNNING' && break
        sleep 1
    done
    sleep 15
fi
exec waydroid app launch "$pkg"
APPW
    chmod +x "$HELPER_DIR/waydroid-fix-shortcuts.sh" "$HELPER_DIR/waydroid-app.sh"
    cat > "$HOME/.local/share/applications/waydroid-cage.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Waydroid (smooth display / hiển thị mượt)
Exec=$HELPER_DIR/waydroid-cage.sh
Icon=waydroid
Categories=System;Game;
Terminal=false
EOF
    # The stock "Waydroid" menu entry (waydroid show-full-ui) -> same cage launcher.
    # Lối tắt "Waydroid" mặc định trong menu -> trình khởi chạy cage.
    : > "$HELPER_DIR/overridden.list"
    local sysd
    for sysd in /usr/share/applications/*.desktop; do
        grep -q '^Exec=waydroid show-full-ui' "$sysd" 2>/dev/null || continue
        sed "s|^Exec=waydroid show-full-ui.*|Exec=$HELPER_DIR/waydroid-cage.sh|" "$sysd" \
            > "$HOME/.local/share/applications/$(basename "$sysd")" &&
            basename "$sysd" >> "$HELPER_DIR/overridden.list"
    done
    update-desktop-database "$(dirname "$APK_DESKTOP")" 2>/dev/null || true
}

setup_apk_handler() {
    setup_cage_launcher || return 1
    if [ ! -s "$HELPER_DIR/tools/$SIGNER_JAR_NAME" ]; then      # optional, handler retries when needed
        mkdir -p "$HELPER_DIR/tools"
        run_progress curl -fL --retry 2 -# -o "$HELPER_DIR/tools/$SIGNER_JAR_NAME.part" "$SIGNER_URL" &&
            mv -f "$HELPER_DIR/tools/$SIGNER_JAR_NAME.part" "$HELPER_DIR/tools/$SIGNER_JAR_NAME" ||
            { rm -f "$HELPER_DIR/tools/$SIGNER_JAR_NAME.part"; say "WARNING: APK signer not downloaded (will retry when needed)" "CẢNH BÁO: chưa tải công cụ ký APK (sẽ thử lại khi cần)"; }
    fi
    mkdir -p "$HELPER_DIR" "$(dirname "$APK_DESKTOP")" || return 1
    cat > "$HELPER_DIR/install-apk.sh" <<'HANDLER'
#!/usr/bin/env bash
# Installs the given .apk into Waydroid. / Cài tệp .apk vào Waydroid.
DIR="$(dirname "$(readlink -f "$0")")"
LOGD="$HOME/.local/state/waydroid-installer"; mkdir -p "$LOGD"
LOG="$LOGD/apk-install.log"
apk="${1:-}"
name="$(basename -- "$apk")"
note() {
    command -v notify-send >/dev/null 2>&1 &&
    notify-send -a "Waydroid APK" -i waydroid \
        -h string:x-canonical-private-synchronous:waydroid-apk "Waydroid APK" "$1 | $2" >/dev/null 2>&1
    return 0                                     # never let a notification pollute captured output
}
running() { waydroid status 2>/dev/null | grep -Eq 'Session:[[:space:]]+RUNNING'; }
list_pkgs() { waydroid app list 2>/dev/null | grep -E '^packageName:' | sort; }

# Mouse -> touch emulation for specific apps (exact package names, comma separated).
# Giả lập chuột -> cảm ứng cho từng ứng dụng (tên gói chính xác, cách nhau bằng dấu phẩy).
add_fake_touch() {
    local cur new p
    running || return 1
    cur="$(waydroid prop get persist.waydroid.fake_touch 2>/dev/null | tr -d '\r\n')"
    case "$cur" in "*"|*" "*) cur="" ;; esac           # drop the old wildcard / error text
    new="$cur"
    for p in "$@"; do
        [ -n "$p" ] || continue
        case ",$new," in *",$p,"*) ;; *) new="${new:+$new,}$p" ;; esac
    done
    [ "$new" = "$cur" ] && return 0
    waydroid prop set persist.waydroid.fake_touch "$new" >>"$LOG" 2>&1 && echo "fake_touch = $new" >>"$LOG"
}

# Report success and enable touch emulation for the app(s) that just appeared.
done_ok() {
    local n
    n="$(comm -13 <(echo "$before") <(list_pkgs) | sed 's/^packageName:[[:space:]]*//')"
    # shellcheck disable=SC2086
    [ -n "$n" ] && add_fake_touch $n
    note "$1" "$2"
}
JAR_NAME="uber-apk-signer-1.3.0.jar"
SIGNER_URL="https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/$JAR_NAME"
STORE="$DIR"   # APK signer lives in the helper folder, not in the shared store

# Install through Android's package manager and print its answer (Success / Failure [...]).
# With "java" the SAME authorization also installs Java when the signature turns out to be invalid
# (one password prompt instead of two). / Một lần nhập mật khẩu cho cả cài đặt và cài Java.
pm_install() {
    local tmp="$HOME/.local/share/waydroid/data/local/tmp/waydroid-installer-$$.apk"
    pkexec bash -c '
        cp -- "$1" "$2" && chmod 644 "$2"
        out="$(waydroid shell -- pm install -r "/data/local/tmp/$(basename "$2")" 2>&1)"
        rm -f "$2"; echo "$out"
        if [ "$3" = java ] && echo "$out" | grep -q INSTALL_PARSE_FAILED_NO_CERTIFICATES && ! command -v java >/dev/null 2>&1; then
            if   command -v pacman  >/dev/null 2>&1; then pacman -S --needed --noconfirm jre-openjdk-headless
            elif command -v apt-get >/dev/null 2>&1; then apt-get install -y default-jre-headless
            elif command -v dnf     >/dev/null 2>&1; then dnf install -y java-latest-openjdk-headless
            fi >>"$4" 2>&1
        fi' _ "$1" "$tmp" "${2:-}" "$LOG" 2>&1
}

# Sign an APK with a local debug key (also zip-aligns). Prints the signed file path.
# Ký APK bằng khóa debug cục bộ (đồng thời căn chỉnh zip). In ra đường dẫn tệp đã ký.
sign_apk() {
    local jar="$STORE/tools/$JAR_NAME" out signed try zip_sys src rrc
    local -a opt
    if ! command -v java >/dev/null 2>&1; then
        note "Installing Java (needed to sign APKs)..." "Đang cài Java (cần để ký APK)..."
        : > "$DIR/.java-by-installer"            # lets the uninstaller remove it again
        if   command -v pacman  >/dev/null 2>&1; then pkexec pacman -S --needed --noconfirm jre-openjdk-headless
        elif command -v apt-get >/dev/null 2>&1; then pkexec apt-get install -y default-jre-headless
        elif command -v dnf     >/dev/null 2>&1; then pkexec dnf install -y java-latest-openjdk-headless
        else false; fi >>"$LOG" 2>&1
        command -v java >/dev/null 2>&1 || { rm -f "$DIR/.java-by-installer"; return 1; }
    fi
    if [ ! -s "$jar" ]; then                     # normally already in the store
        mkdir -p "$STORE/tools"
        curl -fsSL --retry 2 -o "$jar.part" "$SIGNER_URL" >>"$LOG" 2>&1 && mv "$jar.part" "$jar" ||
            { rm -f "$jar.part"; return 1; }
    fi
    mkdir -p "$HOME/.cache"
    out="$(mktemp -d "$HOME/.cache/waydroid-sign.XXXXXX")" || return 1
    mkdir -p "$out/work"; src="$1"
    # A damaged ZIP (bad local headers) cannot be zip-aligned or signed: rebuild it first.
    # ZIP bị hỏng (sai phần đầu mục) không căn chỉnh/ký được: dựng lại trước.
    if command -v python3 >/dev/null 2>&1 && [ -f "$DIR/apk-repair.py" ]; then
        echo "--- zip check/repair" >>"$LOG"
        python3 "$DIR/apk-repair.py" "$1" "$out/work/repaired.apk" >>"$LOG" 2>&1; rrc=$?
        case "$rrc" in
            0|4) src="$out/work/repaired.apk"
                 note "APK had a damaged ZIP structure - rebuilt it before signing" \
                      "APK có cấu trúc ZIP bị hỏng - đã dựng lại trước khi ký"
                 [ "$rrc" -eq 4 ] && note "Some damaged files could not be recovered and were left out (see log)" \
                                          "Một số tệp hỏng không cứu được nên bị bỏ (xem log)" ;;
        esac
    fi
    zip_sys="$(command -v zipalign || true)"
    # The built-in zipalign does not run on every distro: try it, then the system one,
    # then sign without alignment.  / zipalign tích hợp không chạy trên mọi bản phân phối.
    for try in builtin system skip; do
        opt=()
        case "$try" in
            system) [ -n "$zip_sys" ] || continue; opt=(--zipAlignPath "$zip_sys") ;;
            skip)   opt=(--skipZipAlign) ;;
        esac
        echo "--- sign attempt: $try" >>"$LOG"
        if java -jar "$jar" --apks "$src" --out "$out" --allowResign --debug "${opt[@]}" >>"$LOG" 2>&1; then
            signed="$(ls -1 "$out"/*.apk 2>/dev/null | head -n1)"
            [ -f "$signed" ] && { rm -rf "$out/work"; echo "$signed"; return 0; }
        fi
        rm -f "$out"/* 2>/dev/null
    done
    rm -rf "$out"; return 1
}
if [ "${1:-}" = "--fake-touch" ]; then shift; add_fake_touch "$@"; exit $?; fi
[ -f "$apk" ] || { note "File not found" "Không tìm thấy tệp"; exit 1; }
if ! running; then
    note "Starting Waydroid..." "Đang khởi động Waydroid..."
    nohup "$DIR/waydroid-cage.sh" >/dev/null 2>&1 &
    for _ in $(seq 1 120); do running && pgrep -f "cage -- waydroid show-full-ui" >/dev/null 2>&1 && break; sleep 1; done
    sleep 15
fi
note "Installing $name..." "Đang cài $name..."
before="$(list_pkgs)"
out="$(waydroid app install "$apk" 2>&1)"; rc=$?
{ echo "=== $(date '+%F %T') $apk (exit code $rc)"; echo "$out"; } >> "$LOG"
sleep 3
new="$(comm -13 <(echo "$before") <(list_pkgs))"
if [ "$rc" -ne 0 ] || echo "$out" | grep -qiE 'fail|error|exception'; then
    note "Install FAILED (1 error): $name - see $LOG" "Cài THẤT BẠI (1 lỗi): $name - xem $LOG"
    exit 1
elif [ -n "$new" ]; then
    done_ok "Installed: $name" "Đã cài: $name"
else
    # "waydroid app install" is silent on failure: ask Android's package manager directly
    # to obtain the real error. / Lệnh trên không báo lỗi nên hỏi trực tiếp trình quản lý gói Android.
    had_java=0; command -v java >/dev/null 2>&1 && had_java=1
    res="$(pm_install "$apk" java)"
    { echo "--- pm install fallback"; echo "$res"; } >> "$LOG"
    [ "$had_java" -eq 0 ] && command -v java >/dev/null 2>&1 && : > "$DIR/.java-by-installer"   # remove again on uninstall
    if echo "$res" | grep -q '^Success'; then
        done_ok "Installed: $name" "Đã cài: $name"; exit 0
    fi
    reason="$(echo "$res" | grep -o 'INSTALL_[A-Z_]*' | head -n1)"
    if [ "$reason" = "INSTALL_PARSE_FAILED_NO_CERTIFICATES" ]; then
        # Unsigned / modified APK: sign automatically, otherwise leave it to the user.
        note "APK has no valid signature - signing it automatically (may take a few minutes)..." \
             "APK chưa có chữ ký hợp lệ - đang tự động ký (có thể mất vài phút)..."
        if signed="$(sign_apk "$apk")"; then
            # First try without root (no password prompt); ask Android for the real error only on failure.
            out2="$(waydroid app install "$signed" 2>&1)"; sleep 3
            { echo "--- signed copy installed without root: $signed"; echo "$out2"; } >> "$LOG"
            if [ -n "$(comm -13 <(echo "$before") <(list_pkgs))" ]; then
                rm -rf "$(dirname "$signed")"
                done_ok "Installed (auto-signed with a local debug key): $name" \
                        "Đã cài (tự ký bằng khóa debug cục bộ): $name"; exit 0
            fi
            res="$(pm_install "$signed")"
            { echo "--- signed copy: $signed"; echo "$res"; } >> "$LOG"
            rm -rf "$(dirname "$signed")"
            if echo "$res" | grep -q '^Success'; then
                done_ok "Installed (auto-signed with a local debug key): $name" \
                        "Đã cài (tự ký bằng khóa debug cục bộ): $name"; exit 0
            fi
            reason="$(echo "$res" | grep -o 'INSTALL_[A-Z_]*' | head -n1)"
        else
            note "Auto-signing failed (1 error): sign $name manually (e.g. MT Manager or apksigner) and install again - see $LOG" \
                 "Tự ký thất bại (1 lỗi): hãy tự ký $name (ví dụ MT Manager hoặc apksigner) rồi cài lại - xem $LOG"
            exit 1
        fi
    fi
    case "$reason" in
        INSTALL_PARSE_FAILED_NO_CERTIFICATES)
            en="APK is corrupted (signing did not help)"; vi="APK bị hỏng (đã thử ký nhưng không được)" ;;
        INSTALL_FAILED_NO_MATCHING_ABIS)
            en="no compatible CPU architecture (translation layer?)"; vi="không có kiến trúc CPU phù hợp (lớp dịch?)" ;;
        INSTALL_FAILED_INSUFFICIENT_STORAGE)
            en="not enough storage"; vi="không đủ dung lượng" ;;
        INSTALL_FAILED_INVALID_APK)
            en="invalid APK (possibly not zip-aligned)"; vi="APK không hợp lệ (có thể chưa căn chỉnh zip)" ;;
        "")
            en="no answer (authorization cancelled?)"; vi="không có phản hồi (đã hủy xác thực?)" ;;
        *)  en="$reason"; vi="$reason" ;;
    esac
    note "Install FAILED (1 error): $name - $en" "Cài THẤT BẠI (1 lỗi): $name - $vi"
    exit 1
fi
HANDLER
    chmod +x "$HELPER_DIR/install-apk.sh"
    cat > "$HELPER_DIR/apk-repair.py" <<'APKREPAIR'
#!/usr/bin/env python3
# Rebuild an APK/ZIP whose local file headers are damaged so it can be zip-aligned and signed.
# Each damaged entry is recovered from the central directory (CRC-verified) or left out.
# Dựng lại APK có ZIP bị hỏng phần đầu tệp để có thể căn chỉnh và ký; mục nào không cứu được sẽ bị bỏ.
# Exit codes: 0 rebuilt, 3 nothing to repair, 4 rebuilt but some entries were dropped, 1 failure.
import re, sys, zipfile, zlib

LFH = b"PK\x03\x04"
SIG = re.compile(r"^META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))$")


def raw_name_len(zi):
    enc = "utf-8" if zi.flag_bits & 0x800 else "cp437"
    try:
        return len(zi.orig_filename.encode(enc))
    except Exception:
        return len(zi.orig_filename.encode("utf-8"))


def recover(f, zi):
    """Find the data of an entry whose local header is unusable; verify size and CRC32."""
    if zi.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        return None
    base = zi.header_offset + 30 + raw_name_len(zi)
    f.seek(base)
    blob = f.read(zi.compress_size + 128)
    tried = []
    for extra in [len(zi.extra), 0] + list(range(1, 65)):
        if extra in tried:
            continue
        tried.append(extra)
        raw = blob[extra:extra + zi.compress_size]
        if len(raw) != zi.compress_size:
            continue
        try:
            if zi.compress_type == zipfile.ZIP_STORED:
                data = raw
            else:
                d = zlib.decompressobj(-15)
                d.decompress(raw[:4096])            # cheap filter before the full decompress
                data = zlib.decompress(raw, -15)
        except zlib.error:
            continue
        if len(data) == zi.file_size and (zlib.crc32(data) & 0xFFFFFFFF) == zi.CRC:
            return data
    return None


def main(src, dst):
    zin = zipfile.ZipFile(src)
    infos = zin.infolist()
    f = open(src, "rb")
    bad = set()
    for zi in infos:
        f.seek(zi.header_offset)
        if f.read(4) != LFH:
            bad.add(zi.filename)
    if not bad:
        print("OK: ZIP structure is fine (%d entries), no repair needed" % len(infos))
        return 3
    print("Damaged local headers: %d of %d entries" % (len(bad), len(infos)))
    dropped, recovered, copied = [], 0, 0
    with zipfile.ZipFile(dst, "w") as zout:
        for zi in infos:
            if SIG.match(zi.filename):              # old signature files: the signer recreates them
                continue
            data = None
            if zi.filename not in bad:
                try:
                    data = zin.read(zi)
                except Exception:
                    data = None
            if data is None:
                data = recover(f, zi)
                if data is None:
                    dropped.append(zi.filename)
                    continue
                recovered += 1
            ni = zipfile.ZipInfo(zi.filename, zi.date_time)
            ni.compress_type = zi.compress_type
            ni.external_attr = zi.external_attr
            ni.create_system = zi.create_system
            zout.writestr(ni, data, compress_type=zi.compress_type, compresslevel=1)
            copied += 1
    print("Rebuilt: %d entries copied, %d recovered from damaged headers, %d dropped"
          % (copied, recovered, len(dropped)))
    for n in dropped[:20]:
        print("DROPPED: " + n)
    return 4 if dropped else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    except Exception as e:                           # noqa
        print("FAILED: %s" % e)
        sys.exit(1)
APKREPAIR
    chmod +x "$HELPER_DIR/apk-repair.py"
    cat > "$APK_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Install APK with Waydroid / Cài APK bằng Waydroid
Exec=$HELPER_DIR/install-apk.sh %f
Icon=waydroid
MimeType=$APK_MIME;
NoDisplay=true
Terminal=false
Categories=System;
EOF
    update-desktop-database "$(dirname "$APK_DESKTOP")" 2>/dev/null || true
    xdg-mime default waydroid-apk-installer.desktop "$APK_MIME" 2>/dev/null || true
}

# Environment check: prints what was found; returns 1 when Waydroid cannot be installed here.
# Kiểm tra môi trường: in những gì tìm thấy; trả về 1 nếu không thể cài Waydroid trên hệ thống này.
preflight() {
    local bad=0 distro gpu avail mem
    distro="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}" )"
    detect_pm
    say "Distribution: $distro | kernel $(uname -r) | $(uname -m)" "Bản phân phối: $distro | kernel $(uname -r) | $(uname -m)"
    case "$PM" in
        pacman|apt|dnf) say "Package manager: $PM (supported)" "Trình quản lý gói: $PM (được hỗ trợ)" ;;
        *) say "NOT SUPPORTED: no pacman/apt/dnf found (openSUSE, NixOS, Alpine, Gentoo... are not covered)" \
               "KHÔNG HỖ TRỢ: không có pacman/apt/dnf (openSUSE, NixOS, Alpine, Gentoo... chưa được hỗ trợ)"; bad=1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64|aarch64) ;;
        *) say "NOT SUPPORTED CPU architecture: $(uname -m)" "KHÔNG HỖ TRỢ kiến trúc CPU: $(uname -m)"; bad=1 ;;
    esac
    if findmnt -no OPTIONS /usr 2>/dev/null | tr ',' '\n' | grep -qx ro; then
        say "NOT SUPPORTED: the system partition is read-only (immutable system such as SteamOS)" \
            "KHÔNG HỖ TRỢ: phân vùng hệ thống chỉ đọc (hệ thống bất biến như SteamOS)"; bad=1
    fi
    say "Session: ${XDG_SESSION_TYPE:-unknown}, desktop: ${XDG_CURRENT_DESKTOP:-unknown}" \
        "Phiên: ${XDG_SESSION_TYPE:-không rõ}, môi trường: ${XDG_CURRENT_DESKTOP:-không rõ}"
    if grep -q binder /proc/filesystems 2>/dev/null || modinfo binder_linux >/dev/null 2>&1; then
        say "Kernel binder support: found" "Hỗ trợ binder của kernel: có"
    else
        say "WARNING: no binder support found in this kernel (Waydroid needs it; try a kernel with binder)" \
            "CẢNH BÁO: kernel chưa thấy hỗ trợ binder (Waydroid cần; hãy dùng kernel có binder)"
    fi
    gpu="$(lspci 2>/dev/null | grep -iE 'vga|3d' | sed 's/^[^:]*: //' | head -n2 | paste -sd';' -)"
    say "Graphics: ${gpu:-unknown}" "Card đồ họa: ${gpu:-không rõ}"
    echo "$gpu" | grep -qi nvidia && say "WARNING: NVIDIA card: Waydroid may need software rendering (slower)" \
                                         "CẢNH BÁO: card NVIDIA: Waydroid có thể phải dùng vẽ bằng phần mềm (chậm hơn)"
    avail="$(df -BG --output=avail / 2>/dev/null | tail -n1 | tr -dc '0-9')"
    [ "${avail:-99}" -lt 8 ] && say "WARNING: only ${avail} GB free on / (about 8 GB needed)" "CẢNH BÁO: chỉ còn ${avail} GB trống (cần khoảng 8 GB)"
    mem="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    [ "${mem:-9999}" -lt 4096 ] && say "WARNING: only ${mem} MB RAM (4 GB or more recommended)" "CẢNH BÁO: chỉ có ${mem} MB RAM (nên có từ 4 GB)"
    gpu="$(port53_holders)"
    [ -n "$gpu" ] && say "WARNING: port 53 is used by: $gpu (Waydroid's network needs it on its own bridge; see the note at the start of the install)" \
                         "CẢNH BÁO: cổng 53 đang bị chiếm bởi: $gpu (mạng của Waydroid cần cổng này trên cầu nối riêng; xem lưu ý ở đầu quá trình cài)"
    return $bad
}

do_install() {
    TOTAL_STEPS=10; local rc_init=0
    say "NOTE: if you use a DNS blocker / DNS proxy / firewall (e.g. AdGuard Home, Pi-hole, BigLinux Rethink), turn its DNS blocking off before installing Waydroid and back on afterwards." \
        "LƯU Ý: nếu bạn dùng bộ chặn DNS / DNS proxy / tường lửa (ví dụ AdGuard Home, Pi-hole, BigLinux Rethink), hãy tắt chặn DNS trước khi cài Waydroid và bật lại sau khi cài xong."
    notify "Turn off DNS blocking (AdGuard, Pi-hole, Rethink...) before installing" "Hãy tắt chặn DNS (AdGuard, Pi-hole, Rethink...) trước khi cài"
    preflight || { fail "This system is not supported (see the lines above)" "Hệ thống này chưa được hỗ trợ (xem các dòng phía trên)"; return; }
    echo incomplete > "$STATE_FILE"            # cleared only after a run with 0 errors
    [ "$RESUME" -eq 1 ] || : > "$DONE_FILE"    # fresh install -> forget old step marks

    step "Requesting administrator rights" "Yêu cầu quyền quản trị"
    get_root || { fail "No sudo rights" "Không có quyền sudo"; return; }

    validate_done_marks
    detect_kernel_flavor
    [ "$KERNEL_FLAVOR" = xanmod ] && xanmod_preflight
    if ! ensure_psi; then
        fail "Kernel has no usable PSI (Android's lmkd would crash-loop)" "Kernel không có PSI dùng được (lmkd của Android sẽ lỗi liên tục)"
        collect_diag; return
    fi
    if [ "$NEEDS_REBOOT" -eq 1 ]; then       # nothing is lost: the run is resumed after the reboot
        say "REBOOT NEEDED: restart the computer (keep the same kernel), then run this script again to finish the install." \
            "CẦN KHỞI ĐỘNG LẠI: hãy khởi động lại máy (giữ nguyên kernel), rồi chạy lại script để cài tiếp."
        notify "Reboot, then run the script again" "Khởi động lại rồi chạy lại script"
        return
    fi

    ensure_session_env
    say "Session: type=${XDG_SESSION_TYPE:-unknown} wayland=${WAYLAND_DISPLAY:-none} x11=${DISPLAY:-none}" \
        "Phiên: loại=${XDG_SESSION_TYPE:-không rõ} wayland=${WAYLAND_DISPLAY:-không} x11=${DISPLAY:-không}"

    step "Installing Waydroid packages" "Cài đặt gói Waydroid"
    once pkgs install_packages || { fail "Package installation failed" "Cài gói thất bại"; return; }

    step "Preparing download store (reusing saved files)" "Chuẩn bị kho lưu trữ (dùng lại tệp đã tải)"
    prepare_store

    step "Checking kernel binder support" "Kiểm tra hỗ trợ binder của kernel"
    if grep -q binder /proc/filesystems 2>/dev/null; then
        say "Kernel binder: OK (already available)" "Binder của kernel: OK (đã có sẵn)"
    elif check_kernel_binder; then
        record_fix "FIXED" "binder module loaded"          # logged only when something was really fixed
    else
        fail "Kernel has no binder support; install a binder-enabled kernel/module and re-run" \
             "Kernel thiếu binder; hãy cài kernel/module hỗ trợ binder rồi chạy lại"
        collect_diag; return
    fi

    step "Initializing Waydroid image" "Khởi tạo ảnh Waydroid"
    init_waydroid; rc_init=$?
    if [ "$rc_init" -eq 2 ]; then
        fail "Waydroid package is not installed (the packages step did not really succeed); run the script again" \
             "Chưa cài gói Waydroid (bước cài gói chưa thật sự thành công); hãy chạy lại script"
        sed -i '/^pkgs$/d' "$DONE_FILE" 2>/dev/null; collect_diag; return
    elif [ "$rc_init" -ne 0 ]; then
        fail "waydroid init failed (check the network and the log above)" "waydroid init lỗi (kiểm tra mạng và log phía trên)"
        collect_diag; return
    fi

    step "Starting container and session" "Khởi động container và phiên"
    if ! enable_container; then
        fail "Container service failed" "Dịch vụ container lỗi"; collect_diag; return
    fi
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        fail "No Wayland display found: log in to a Wayland session (Waydroid session cannot start without it)" \
             "Không tìm thấy màn hình Wayland: hãy đăng nhập phiên Wayland (thiếu thì phiên Waydroid không chạy)"
        collect_diag; return
    fi
    session_running || wait_for_quiet
    session_running || precheck_port53 || true      # warning only; the start below decides
    if ! start_session; then
        if sudo -n journalctl -u waydroid-container.service -n 80 --no-pager 2>&1 | grep -q 'Command failed: % mount' &&
           say "Waydroid could not mount its image: re-initializing it" "Waydroid không gắn được ảnh: khởi tạo lại ảnh" &&
           init_waydroid && sudo systemctl restart waydroid-container.service && start_session; then
            say "Image repaired" "Đã sửa ảnh"
        else
            explain_start_failure || fail "Session did not start" "Phiên không khởi động được"
            collect_diag; return
        fi
    fi

    step "Adding Google Play + ARM translation layer" "Thêm Google Play + lớp dịch ARM"
    if ! wait_android_boot; then
        retry_with_fresh_images || { fail "Android did not finish booting" "Android khởi động chưa xong"; boot_failed_hint; collect_diag; return; }
    fi
    once ws run_waydroid_script || fail "waydroid_script (GApps/translation) failed" "waydroid_script (GApps/lớp dịch) lỗi"

    step "Applying touch/multi-window/multi-arch settings" "Áp dụng cảm ứng/đa cửa sổ/đa kiến trúc"
    timeout 25 waydroid session stop >/dev/null 2>&1   # waydroid_script leaves the session stopped
    sudo systemctl restart waydroid-container.service
    booted=0
    if start_session && wait_android_boot; then
        booted=1
        once props set_properties || fail "Setting properties failed" "Đặt thuộc tính lỗi"
    else
        fail "Android did not finish booting" "Android khởi động chưa xong"; boot_failed_hint; collect_diag
    fi

    step "Disabling Google Play Protect" "Tắt Google Play Protect"
    if [ "$booted" -eq 1 ]; then
        once pp disable_play_protect || fail "Could not disable Play Protect" "Không tắt được Play Protect"
        timeout 25 waydroid session stop >/dev/null 2>&1   # next launch (smooth shortcut) starts a fresh session
    else
        fail "Skipped: Android is not running" "Bỏ qua: Android chưa chạy"
    fi

    step "Enabling double-click APK install" "Bật nhấp đúp APK để cài"
    once apk setup_apk_handler || fail "APK handler setup failed" "Tạo trình cài APK lỗi"

    "$HELPER_DIR/waydroid-fix-shortcuts.sh" --once 2>/dev/null || true   # per-app menu shortcuts -> cage

    store_manifest || say "WARNING: could not write the store checksum list" "CẢNH BÁO: không ghi được danh sách mã băm của kho"

    if [ "$ERR_COUNT" -eq 0 ]; then
        echo complete > "$STATE_FILE"; rm -f "$DONE_FILE"
    fi
}

# ----------------------------------------------------------- uninstall part --
# Remove every launcher (menu / Desktop) that points to Waydroid, whatever its file name.
# Xóa mọi lối tắt (menu / Desktop) trỏ tới Waydroid, bất kể tên tệp.
remove_waydroid_launchers() {
    local dir f
    local -a dirs=("$HOME/.local/share/applications" "$HOME/Desktop")
    command -v xdg-user-dir >/dev/null 2>&1 && dirs+=("$(xdg-user-dir DESKTOP 2>/dev/null)")
    for dir in "${dirs[@]}"; do
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' f; do
            rm -f "$f" && say "Removed launcher: $f" "Đã xóa lối tắt: $f"
        done < <(find "$dir" -maxdepth 1 -name '*.desktop' -print0 2>/dev/null | xargs -0 -r grep -liZ 'waydroid' 2>/dev/null)
    done
    find "$HOME/.local/share/icons" -iname '*waydroid*' -delete 2>/dev/null
    true
}

# Make desktop environments forget the removed launchers right away.
refresh_menus() {
    local k
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
    command -v xdg-desktop-menu >/dev/null 2>&1 && xdg-desktop-menu forceupdate 2>/dev/null
    for k in kbuildsycoca6 kbuildsycoca5; do
        command -v "$k" >/dev/null 2>&1 && { "$k" --noincremental >/dev/null 2>&1; break; }
    done
    true
}

do_uninstall() {
    TOTAL_STEPS=5
    local rm_cage=0 rm_gimg=0 rm_java=0 rm_repo=0 rm_extra=0 rm_dns=0 rm_psi=0 n left
    [ -f "$HELPER_DIR/.extra-images-by-installer" ] && rm_extra=1     # images copied from the store
    [ -f "$HELPER_DIR/.cage-by-installer" ] && rm_cage=1            # cage was installed by this script
    [ -f "$HELPER_DIR/.gapps-image-by-installer" ] && rm_gimg=1     # GApps image package installed by this script
    [ -f "$HELPER_DIR/.java-by-installer" ] && rm_java=1            # Java was installed for APK signing
    [ -f "$HELPER_DIR/.waydroid-repo-by-installer" ] && rm_repo=1   # apt repository added by this script
    [ -f "$HELPER_DIR/.dnsmasq-dropin-by-installer" ] && rm_dns=1   # dnsmasq drop-in made by this script
    [ -f "$HELPER_DIR/.psi-grub-by-installer" ] && rm_psi=1         # psi=1 added to GRUB by this script
    step "Requesting administrator rights" "Yêu cầu quyền quản trị"
    get_root || { fail "No sudo rights" "Không có quyền sudo"; return; }

    step "Stopping Waydroid" "Dừng Waydroid"
    waydroid session stop >/dev/null 2>&1
    pkill -f "^cage -- waydroid show-full-ui" 2>/dev/null          # close a still-open Waydroid window
    sudo systemctl disable --now waydroid-container.service >/dev/null 2>&1
    sudo pkill -f '^(/usr/bin/)?python[0-9.]* .*/waydroid (session|show-full-ui)' 2>/dev/null

    step "Removing launchers and the APK double-click handler" "Gỡ lối tắt và trình cài APK nhấp đúp"
    if [ -f "$HELPER_DIR/overridden.list" ]; then         # user-level copies of stock menu entries
        while IFS= read -r n; do [ -n "$n" ] && rm -f "$HOME/.local/share/applications/$n"; done < "$HELPER_DIR/overridden.list"
    fi
    rm -rf "$HELPER_DIR" "$APK_DESKTOP"
    remove_waydroid_launchers
    [ -f "$HOME/.config/mimeapps.list" ] &&
        sed -i '/waydroid-apk-installer.desktop/d' "$HOME/.config/mimeapps.list"

    step "Removing Waydroid package" "Gỡ gói Waydroid"
    detect_pm
    # Shared dependencies/kernel modules are intentionally kept (gaming performance).
    # Giữ lại thư viện/mô-đun dùng chung để đảm bảo hiệu suất chơi game.
    case "$PM" in
        pacman) run_progress sudo pacman -Rns --noconfirm waydroid ;;   # also drops Waydroid-only deps
        apt)    run_progress sudo apt-get purge -y waydroid ;;
        dnf)    run_progress sudo dnf remove -y waydroid ;;
        *)      false ;;
    esac || fail "Package removal failed" "Gỡ gói lỗi"
    if [ "$rm_gimg" -eq 1 ] && [ "$PM" = pacman ]; then
        sudo pacman -Rns --noconfirm waydroid-image-gapps || fail "Image package removal failed" "Gỡ gói ảnh lỗi"
    fi
    if [ "$rm_cage" -eq 1 ]; then          # remove cage only if this script installed it
        case "$PM" in
            pacman) sudo pacman -Rns --noconfirm cage ;;
            apt)    sudo apt-get purge -y cage ;;
            dnf)    sudo dnf remove -y cage ;;
        esac || fail "cage removal failed" "Gỡ cage lỗi"
    fi
    if [ "$rm_java" -eq 1 ]; then          # remove Java only if the APK signer installed it
        case "$PM" in
            pacman) sudo pacman -Rns --noconfirm jre-openjdk-headless ;;
            apt)    sudo apt-get purge -y default-jre-headless ;;
            dnf)    sudo dnf remove -y java-latest-openjdk-headless ;;
        esac || fail "Java removal failed" "Gỡ Java lỗi"
    fi
    if [ "$rm_repo" -eq 1 ] && [ "$PM" = apt ]; then   # the Waydroid apt repository this script added
        sudo rm -f /etc/apt/sources.list.d/waydroid.list /usr/share/keyrings/waydroid.gpg
        sudo apt-get update -y >/dev/null 2>&1
    fi
    # System-wide launchers left behind (failed removal or manual install): remove and report.
    left="$(ls /usr/share/applications 2>/dev/null | grep -i waydroid || true)"
    if [ -n "$left" ]; then
        while IFS= read -r n; do
            sudo rm -f "/usr/share/applications/$n" && say "Removed leftover launcher: $n" "Đã xóa lối tắt còn sót: $n"
        done <<< "$left"
    fi
    hash -r
    if command -v waydroid >/dev/null 2>&1; then
        fail "Waydroid is still installed at $(command -v waydroid) (installed another way?)" \
             "Waydroid vẫn còn tại $(command -v waydroid) (cài bằng cách khác?)"
    fi

    step "Deleting Waydroid data and caches" "Xóa dữ liệu và bộ nhớ đệm Waydroid"
    if [ "$rm_extra" -eq 1 ]; then
        sudo rm -f /etc/waydroid-extra/images/system.img /etc/waydroid-extra/images/vendor.img
        sudo rmdir /etc/waydroid-extra/images /etc/waydroid-extra 2>/dev/null
    fi
    if [ "$rm_psi" -eq 1 ] && [ -f "$GRUB_DEFAULT_FILE" ]; then   # remove only our own psi=1 token
        sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=[\"'])psi=1 /\1/" "$GRUB_DEFAULT_FILE"
        grub_regen >/dev/null 2>&1 || say "Run  sudo update-grub  to finish removing psi=1" "Hãy chạy  sudo update-grub  để gỡ nốt psi=1"
        sudo rm -f "$GRUB_BACKUP"
    fi
    if [ "$rm_dns" -eq 1 ]; then            # give the system dnsmasq its original command line back
        sudo rm -f "$DNSMASQ_DROPIN"; sudo rmdir "$DNSMASQ_DROPIN_DIR" 2>/dev/null
        sudo systemctl daemon-reload; sudo systemctl try-restart dnsmasq.service
    fi
    sudo rm -rf /var/lib/waydroid
    rm -rf "$HOME/.local/share/waydroid" "$HOME/.cache/waydroid-script" "$HOME"/.cache/waydroid-sign.* 2>/dev/null
    sudo rm -rf /root/.cache/waydroid-script 2>/dev/null
    remove_waydroid_launchers          # once more: Waydroid may have re-created entries while stopping
    refresh_menus
    rm -rf "$STATE_DIR"
    say "Download store kept for a faster reinstall: $STORE_DIR (delete it manually to free space)" \
        "Kho lưu trữ được giữ lại để cài lại nhanh: $STORE_DIR (xóa thủ công nếu cần giải phóng dung lượng)"
}

# --------------------------------------------------------------------- main --
say "Log file: $LOG_FILE" "Tệp log: $LOG_FILE"
if [ "${1:-}" = "--check" ]; then               # report only: nothing is installed or changed
    if preflight; then say "This system looks supported." "Hệ thống này có vẻ được hỗ trợ."; exit 0; fi
    say "This system is NOT supported." "Hệ thống này KHÔNG được hỗ trợ."; exit 1
fi
if [ "${1:-}" = "--update-helpers" ]; then
    # Refresh launcher, APK handler, repair tool and shortcuts without reinstalling Waydroid.
    # Cập nhật các script phụ trợ trên máy đã cài, không cần cài lại Waydroid.
    waydroid_installed || { say "Waydroid is not installed" "Chưa cài Waydroid"; exit 1; }
    mkdir -p "$HELPER_DIR"
    if setup_apk_handler; then
        "$HELPER_DIR/waydroid-fix-shortcuts.sh" --once 2>/dev/null
        say "Helper scripts updated" "Đã cập nhật các script phụ trợ"
        exit 0
    fi
    say "ERROR: could not update the helper scripts" "LỖI: không cập nhật được các script phụ trợ"
    exit 1
fi
if [ "${1:-}" = "--fake-touch" ]; then          # ./waydroid-installer.sh --fake-touch com.example.game
    shift
    [ -x "$HELPER_DIR/install-apk.sh" ] || { say "Run --update-helpers first" "Hãy chạy --update-helpers trước"; exit 1; }
    exec "$HELPER_DIR/install-apk.sh" --fake-touch "$@"
fi
if [ "${1:-}" = "--diag" ]; then                  # ./waydroid-installer.sh --diag  -> full report in the log, changes nothing
    MODE=diag
    detect_kernel_flavor
    say "Diagnostics only (nothing is installed or changed). Run it right after Waydroid fails to open, then send the log." \
        "Chỉ chẩn đoán (không cài hay thay đổi gì). Hãy chạy ngay sau khi Waydroid không mở được, rồi gửi log."
    get_root || { say "No sudo rights" "Không có quyền sudo"; exit 1; }
    collect_diag
    say "Report saved in: $LOG_FILE" "Báo cáo đã lưu tại: $LOG_FILE"
    [ -t 0 ] && { read -r -p "Press Enter to close | Nhấn Enter để đóng... " _; }
    exit 0
fi
if [ "${1:-}" = "--fresh" ]; then               # forget a stuck/unfinished install and start clean
    rm -f "$STATE_FILE" "$DONE_FILE"
    say "Saved install state cleared" "Đã xóa trạng thái cài đặt đã lưu"
fi
[ "${1:-}" = "--resume" ] && RESUME=1          # force "continue unfinished install"
[ "$(cat "$STATE_FILE" 2>/dev/null)" = "incomplete" ] && RESUME=1
if waydroid_installed && [ "$RESUME" -eq 0 ]; then
    MODE=uninstall
    say "Waydroid detected -> UNINSTALL mode (install disabled)" \
        "Phát hiện Waydroid -> chế độ GỠ BỎ (đã vô hiệu cài đặt)"
    do_uninstall
else
    MODE=install
    if [ "$RESUME" -eq 1 ]; then
        say "Unfinished install detected -> RESUMING install (completed steps are skipped)" \
            "Phát hiện cài đặt dở dang -> TIẾP TỤC cài (bỏ qua bước đã xong)"
    else
        say "Waydroid not found -> INSTALL mode (uninstall disabled)" \
            "Chưa có Waydroid -> chế độ CÀI ĐẶT (đã vô hiệu gỡ bỏ)"
    fi
    do_install
fi

# ------------------------------------------------------------------ summary --
echo
if [ "$ERR_COUNT" -eq 0 ] && [ "$NEEDS_REBOOT" -eq 1 ]; then
    say "Paused: restart the computer (same kernel), then run this script again - it continues the install." \
        "Tạm dừng: hãy khởi động lại máy (giữ nguyên kernel), rồi chạy lại script - nó sẽ cài tiếp."
elif [ "$ERR_COUNT" -eq 0 ]; then
    say "Done: $MODE completed with 0 errors." "Hoàn tất: $MODE xong, 0 lỗi."
    notify "Done ($MODE), 0 errors" "Hoàn tất ($MODE), 0 lỗi"
    [ "$MODE" = install ] && say \
        "Next: open Waydroid or any app from the menu (they now start in the smooth cage window), log in to Google Play; if prompted, register the device ID. Reboot is recommended." \
        "Tiếp theo: mở Waydroid hoặc ứng dụng từ menu (nay chạy trong cửa sổ cage mượt), đăng nhập Google Play; nếu được yêu cầu, đăng ký device ID. Nên khởi động lại máy."
else
    say "Finished with $ERR_COUNT error(s):" "Kết thúc với $ERR_COUNT lỗi:"
    for e in "${ERR_LIST[@]}"; do echo "   - $e"; done
    notify "$ERR_COUNT error(s) - see log" "$ERR_COUNT lỗi - xem log"
    say "Details: $LOG_FILE" "Chi tiết: $LOG_FILE"
    [ "$MODE" = install ] && say "Run the script again to resume from the failed step." "Chạy lại script để tiếp tục từ bước bị lỗi."
fi
[ -t 0 ] && { read -r -p "Press Enter to close | Nhấn Enter để đóng... " _; }
exit "$ERR_COUNT"
