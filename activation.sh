#!/usr/bin/env bash
# =============================================================================
#  activation.sh -- complete activation-state backup / restore for SSHRD_Script
# -----------------------------------------------------------------------------
#  Fork addition. Sourced by sshrd.sh, never run directly:
#
#      ./sshrd.sh --backup-activation-full     (aliases: --dump-activation-all)
#      ./sshrd.sh --restore-activation-full
#      ./sshrd.sh --activation-info
#
#  Written for macOS 12 (system bash 3.2 + BSD userland) and Linux (GNU),
#  because that is what SSHRD_Script itself supports.  Deliberately:
#    * no bash 4 features (no associative arrays, no ${x,,}, no mapfile)
#    * no GNU-only flags (no sed -i, no stat -c, no sha256sum requirement)
#    * no host-side plist tooling (macOS has plutil, Linux usually does not)
#    * no device-side tar/find dependency, only scp + plain sh builtins
#
# -----------------------------------------------------------------------------
#  WHY THIS EXISTS
# -----------------------------------------------------------------------------
#  Upstream --backup-activation saves exactly three files:
#      * activation_record.plist  / pod_record.plist   (the ticket)
#      * com.apple.commcenter.device_specific_nobackup.plist
#      * IC-Info.sisv
#  On some iOS versions that is enough for SpringBoard to say "Activated",
#  but it is NOT the whole activation state, and it is not what keeps
#  iServices (iMessage / FaceTime / App Store device auth) working.  Missing:
#
#  1. <mobileactivationd container>/Library/internal/data_ark.plist
#     mobileactivationd's own "data ark": the activation state it actually
#     trusts, the record copy, the device certificate pieces, the activation
#     randomness and the ProductVersion/BuildVersion it was activated on.
#     Without a matching data_ark.plist the record on disk is often ignored
#     (or the device boot-rejects and goes back to the Hello screen).
#
#  2. the whole /private/var/mobile/Library/FairPlay tree
#     The device's FairPlay identity.  IC-Info.sisv is only one file of it.
#     This is what Apple's servers use to authenticate *this* device when
#     iServices registers.
#
#  3. /private/var/root/Library/Lockdown
#     pair_records + lockdown plists (and, on old iOS, a second data_ark.plist).
#
#  4. /private/var/mobile/Library/Preferences/com.apple.purplebuddy.plist
#     Setup Assistant state, so the device boots to the home screen instead of
#     the Hello screen after a restore.
#
# -----------------------------------------------------------------------------
#  WHAT CANNOT BE SAVED FROM A RAMDISK (be realistic about "everything")
# -----------------------------------------------------------------------------
#  Keychain items are not files: iMessage/IDS keys, Apple ID tokens and the
#  iServices account material live in the keychain, wrapped by SEP class keys.
#  A ramdisk cannot read or write them.  So:
#    * restoring the files below preserves the *activation identity*, which is
#      what makes iMessage/FaceTime registration succeed;
#    * if the device was ERASED, you still have to sign in with your Apple ID
#      (and sometimes toggle iMessage/FaceTime off and on) once after restoring.
#  Nothing here can copy another device's iServices registration.
#
# -----------------------------------------------------------------------------
#  LAYOUT OF A FULL DUMP
# -----------------------------------------------------------------------------
#  userdata/activation_records/<serial>/full/
#      mad-Library/                     copy of <container>/Library
#          internal/data_ark.plist      <-- the important one
#          activation_records/*         activation_record.plist / pod_record.plist
#          Preferences/                 mobileactivationd prefs (if any)
#      FairPlay/                        copy of /private/var/mobile/Library/FairPlay
#      Lockdown/                        copy of /private/var/root/Library/Lockdown
#      com.apple.commcenter.device_specific_nobackup.plist
#      com.apple.purplebuddy.plist      (optional)
#      legacy/                          iOS 7-9 layout, best effort
#      manifest.txt                     serial / iOS / ramdisk / container UUID
#      SHA256SUMS
#
#  userdata/activation_records/<serial>/
#      activation_record.plist          <- compat copies so the old
#      IC-Info.sisv                        --restore-activation command still
#      com.apple...nobackup.plist          works from a full dump
#      data_ark.plist
# =============================================================================

ACT_VERSION="1.0.0"
ACT_ROOT="${ACT_ROOT:-userdata/activation_records}"
ACT_PASS="alpine"

# -----------------------------------------------------------------------------
#  thin wrappers around the bundled, per-architecture host tools
# -----------------------------------------------------------------------------
act_bin_dir() {
    printf '%s/%s' "$(uname)" "$(uname -m)"
}

act_ssh() {
    "$(act_bin_dir)/sshpass" -p "$ACT_PASS" ssh root@127.0.0.1 -p2222 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "$@"
}

act_scp() {
    "$(act_bin_dir)/sshpass" -p "$ACT_PASS" scp -P2222 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "$@"
}

# -----------------------------------------------------------------------------
#  process / connection handling
# -----------------------------------------------------------------------------
act_stop() {
    killall iproxy > /dev/null 2>&1 || true
    if [ "$(uname)" = 'Linux' ]; then
        sudo killall usbmuxd > /dev/null 2>&1 || true
    fi
}

act_die() {
    echo_error "$1"
    act_stop
    exit 1
}

act_done() {
    act_stop
    exit 0
}

act_start() {
    if [ "$(uname)" = 'Linux' ]; then
        sudo systemctl stop usbmuxd > /dev/null 2>&1 || true
        sudo killall usbmuxd > /dev/null 2>&1 || true
        sleep .1
        sudo usbmuxd -pf > /dev/null 2>&1 &
        sleep .1
    fi
    killall iproxy > /dev/null 2>&1 || true
    "$(act_bin_dir)/iproxy" 2222 22 > /dev/null 2>&1 &
    # keep bash from printing "Terminated: 15" when act_stop kills it
    disown 2>/dev/null || true
    sleep 1
}

act_wait_ssh() {
    local i
    i=0
    while [ "$i" -lt 15 ]; do
        if act_ssh "true" > /dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

# -----------------------------------------------------------------------------
#  fork banner (pure ASCII so it renders in any terminal / locale)
# -----------------------------------------------------------------------------
fate_banner() {
    if [ -n "${ACT_BANNER_SHOWN:-}" ]; then
        return 0
    fi
    ACT_BANNER_SHOWN=1
    printf '\n'
    printf '%s\n' "${color_B:-} _____      _      _____   _____ ${color_N:-}"
    printf '%s\n' "${color_B:-}|  ___|    / \\    |_   _| |  ___|${color_N:-}"
    printf '%s\n' "${color_B:-}| |_      / _ \\     | |   | |__  ${color_N:-}"
    printf '%s\n' "${color_B:-}|  _|    / ___ \\    | |   |  __| ${color_N:-}"
    printf '%s\n' "${color_B:-}|_|     /_/   \\_\\   |_|   |_____|${color_N:-}"
    printf '%s\n' "${color_Y:-}  FATE's SSHRD fork  |  complete activation backup  |  activation.sh ${ACT_VERSION}${color_N:-}"
    printf '\n'
}

act_prepare() {
    fate_banner
    act_start
    if ! act_wait_ssh; then
        act_stop
        echo_error "Cannot reach the SSH ramdisk on 127.0.0.1:2222"
        echo_code "Create and boot the ramdisk first:"
        echo_code "./sshrd.sh <ramdisk version>   then   ./sshrd.sh boot"
        return 1
    fi
    if ! act_ssh "test -e /mnt2/tmp" > /dev/null 2>&1; then
        echo_text "Mounting device filesystems"
        act_ssh "/usr/bin/mount_filesystems" > /dev/null 2>&1 || true
        sleep 1
    fi
    if ! act_ssh "test -d /mnt2/containers/Data/System" > /dev/null 2>&1; then
        act_stop
        echo_error "The data volume is not mounted (/mnt2/containers/Data/System is missing)"
        echo_code "Mount it inside the ramdisk:  /usr/bin/mount_filesystems"
        echo_code "On iOS 10.0-10.2.1:            /usr/bin/mount_filesystems  (or the manual mount_hfs pair)"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
#  device queries
# -----------------------------------------------------------------------------
act_ramdisk_version() {
    local v
    v=$(act_ssh "/usr/bin/sw_vers -productVersion" 2>/dev/null | tr -d '\r' | head -1)
    printf '%s' "$v"
}

act_ramdisk_major() {
    local v
    v=$(act_ramdisk_version)
    printf '%s' "${v%%.*}"
}

# Print a remote plist as XML1 so the host can parse it with grep/sed.
# iOS 11's /usr/bin/plutil has no -p (it prints nothing), but -convert exists all
# the way from iOS 7 to current, so copy to /mnt2/tmp, convert, cat back.
act_plist_xml() {
    act_ssh "rm -f /mnt2/tmp/act_read.plist
cp '$1' /mnt2/tmp/act_read.plist 2>/dev/null || exit 1
/usr/bin/plutil -convert xml1 /mnt2/tmp/act_read.plist > /dev/null 2>&1 || exit 1
cat /mnt2/tmp/act_read.plist
rm -f /mnt2/tmp/act_read.plist" 2>/dev/null
}

# value of a (string) key in a remote plist
act_plist_get() {
    act_plist_xml "$1" \
        | tr -d '\r' \
        | grep -A1 "<key>$2</key>" \
        | grep -o "<string>[^<]*</string>" \
        | head -1 \
        | sed 's/<[^>]*>//g' || true
}

# a writable temp directory on the host (TMPDIR on macOS, /tmp elsewhere)
act_tmpdir() {
    local d
    d="${TMPDIR:-/tmp}"
    if [ ! -d "$d" ]; then
        d="."
    fi
    printf '%s' "$d"
}

# -----------------------------------------------------------------------------
#  IC-Info.sisv from an activation record (the AR2SISV trick)
# -----------------------------------------------------------------------------
#  The record embeds FairPlayKeyData: a base64 container that carries the device
#  FairPlay blob between "R-" and "-E".  Decoding it gives back IC-Info.sisv,
#  which is what iServices need - useful when the real one cannot be downloaded.
#  Same logic as j4nf4b3l/AR2SISV and overcast302/pyAR2SISV, in plain shell.
# -----------------------------------------------------------------------------
act_b64d() {
    if printf '' | base64 -D > /dev/null 2>&1; then
        base64 -D
    else
        base64 -d
    fi
}

# raw value of a plist key on stdout (data values come out base64-encoded)
act_plist_raw() {
    if command -v plutil > /dev/null 2>&1; then
        plutil -extract "$2" raw -o - "$1" 2>/dev/null
    elif command -v python3 > /dev/null 2>&1; then
        python3 -c 'import base64, plistlib, sys
v = plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]]
if isinstance(v, (bytes, bytearray)):
    print(base64.b64encode(bytes(v)).decode())
else:
    print(v)' "$1" "$2" 2>/dev/null
    fi
}

# act_sisv_from_record <activation_record.plist> <output IC-Info.sisv>
act_sisv_from_record() {
    local fpd text inner
    if [ ! -f "$1" ]; then
        return 1
    fi
    fpd=$(act_plist_raw "$1" FairPlayKeyData)
    if [ -z "$fpd" ]; then
        return 1
    fi
    text=$(printf '%s' "$fpd" | act_b64d 2>/dev/null | tr -d '\n')
    case "$text" in
        *R-*-E*) : ;;
        *) return 1 ;;
    esac
    inner=$(printf '%s' "$text" | sed -n 's/.*R-\([A-Za-z0-9+/=]*\)-E.*/\1/p')
    if [ -z "$inner" ]; then
        return 1
    fi
    printf '%s' "$inner" | act_b64d > "$2" 2>/dev/null || return 1
    if [ ! -s "$2" ]; then
        return 1
    fi
    return 0
}

# Parse a local plist and print "key => value" lines.
# macOS plutil is used when present, python plistlib otherwise (Linux).
act_plist_local() {
    local py
    if [ ! -f "$1" ]; then
        return 1
    fi
    if command -v plutil > /dev/null 2>&1; then
        plutil -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//'
        return 0
    fi
    py=""
    if command -v python3 > /dev/null 2>&1; then
        py=python3
    elif command -v python > /dev/null 2>&1; then
        py=python
    fi
    if [ -n "$py" ]; then
        "$py" -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
for k in d:
    print("%s => %s" % (k, d[k]))' "$1" 2>/dev/null
    fi
    return 0
}

# Fallback parser: pull the plist to the host and parse it there.
# Used when the device plutil cannot convert it (macOS plutil is a superset).
act_plist_host_dump() {
    local tmp
    tmp="$(act_tmpdir)/act_plist_$$.plist"
    if ! act_scp -p "root@127.0.0.1:$1" "$tmp" > /dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    act_plist_local "$tmp"
    rm -f "$tmp"
    return 0
}

# value of a key in /mnt1/System/Library/CoreServices/SystemVersion.plist
act_sysversion() {
    act_plist_get /mnt1/System/Library/CoreServices/SystemVersion.plist "$1"
}

# iOS version of the installed system.  On some ramdisks (iOS 11 in particular)
# the system volume is not mounted yet or plutil cannot read the file, so fall
# back to the ramdisk version - the script requires it to match the device.
act_ios_version() {
    local v
    v=$(act_sysversion ProductVersion)
    if [ -z "$v" ]; then
        v=$(act_ramdisk_version)
    fi
    printf '%s' "$v"
}

act_ios_build() {
    act_sysversion ProductBuildVersion
}

act_serial() {
    local ioreg major v
    v=""
    major=$(act_ramdisk_major)
    if [ -z "$major" ]; then
        major=0
    fi
    if [ "$major" -ge 15 ]; then
        ioreg="/mnt1/usr/sbin/ioreg"
    else
        ioreg="/usr/sbin/ioreg"
    fi
    v=$(act_ssh "$ioreg -l" 2>/dev/null \
        | grep IOPlatformSerialNumber \
        | sed 's/.*IOPlatformSerialNumber" = "\(.*\)"/\1/' \
        | cut -d '"' -f4 \
        | head -1)
    printf '%s' "$v"
}

# Print the System-data container of mobileactivationd, or nothing.
# Primary method: MCMMetadataIdentifier in the container metadata plist.
# Fallback:        the container that owns Library/internal or activation_records.
act_mad_container() {
    local d
    d=$(act_ssh 'for c in /mnt2/containers/Data/System/*; do
        [ -d "$c" ] || continue
        m="$c/.com.apple.mobile_container_manager.metadata.plist"
        [ -f "$m" ] || continue
        if /usr/bin/plutil -p "$m" 2>/dev/null | grep -q com.apple.mobileactivationd; then
            echo "$c"
            break
        fi
        if grep -a -q com.apple.mobileactivationd "$m" 2>/dev/null; then
            echo "$c"
            break
        fi
    done' 2>/dev/null | tr -d '\r' | head -1)
    if [ -z "$d" ]; then
        d=$(act_ssh 'for c in /mnt2/containers/Data/System/*; do
            if [ -d "$c/Library/internal" ] || [ -d "$c/Library/activation_records" ]; then
                echo "$c"
                break
            fi
        done' 2>/dev/null | tr -d '\r' | head -1)
    fi
    case "$d" in
        */containers/Data/System/*) printf '%s' "$d" ;;
        *) printf '' ;;
    esac
}

act_manifest_get() {
    if [ -f "$1" ]; then
        grep "^$2: " "$1" 2>/dev/null | head -1 | sed "s/^$2: //"
    fi
}

# -----------------------------------------------------------------------------
#  small output / hashing helpers
# -----------------------------------------------------------------------------
act_check_file() {
    # $1 = local path, $2 = human label, $3 = 1 if required
    if [ -s "$1" ]; then
        echo "  [ok]    $2"
    elif [ -e "$1" ]; then
        echo "  [empty] $2"
        if [ "$3" = "1" ]; then
            ACT_MISSING=$((ACT_MISSING + 1))
        fi
    else
        echo "  [MISS]  $2"
        if [ "$3" = "1" ]; then
            ACT_MISSING=$((ACT_MISSING + 1))
        fi
    fi
}

act_check_dir() {
    # $1 = local path, $2 = human label, $3 = 1 if required
    if [ -d "$1" ]; then
        echo "  [ok]    $2"
    else
        echo "  [MISS]  $2"
        if [ "$3" = "1" ]; then
            ACT_MISSING=$((ACT_MISSING + 1))
        fi
    fi
}

act_hash_file() {
    # $1 = file, $2 = output file (appends)
    if [ ! -f "$1" ]; then
        return 0
    fi
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" >> "$2" 2>/dev/null || true
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$1" >> "$2" 2>/dev/null || true
    fi
    return 0
}

act_du() {
    # best-effort human readable size of a directory
    du -sh "$1" 2>/dev/null | cut -f1
}

# =============================================================================
#  --activation-info : what is on the device right now
# =============================================================================
act_info() {
    local serial mad
    if ! act_prepare; then
        act_die "The SSH ramdisk is not ready"
    fi
    serial=$(act_serial)
    mad=$(act_mad_container)

    echo_text "Device serial       : ${serial:-unknown}"
    echo_text "iOS on device       : $(act_ios_version) ($(act_ios_build))"
    echo_text "SSH ramdisk version : $(act_ramdisk_version)"
    if [ -n "$mad" ]; then
        echo_text "mobileactivationd   : $mad"
    else
        echo_warn "mobileactivationd container not found (data_ark.plist cannot be read)"
    fi

    echo_text "Activation files on the device (present does not mean readable):"
    act_ssh 'for p in \
        /mnt2/containers/Data/System/*/Library/internal/data_ark.plist \
        /mnt2/containers/Data/System/*/Library/activation_records/*_record.plist \
        /mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv \
        /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist \
        /mnt2/root/Library/Lockdown/data_ark.plist \
        /mnt2/root/Library/Lockdown/pair_records \
        /mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist ; do
        for f in $p; do
            [ -e "$f" ] || continue
            if [ -d "$f" ]; then
                echo "  present, directory   $f"
            elif cat "$f" > /dev/null 2>&1; then
                echo "  present, readable    $f"
            else
                echo "  present, UNREADABLE  $f"
            fi
        done
    done' 2>/dev/null || true

    if [ -n "$mad" ]; then
        echo_text "data_ark.plist summary:"
        ark=$(act_plist_xml "$mad/Library/internal/data_ark.plist" \
            | tr -d '\r' \
            | grep -A1 -E '<key>-?(ActivationState|ProductVersion|BuildVersion|DeviceName|ActivationRandomness)</key>' \
            | grep -v '^--$' \
            | sed 's/^[[:space:]]*//')
        if [ -z "$ark" ]; then
            ark=$(act_plist_host_dump "$mad/Library/internal/data_ark.plist" 2>/dev/null \
                | grep -E 'ActivationState|ProductVersion|BuildVersion|DeviceName|ActivationRandomness' \
                | sed 's/^[[:space:]]*//')
            if [ -n "$ark" ]; then
                echo_text "(parsed on the Mac - the device plutil could not convert it)"
            fi
        fi
        if [ -n "$ark" ]; then
            printf '%s\n' "$ark"
        else
            echo_warn "Could not parse data_ark.plist as XML - running a raw diagnostic:"
            act_ssh "ls -l '$mad/Library/internal/data_ark.plist'
rm -f /mnt2/tmp/act_read.plist
cp '$mad/Library/internal/data_ark.plist' /mnt2/tmp/act_read.plist && echo '  step copy  : ok' || echo '  step copy  : FAILED'
/usr/bin/plutil -convert xml1 /mnt2/tmp/act_read.plist && echo '  step plutil: ok' || echo '  step plutil: FAILED'
echo -n '  first bytes: '
head -c 8 /mnt2/tmp/act_read.plist 2>/dev/null | od -An -c 2>/dev/null || echo '(none)'
rm -f /mnt2/tmp/act_read.plist" 2>&1 | sed 's/^/  /'
        fi
    fi

    echo_text "FairPlay tokens (IC-Info.sisv / SIC-Info.sisv are the device/store tokens):"
    act_ssh "ls -l /mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes 2>/dev/null" 2>/dev/null || true
    act_done
}

# =============================================================================
#  --check-payload : is the FATE boot banner really inside sshtars/ssh.tar.gz ?
# -----------------------------------------------------------------------------
#  The banner lives in the ramdisk payload, not in the device filesystem, so a
#  stale build silently keeps the old dropbear.  This inspects the tarball the
#  build actually consumes (no device needed).
# =============================================================================
act_check_payload() {
    local n
    fate_banner
    if [ ! -f sshtars/ssh.tar.gz ]; then
        echo_error "sshtars/ssh.tar.gz not found - run this from the SSHRD_Script folder"
        exit 1
    fi
    echo_text "Ramdisk payload: sshtars/ssh.tar.gz ($(act_du sshtars/ssh.tar.gz 2>/dev/null))"
    if tar -xzOf sshtars/ssh.tar.gz usr/local/bin/dropbear 2>/dev/null | head -1 | grep -q '^#!/bin/sh'; then
        n=$(tar -xzOf sshtars/ssh.tar.gz usr/local/bin/dropbear 2>/dev/null | grep -c 'FATE_BOOT' || true)
        echo "  usr/local/bin/dropbear : wrapper script, banner blocks: ${n}"
    else
        echo_warn "usr/local/bin/dropbear : stock binary - the boot banner will NOT appear"
    fi
    if tar -tzf sshtars/ssh.tar.gz 2>/dev/null | grep -qx 'usr/local/bin/dropbear.real'; then
        echo "  usr/local/bin/dropbear.real : present (the wrapper execs this)"
    else
        echo_warn "usr/local/bin/dropbear.real : MISSING - wrapper would fall back to dropbear.orig"
    fi
    echo_text "An already-built sshramdisk/ or work/ramdisk.dmg keeps the old payload - delete both and rebuild"
    exit 0
}

# =============================================================================
#  --make-sisv : rebuild IC-Info.sisv from the activation record in the dump
# -----------------------------------------------------------------------------
#  Host-side only (no device): reads the newest dumped activation_record.plist,
#  extracts FairPlayKeyData and writes a fresh IC-Info.sisv next to the dumped
#  FairPlay files, so the next restore uploads a valid one.
# =============================================================================
act_make_sisv() {
    local record base out
    fate_banner
    record=$(ls -t "$ACT_ROOT"/*/full/mad-Library/activation_records/activation_record.plist 2>/dev/null | head -1)
    if [ -z "$record" ]; then
        echo_error "No activation_record.plist found under $ACT_ROOT/*/full/"
        echo_code "Run ./sshrd.sh --backup-activation-full first"
        exit 1
    fi
    base=$(dirname "$(dirname "$(dirname "$record")")")
    out="$base/FairPlay/iTunes_Control/iTunes/IC-Info.sisv"
    mkdir -p "$base/FairPlay/iTunes_Control/iTunes"
    echo_text "Record : $record"
    echo_text "Output : $out"
    if act_sisv_from_record "$record" "$out"; then
        echo_text "IC-Info.sisv rebuilt: $(wc -c < "$out" | tr -d ' ') bytes (a genuine one is 1140)"
    else
        echo_error "Could not rebuild IC-Info.sisv - no usable FairPlayKeyData in that record"
        rm -f "$out"
        exit 1
    fi
    exit 0
}

# =============================================================================
#  --owner-phone / --owner-email / --contact-info
# -----------------------------------------------------------------------------
#  Read-only lookups, the same class of data the device itself shows in
#  Settings: the phone/SIM identifiers from CommCenter and the activation
#  record, and the account e-mail addresses stored in the account files.
#  Nothing is written to the device.  Use it on a device you own or are
#  authorised to service.
# =============================================================================
act_phone_report() {
    local tmp mad
    echo_text "Phone / SIM identifiers (CommCenter)"
    tmp="$(act_tmpdir)/act_cc_$$.plist"
    if act_scp -p root@127.0.0.1:/mnt2/wireless/Library/Preferences/com.apple.commcenter.plist "$tmp" > /dev/null 2>&1; then
        act_plist_local "$tmp" \
            | grep -E '(PhoneNumber|SIMPhoneNumber|NetworkPhoneNumber|CDMANetworkPhoneNumber|ICCID|IMSI|IMEI|MEID|CarrierName)' \
            | sed 's/^/  /' || true
        rm -f "$tmp"
    else
        echo_warn "Could not read com.apple.commcenter.plist"
    fi

    mad=$(act_mad_container)
    if [ -n "$mad" ]; then
        tmp="$(act_tmpdir)/act_ar_$$.plist"
        if act_scp -p "root@127.0.0.1:$mad/Library/activation_records/activation_record.plist" "$tmp" > /dev/null 2>&1; then
            echo_text "Identifiers in the activation record"
            act_plist_local "$tmp" \
                | grep -E '(PhoneNumber|ICCID|IMEI|MEID|SerialNumber|UniqueDeviceID|ProductType)' \
                | sed 's/^/  /' || true
            rm -f "$tmp"
        fi
    fi
}

act_email_report() {
    local hits
    echo_text "Account e-mail addresses stored on the device (read-only search)"
    hits=$(act_ssh 'for f in \
        /mnt2/mobile/Library/Accounts/Accounts3.sqlite \
        /mnt2/mobile/Library/Accounts/Accounts3.sqlite-wal \
        /mnt2/mobile/Library/Preferences/MobileMeAccounts.plist \
        /mnt2/mobile/Library/Preferences/com.apple.MobileMeAccounts.plist \
        /mnt2/mobile/Library/Preferences/com.apple.accountsd.plist \
        /mnt2/mobile/Library/Preferences/com.apple.identityservicesd.plist \
        /mnt2/mobile/Library/Preferences/com.apple.mobilemail.plist \
        /mnt2/mobile/Library/Preferences/com.apple.mail.plist \
        /mnt2/wireless/Library/Preferences/com.apple.commcenter.plist \
        /mnt2/containers/Data/System/*/Library/activation_records/*_record.plist ; do
        for g in $f; do
            [ -f "$g" ] || continue
            grep -a -o -E "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" "$g" 2>/dev/null
        done
    done' 2>/dev/null | tr -d '\r' | grep -E '@' | sort -u | head -50)
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | sed 's/^/  /'
    else
        echo "  (none found in the account files)"
    fi
}

act_own_phone() {
    if ! act_prepare; then
        act_die "The SSH ramdisk is not ready"
    fi
    act_phone_report
    act_done
}

act_own_email() {
    if ! act_prepare; then
        act_die "The SSH ramdisk is not ready"
    fi
    act_email_report
    act_done
}

act_contact_info() {
    if ! act_prepare; then
        act_die "The SSH ramdisk is not ready"
    fi
    act_phone_report
    act_email_report
    act_done
}

# =============================================================================
#  --backup-activation-full
# =============================================================================
act_backup_full() {
    local serial mad iosver iosbuild out f records
    echo_text "Complete activation backup (records + data_ark.plist + FairPlay + CommCenter + Lockdown)"

    if ! act_prepare; then
        act_die "The SSH ramdisk is not ready"
    fi

    serial=$(act_serial)
    if [ -z "$serial" ]; then
        act_die "Could not read the device serial number (IOPlatformSerialNumber)"
    fi
    mad=$(act_mad_container)
    iosver=$(act_ios_version)
    iosbuild=$(act_ios_build)
    out="$ACT_ROOT/$serial/full"

    echo_text "Serial: ${serial}"
    echo_text "iOS   : ${iosver:-unknown} (${iosbuild:-unknown})"
    if [ -n "$mad" ]; then
        echo_text "Container: ${mad}"
    else
        echo_warn "mobileactivationd container not found - data_ark.plist will be missing from this dump"
    fi

    if [ -d "$out" ]; then
        echo_warn "A full dump already exists at $out"
        pause
        rm -rf "$out"
    fi
    mkdir -p "$out"

    # --- 1. mobileactivationd system container --------------------------------
    if [ -n "$mad" ]; then
        echo_text "Saving mobileactivationd container Library (data_ark.plist + activation records)"
        if ! act_scp -rp "root@127.0.0.1:$mad/Library" "$out/mad-Library" > /dev/null 2>&1; then
            echo_warn "Whole-Library copy failed, retrying item by item"
            rm -rf "$out/mad-Library"
            mkdir -p "$out/mad-Library"
            act_scp -rp "root@127.0.0.1:$mad/Library/internal" "$out/mad-Library/" > /dev/null 2>&1 || true
            act_scp -rp "root@127.0.0.1:$mad/Library/activation_records" "$out/mad-Library/" > /dev/null 2>&1 || true
            act_scp -rp "root@127.0.0.1:$mad/Library/Preferences" "$out/mad-Library/" > /dev/null 2>&1 || true
        fi
    fi

    # --- 2. FairPlay identity -------------------------------------------------
    echo_text "Saving FairPlay identity (/private/var/mobile/Library/FairPlay)"
    if act_ssh "test -d /mnt2/mobile/Library/FairPlay" > /dev/null 2>&1; then
        rm -rf "$out/FairPlay"
        if ! act_scp -rp root@127.0.0.1:/mnt2/mobile/Library/FairPlay "$out/FairPlay" > /dev/null 2>&1; then
            echo_warn "FairPlay copy failed - see the IC-Info.sisv note below"
            rm -rf "$out/FairPlay"
        fi
    else
        echo_warn "No FairPlay directory on the device"
    fi

    # --- 2b. rebuild IC-Info.sisv from the record when the device will not give it
    if [ ! -s "$out/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" ]; then
        rec="$out/mad-Library/activation_records/activation_record.plist"
        if [ -f "$rec" ]; then
            mkdir -p "$out/FairPlay/iTunes_Control/iTunes"
            if act_sisv_from_record "$rec" "$out/FairPlay/iTunes_Control/iTunes/IC-Info.sisv"; then
                echo_text "IC-Info.sisv was missing - rebuilt it from FairPlayKeyData in the activation record"
            else
                echo_warn "IC-Info.sisv missing and could not be rebuilt from the record"
            fi
        fi
    fi

    # --- 3. CommCenter device specific plist ----------------------------------    echo_text "Saving CommCenter activation data"
    if act_ssh "test -f /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist" > /dev/null 2>&1; then
        act_scp -p root@127.0.0.1:/mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist "$out/" > /dev/null 2>&1 || \
            echo_warn "Could not copy com.apple.commcenter.device_specific_nobackup.plist"
    else
        echo_warn "com.apple.commcenter.device_specific_nobackup.plist not found (Wi-Fi-only device?)"
    fi

    # --- 4. Lockdown ----------------------------------------------------------
    echo_text "Saving Lockdown (pair records)"
    if act_ssh "test -d /mnt2/root/Library/Lockdown" > /dev/null 2>&1; then
        rm -rf "$out/Lockdown"
        act_scp -rp root@127.0.0.1:/mnt2/root/Library/Lockdown "$out/Lockdown" > /dev/null 2>&1 || \
            echo_warn "Could not copy /private/var/root/Library/Lockdown"
    fi

    # --- 5. Setup Assistant state --------------------------------------------
    if act_ssh "test -f /mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist" > /dev/null 2>&1; then
        echo_text "Saving Setup Assistant state"
        act_scp -p root@127.0.0.1:/mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist "$out/" > /dev/null 2>&1 || \
            echo_warn "Could not copy com.apple.purplebuddy.plist"
    fi

    # --- 6. legacy iOS 7-9 layout, best effort --------------------------------
    if act_ssh "test -d /mnt2/mobile/Library/mad/activation_records" > /dev/null 2>&1; then
        echo_text "Saving legacy iOS 7-9 activation_records"
        mkdir -p "$out/legacy"
        act_scp -rp root@127.0.0.1:/mnt2/mobile/Library/mad/activation_records "$out/legacy/mad_activation_records" > /dev/null 2>&1 || true
    fi

    # --- compat copies for the upstream --restore-activation command ----------
    mkdir -p "$ACT_ROOT/$serial"
    if [ -d "$out/mad-Library/activation_records" ]; then
        for f in "$out/mad-Library/activation_records"/*_record.plist; do
            if [ -f "$f" ]; then
                cp -f "$f" "$ACT_ROOT/$serial/" 2>/dev/null || true
            fi
        done
    fi
    if [ -f "$out/mad-Library/internal/data_ark.plist" ]; then
        cp -f "$out/mad-Library/internal/data_ark.plist" "$ACT_ROOT/$serial/data_ark.plist" 2>/dev/null || true
    fi
    if [ -f "$out/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" ]; then
        cp -f "$out/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" "$ACT_ROOT/$serial/IC-Info.sisv" 2>/dev/null || true
    fi
    if [ -f "$out/com.apple.commcenter.device_specific_nobackup.plist" ]; then
        cp -f "$out/com.apple.commcenter.device_specific_nobackup.plist" "$ACT_ROOT/$serial/" 2>/dev/null || true
    fi

    # --- manifest + checksums -------------------------------------------------
    {
        echo "SSHRD_Script complete activation dump"
        echo "tool: activation.sh $ACT_VERSION"
        echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "host: $(uname -s) $(uname -m)"
        echo "serial: $serial"
        echo "ios: ${iosver:-unknown} (${iosbuild:-unknown})"
        echo "ramdisk: $(act_ramdisk_version)"
        echo "mad_container: ${mad:-unknown}"
        echo "fairplay_entries: $(ls -1R "$out/FairPlay" 2>/dev/null | wc -l | tr -d ' ')"
        echo "contents:"
        ls -1 "$out" 2>/dev/null | sed 's/^/  /'
    } > "$out/manifest.txt"

    : > "$out/SHA256SUMS"
    act_hash_file "$out/mad-Library/internal/data_ark.plist" "$out/SHA256SUMS"
    act_hash_file "$out/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" "$out/SHA256SUMS"
    act_hash_file "$out/FairPlay/iTunes_Control/iTunes/SIC-Info.sisv" "$out/SHA256SUMS"
    act_hash_file "$out/com.apple.commcenter.device_specific_nobackup.plist" "$out/SHA256SUMS"
    act_hash_file "$out/Lockdown/data_ark.plist" "$out/SHA256SUMS"
    if [ -d "$out/mad-Library/activation_records" ]; then
        for f in "$out/mad-Library/activation_records"/*_record.plist; do
            if [ -f "$f" ]; then
                act_hash_file "$f" "$out/SHA256SUMS"
            fi
        done
    fi

    # --- verification ---------------------------------------------------------
    records=0
    if [ -d "$out/mad-Library/activation_records" ]; then
        for f in "$out/mad-Library/activation_records"/*_record.plist; do
            if [ -f "$f" ]; then
                records=$((records + 1))
            fi
        done
    fi
    fairplay=0
    if [ -d "$out/FairPlay/iTunes_Control/iTunes" ]; then
        for f in "$out/FairPlay/iTunes_Control/iTunes"/*; do
            if [ -f "$f" ]; then
                fairplay=$((fairplay + 1))
            fi
        done
    fi

    echo_text "Verifying dump at $out"
    ACT_MISSING=0
    if [ -s "$out/mad-Library/internal/data_ark.plist" ] || [ -s "$out/Lockdown/data_ark.plist" ]; then
        echo "  [ok]    data_ark.plist (mobileactivationd data ark)"
    else
        echo "  [MISS]  data_ark.plist (mobileactivationd data ark)"
        ACT_MISSING=$((ACT_MISSING + 1))
    fi
    act_check_file "$out/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" "IC-Info.sisv (FairPlay device token)" 1
    act_check_file "$out/FairPlay/iTunes_Control/iTunes/SIC-Info.sisv" "SIC-Info.sisv (FairPlay store token)" 0
    act_check_file "$out/com.apple.commcenter.device_specific_nobackup.plist" "CommCenter device-specific plist" 1
    echo "  [info]  activation record(s) found: $records"
    echo "  [info]  FairPlay token files saved: $fairplay"
    if [ -f "$out/mad-Library/internal/data_ark.plist" ]; then
        act_plist_local "$out/mad-Library/internal/data_ark.plist" \
            | grep -E 'ActivationState|BuildVersion|ProductVersion' \
            | sed 's/^/  [ark]   /' || true
    fi
    if [ "$records" -eq 0 ]; then
        ACT_MISSING=$((ACT_MISSING + 1))
    fi
    if [ "$fairplay" -eq 0 ]; then
        ACT_MISSING=$((ACT_MISSING + 1))
    fi
    act_check_dir "$out/Lockdown" "Lockdown (pair records)" 0
    act_check_file "$out/com.apple.purplebuddy.plist" "Setup Assistant state" 0

    echo_text "Dump size: $(act_du "$out")"
    echo_text "Saved to: $out"

    if [ "$ACT_MISSING" -gt 0 ]; then
        echo_error "Dump is incomplete ($ACT_MISSING required item(s) missing)"
        echo_code "If only IC-Info.sisv is missing, it is currently undownloadable by design:"
        echo_code "  rm /mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv"
        echo_code "  reboot to the lock screen (this regenerates a downloadable IC-Info.sisv),"
        echo_code "  boot the ramdisk again and re-run --backup-activation-full"
        act_stop
        exit 1
    fi

    echo_text "Complete activation state saved"
    act_done
}

# =============================================================================
#  --restore-activation-full
# =============================================================================
act_restore_full() {
    local serial mad src dumpserial
    echo_text "Restoring complete activation state"

    if ! act_prepare; then
        act_die "The SSH ramdisk is not ready"
    fi

    serial=$(act_serial)
    if [ -z "$serial" ]; then
        act_die "Could not read the device serial number"
    fi
    src="$ACT_ROOT/$serial/full"
    if [ ! -d "$src" ]; then
        echo_error "No full dump for serial $serial"
        echo_code "Expected: $src"
        echo_code "Create it with: ./sshrd.sh --backup-activation-full"
        act_die "Nothing to restore"
    fi

    dumpserial=$(act_manifest_get "$src/manifest.txt" serial)
    if [ -n "$dumpserial" ] && [ "$dumpserial" != "$serial" ]; then
        echo_warn "This dump was taken from serial $dumpserial, but the device reports $serial"
        pause
    fi

    if [ ! -f "$src/mad-Library/internal/data_ark.plist" ]; then
        echo_warn "The dump has no data_ark.plist - only the legacy 3-file set will be restored"
    fi

    echo_warn "This overwrites the activation records, data_ark.plist, FairPlay identity and CommCenter data on the device"
    echo_warn "Keep the dump: an erase wipes the device again and you will need it"
    pause

    mad=$(act_mad_container)
    if [ -z "$mad" ]; then
        echo_error "Cannot find the mobileactivationd container on the device"
        echo_code "Boot the device once (to the Hello / Setup screen) so mobileactivationd creates it,"
        echo_code "then boot the ramdisk again and re-run --restore-activation-full"
        act_die "Restore aborted"
    fi

    echo_text "Uploading activation files one by one"
    # Recursive scp (scp -r dir) is not reliable on every ramdisk, so the staging
    # tree is recreated explicitly and every file is sent individually.
    if ! act_ssh "rm -rf /mnt2/tmp/act_restore
mkdir -p /mnt2/tmp/act_restore/mad-Library/internal
mkdir -p /mnt2/tmp/act_restore/mad-Library/activation_records
mkdir -p /mnt2/tmp/act_restore/mad-Library/Preferences
mkdir -p /mnt2/tmp/act_restore/FairPlay/iTunes_Control/iTunes
mkdir -p /mnt2/tmp/act_restore/Lockdown" > /dev/null 2>&1; then
        act_die "Cannot create /mnt2/tmp/act_restore on the device"
    fi

    for f in "$src/mad-Library/internal"/*; do
        if [ -f "$f" ]; then
            act_scp -p "$f" "root@127.0.0.1:/mnt2/tmp/act_restore/mad-Library/internal/" > /dev/null 2>&1 || \
                act_die "Failed to upload $(basename "$f")"
        fi
    done
    for f in "$src/mad-Library/activation_records"/*; do
        if [ -f "$f" ]; then
            act_scp -p "$f" "root@127.0.0.1:/mnt2/tmp/act_restore/mad-Library/activation_records/" > /dev/null 2>&1 || \
                act_die "Failed to upload $(basename "$f")"
        fi
    done
    for f in "$src/mad-Library/Preferences"/*; do
        if [ -f "$f" ]; then
            act_scp -p "$f" "root@127.0.0.1:/mnt2/tmp/act_restore/mad-Library/Preferences/" > /dev/null 2>&1 || true
        fi
    done
    if [ -d "$src/FairPlay/iTunes_Control/iTunes" ]; then
        for f in "$src/FairPlay/iTunes_Control/iTunes"/*; do
            if [ -f "$f" ]; then
                act_scp -p "$f" "root@127.0.0.1:/mnt2/tmp/act_restore/FairPlay/iTunes_Control/iTunes/" > /dev/null 2>&1 || \
                    echo_warn "Failed to upload $(basename "$f") (FairPlay)"
            fi
        done
    fi
    if [ -f "$src/Lockdown/data_ark.plist" ]; then
        act_scp -p "$src/Lockdown/data_ark.plist" "root@127.0.0.1:/mnt2/tmp/act_restore/Lockdown/data_ark.plist" > /dev/null 2>&1 || \
            echo_warn "Failed to upload Lockdown/data_ark.plist"
    fi
    if [ -d "$src/Lockdown/pair_records" ]; then
        act_ssh "mkdir -p /mnt2/tmp/act_restore/Lockdown/pair_records" > /dev/null 2>&1 || true
        for f in "$src/Lockdown/pair_records"/*; do
            if [ -f "$f" ]; then
                act_scp -p "$f" "root@127.0.0.1:/mnt2/tmp/act_restore/Lockdown/pair_records/" > /dev/null 2>&1 || true
            fi
        done
    fi
    for f in com.apple.commcenter.device_specific_nobackup.plist com.apple.purplebuddy.plist; do
        if [ -f "$src/$f" ]; then
            act_scp -p "$src/$f" "root@127.0.0.1:/mnt2/tmp/act_restore/" > /dev/null 2>&1 || \
                echo_warn "Failed to upload $f"
        fi
    done

    echo_text "Installing activation state"
    if ! act_ssh "MAD='$mad' sh -s" <<'EOS'
set -e
TMP=/mnt2/tmp/act_restore
LIB="$MAD/Library"

# 1) data_ark.plist -- mobileactivationd's activation data ark
if [ -f "$TMP/mad-Library/internal/data_ark.plist" ]; then
    mkdir -p "$LIB/internal"
    if ! cp -f "$TMP/mad-Library/internal/data_ark.plist" "$LIB/internal/data_ark.plist" 2>/dev/null; then
        echo "   internal/ is write-protected - swapping the directory"
        rm -rf /mnt2/tmp/internal.new
        mkdir -p /mnt2/tmp/internal.new
        cp -f "$TMP/mad-Library/internal/data_ark.plist" /mnt2/tmp/internal.new/data_ark.plist
        rm -rf "$LIB/internal" 2>/dev/null || true
        if [ -e "$LIB/internal" ]; then
            echo "   ERROR: could not replace $LIB/internal"
        else
            mv /mnt2/tmp/internal.new "$LIB/internal"
            chmod 755 "$LIB/internal" 2>/dev/null || true
        fi
    fi
    chmod 644 "$LIB/internal/data_ark.plist" 2>/dev/null || true
    echo "   data_ark.plist              -> $LIB/internal/data_ark.plist"
else
    echo "   WARN: no data_ark.plist in the dump"
fi

# 2) activation records
#    The directory itself is Data Vault protected on some versions: creating a
#    file inside it returns EPERM, but replacing the directory (rename) works.
if [ -d "$TMP/mad-Library/activation_records" ]; then
    AR_SRC="$TMP/mad-Library/activation_records"
    mkdir -p "$LIB/activation_records" 2>/dev/null || true
    AR_OK=1
    for f in "$AR_SRC"/*; do
        [ -f "$f" ] || continue
        if ! cp -f "$f" "$LIB/activation_records/" 2>/dev/null; then
            AR_OK=0
            break
        fi
    done
    if [ "$AR_OK" = "0" ]; then
        echo "   activation_records/ is write-protected - swapping the directory"
        rm -rf /mnt2/tmp/act_ar
        mkdir -p /mnt2/tmp/act_ar
        for f in "$AR_SRC"/*; do
            [ -f "$f" ] || continue
            cp -f "$f" /mnt2/tmp/act_ar/
        done
        rm -rf "$LIB/activation_records" 2>/dev/null || true
        if [ -e "$LIB/activation_records" ]; then
            echo "   ERROR: could not replace $LIB/activation_records"
        else
            mv /mnt2/tmp/act_ar "$LIB/activation_records"
            chmod 755 "$LIB/activation_records" 2>/dev/null || true
        fi
    fi
    for f in "$LIB/activation_records"/*_record.plist; do
        if [ -f "$f" ]; then
            chmod 666 "$f" || true
            /usr/sbin/chown mobile:nobody "$f" || true
        fi
    done
    echo "   activation_record.plist     -> $LIB/activation_records/"
fi

# 3) mobileactivationd preferences (small, harmless)
if [ -d "$TMP/mad-Library/Preferences" ]; then
    mkdir -p "$LIB/Preferences"
    for f in "$TMP/mad-Library/Preferences"/*; do
        if [ -f "$f" ]; then
            cp -f "$f" "$LIB/Preferences/"
        fi
    done
    echo "   mobileactivationd prefs     -> $LIB/Preferences/"
fi

# 4) FairPlay identity (whole tree)
if [ -d "$TMP/FairPlay" ]; then
    rm -rf /mnt2/mobile/Library/FairPlay
    if ! mv "$TMP/FairPlay" /mnt2/mobile/Library/FairPlay 2>/dev/null; then
        # iOS 17+ sometimes refuses a direct rename into mobile/Library;
        # staging through the Media partition (not data-vaulted) works.
        mkdir -p /mnt2/mobile/Media/Downloads
        rm -rf /mnt2/mobile/Media/Downloads/FairPlay
        cp -R "$TMP/FairPlay" /mnt2/mobile/Media/Downloads/FairPlay 2>/dev/null || true
        if [ -d /mnt2/mobile/Media/Downloads/FairPlay ]; then
            if ! mv /mnt2/mobile/Media/Downloads/FairPlay /mnt2/mobile/Library/FairPlay 2>/dev/null; then
                cp -R /mnt2/mobile/Media/Downloads/FairPlay /mnt2/mobile/Library/FairPlay
            fi
        else
            cp -R "$TMP/FairPlay" /mnt2/mobile/Library/FairPlay
        fi
    fi
    /usr/sbin/chown -R mobile:mobile /mnt2/mobile/Library/FairPlay || true
    chmod -R u+rwX,go+rX /mnt2/mobile/Library/FairPlay || true
    if [ -f /mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv ]; then
        chmod 664 /mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv || true
    fi
    echo "   FairPlay/                   -> /mnt2/mobile/Library/FairPlay"
fi

# 5) CommCenter activation data
if [ -f "$TMP/com.apple.commcenter.device_specific_nobackup.plist" ]; then
    mkdir -p /mnt2/wireless/Library/Preferences
    cp -f "$TMP/com.apple.commcenter.device_specific_nobackup.plist" /mnt2/wireless/Library/Preferences/
    chmod 600 /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist || true
    /usr/sbin/chown _wireless:_wireless /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist || true
    echo "   commcenter plist            -> /mnt2/wireless/Library/Preferences/"
fi

# 6) Lockdown pair records (+ legacy data ark if the dump has one)
if [ -n "$(ls -A "$TMP/Lockdown/pair_records" 2>/dev/null)" ]; then
    mkdir -p /mnt2/root/Library/Lockdown
    rm -rf /mnt2/root/Library/Lockdown/pair_records
    cp -R "$TMP/Lockdown/pair_records" /mnt2/root/Library/Lockdown/pair_records
    /usr/sbin/chown -R root:wheel /mnt2/root/Library/Lockdown/pair_records || true
    chmod 700 /mnt2/root/Library/Lockdown/pair_records || true
    echo "   pair_records/               -> /mnt2/root/Library/Lockdown/"
fi
if [ -f "$TMP/Lockdown/data_ark.plist" ]; then
    mkdir -p /mnt2/root/Library/Lockdown
    cp -f "$TMP/Lockdown/data_ark.plist" /mnt2/root/Library/Lockdown/data_ark.plist
    chmod 644 /mnt2/root/Library/Lockdown/data_ark.plist || true
    echo "   data_ark.plist (legacy)     -> /mnt2/root/Library/Lockdown/"
fi

# 7) Setup Assistant state
if [ -f "$TMP/com.apple.purplebuddy.plist" ]; then
    mkdir -p /mnt2/mobile/Library/Preferences
    cp -f "$TMP/com.apple.purplebuddy.plist" /mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist
    chmod 600 /mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist || true
    /usr/sbin/chown mobile:mobile /mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist || true
    echo "   com.apple.purplebuddy.plist -> /mnt2/mobile/Library/Preferences/"
fi

# 8) legacy iOS 7-9 records
if [ -d "$TMP/legacy/mad_activation_records" ]; then
    mkdir -p /mnt2/mobile/Library/mad/activation_records
    for f in "$TMP/legacy/mad_activation_records"/*; do
        if [ -f "$f" ]; then
            cp -f "$f" /mnt2/mobile/Library/mad/activation_records/
            chmod 666 "/mnt2/mobile/Library/mad/activation_records/$(basename "$f")" || true
            /usr/sbin/chown mobile:nobody "/mnt2/mobile/Library/mad/activation_records/$(basename "$f")" || true
        fi
    done
    echo "   legacy records              -> /mnt2/mobile/Library/mad/activation_records/"
fi

sync
echo "   sync done"
EOS
    then
        act_die "The restore script failed on the device (see the messages above)"
    fi

    echo_text "Verifying restored state"
    act_ssh "MAD='$mad' sh -s" <<'EOS' || true
for p in \
    "$MAD/Library/internal/data_ark.plist" \
    "$MAD/Library/activation_records" \
    /mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv \
    /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist \
    /mnt2/root/Library/Lockdown/pair_records ; do
    if [ -e "$p" ]; then
        echo "  restored  $p"
    else
        echo "  MISSING   $p"
    fi
done
EOS

    echo_text "Activation state restored"
    echo_code "1. Reboot:  ./sshrd.sh reboot"
    echo_code "2. If the device still asks to activate, connect it to Wi-Fi once and wait."
    echo_code "3. iServices: sign in with your Apple ID; toggle iMessage/FaceTime off and on"
    echo_code "   if they were already enabled (keychain items are not part of this dump)."
    act_done
}
