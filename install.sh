#!/bin/sh
set -eu

TARGET='/www/luci-static/resources/view/system/flash.js'
URL='https://raw.githubusercontent.com/dotywrt/AW1KU_V2/main/flash.js'

ACL_DIR='/usr/share/rpcd/acl.d'
ACL="$ACL_DIR/dotywrt-emmc-flash.json"

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
DL="/tmp/dotywrt-flash.js.$$"
TMP=""

cleanup() {
    rm -f "$DL" 2>/dev/null || true
    [ -n "${TMP:-}" ] && rm -f "$TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ ! -f "$TARGET" ]; then
    echo "ERROR: $TARGET not found"
    exit 1
fi

if ! command -v wget >/dev/null 2>&1; then
    echo "ERROR: wget not found"
    exit 1
fi

if [ ! -e /www/cgi-bin/cgi-download ] && [ ! -e /usr/libexec/cgi-io ]; then
    echo "ERROR: cgi-download/cgi-io not found."
    echo "Full block-device download cannot be enabled safely."
    exit 1
fi

echo '[1/6] Detecting storage...'
grep -E 'mmcblk[0-9]+(p[0-9]+)?$' /proc/partitions 2>/dev/null || true

echo
echo '[2/6] Downloading latest flash.js from GitHub...'
echo "URL: $URL"

rm -f "$DL"

if ! wget -O "$DL" "$URL"; then
    echo
    echo 'ERROR: Failed to download flash.js'
    exit 1
fi

if [ ! -s "$DL" ]; then
    echo 'ERROR: Downloaded flash.js is empty'
    exit 1
fi

if grep -qiE '<!DOCTYPE html|<html[ >]' "$DL" 2>/dev/null; then
    echo 'ERROR: Downloaded file looks like HTML, not flash.js'
    exit 1
fi

SIZE="$(wc -c < "$DL" 2>/dev/null || echo 0)"

case "$SIZE" in
    ''|*[!0-9]*) SIZE=0 ;;
esac

if [ "$SIZE" -lt 1000 ]; then
    echo "ERROR: Downloaded flash.js looks too small: $SIZE bytes"
    exit 1
fi

echo "Downloaded: $SIZE bytes"

echo
echo '[3/6] Backing up current LuCI flash page...'
BACKUP="$TARGET.bak.$STAMP"
cp -p "$TARGET" "$BACKUP"
echo "Backup: $BACKUP"

echo
echo '[4/6] Installing latest eMMC-aware flash.js...'

NEW="$TARGET.new.$$"
cp "$DL" "$NEW"
chmod 0644 "$NEW"
mv "$NEW" "$TARGET"

echo
echo '[5/6] Creating read-only eMMC/MTD + GPT label ACLs...'

mkdir -p "$ACL_DIR"

TMP="$ACL.tmp.$$"

{
    echo '{'
    echo '  "dotywrt-emmc-flash": {'
    echo '    "description": "DOTYWRT eMMC and MTD raw image download",'
    echo '    "read": {'
    echo '      "cgi-io": [ "download" ],'
    echo '      "file": {'

    first=1

    add_acl_path() {
        p="$1"

        [ -e "$p" ] || return 0

        if [ "$first" -eq 0 ]; then
            printf ',\n'
        fi

        printf '        "%s": [ "read" ]' "$p"
        first=0
    }

    add_acl_path '/proc/partitions'
    add_acl_path '/proc/mtd'

    for p in \
        /dev/mmcblk[0-9] \
        /dev/mmcblk[0-9]p[0-9]* \
        /dev/mtdblock[0-9]*
    do
        [ -b "$p" ] || continue
        add_acl_path "$p"
    done

    for p in /sys/class/block/mmcblk[0-9]p[0-9]*/uevent
    do
        [ -r "$p" ] || continue
        add_acl_path "$p"
    done

    printf '\n'
    echo '      }'
    echo '    }'
    echo '  }'
    echo '}'
} > "$TMP"

mv "$TMP" "$ACL"
TMP=""

chmod 0644 "$ACL"

echo
echo '[6/6] Reloading LuCI/RPC permissions and clearing cache...'

rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true

if [ -x /etc/init.d/rpcd ]; then
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
fi

sync

echo
echo '==================================================='
echo ' DOTYWRT eMMC Flash Page Update Complete'
echo '==================================================='
echo
echo "Source : $URL"
echo "Target : $TARGET"
echo "Backup : $BACKUP"
echo
echo 'Reload:'
echo 'System -> Backup / Flash Firmware'
echo 'Then press Ctrl+Shift+R'
echo
echo 'Expected:'
echo '  - FULL eMMC device (mmcblk0)'
echo '  - Individual mmcblk0pXX partitions'
echo '  - Real GPT PARTNAME labels'
echo '  - Full raw partition/device download'
echo
echo 'Downloads are READ-ONLY.'
