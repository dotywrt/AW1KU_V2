#!/bin/sh

set -eu

OUTDIR="/tmp/fw_dump"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
ZIPOUT="/tmp/fw_dump_${STAMP}.zip"
TGZOUT="/tmp/fw_dump_${STAMP}.tar.gz"

echo "=================================================="
echo " Firmware Partition Dump"
echo "=================================================="
echo

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

get_partname() {
    dev="$1"
    u="/sys/class/block/${dev##*/}/uevent"
    [ -r "$u" ] || return 0
    sed -n 's/^PARTNAME=//p' "$u" | head -n 1
}

get_expected_bytes() {
    dev="$1"
    s="/sys/class/block/${dev##*/}/size"
    [ -r "$s" ] || {
        echo 0
        return
    }
    sectors="$(cat "$s" 2>/dev/null || echo 0)"
    case "$sectors" in
        ''|*[!0-9]*) sectors=0 ;;
    esac
    echo $((sectors * 512))
}

dump_part() {
    dev="$1"
    outfile="$2"
    expected_label="$3"

    echo
    echo "--------------------------------------------------"
    echo "Device : $dev"
    echo "Output : $OUTDIR/$outfile"

    if [ ! -b "$dev" ]; then
        echo "ERROR: block device not found: $dev"
        exit 1
    fi

    actual_label="$(get_partname "$dev")"
    if [ -n "$actual_label" ]; then
        echo "GPT    : $actual_label"
        if [ "$actual_label" != "$expected_label" ]; then
            echo "ERROR: partition label mismatch!"
            echo "Expected: $expected_label"
            echo "Actual  : $actual_label"
            echo "Aborting to avoid dumping the wrong partition."
            exit 1
        fi
    else
        echo "GPT    : [label unavailable]"
    fi

    expected_bytes="$(get_expected_bytes "$dev")"
    echo "Size   : $expected_bytes bytes"

    dd if="$dev" of="$OUTDIR/$outfile" bs=1M

    actual_bytes="$(wc -c < "$OUTDIR/$outfile" | tr -d ' ')"
    echo "Dumped : $actual_bytes bytes"

    if [ "$expected_bytes" -gt 0 ] && [ "$actual_bytes" -ne "$expected_bytes" ]; then
        echo "ERROR: incomplete dump!"
        echo "Expected: $expected_bytes bytes"
        echo "Got     : $actual_bytes bytes"
        exit 1
    fi

    echo "OK: FULL partition saved."
}

dump_part /dev/mmcblk0p18 spmfw_a.img      spmfw_a
dump_part /dev/mmcblk0p19 pi_img_a.img     pi_img_a
dump_part /dev/mmcblk0p20 dpm_a.img        dpm_a
dump_part /dev/mmcblk0p21 medmcu_a.img     medmcu_a
dump_part /dev/mmcblk0p22 sspm_a.img       sspm_a
dump_part /dev/mmcblk0p23 mcupm_a.img      mcupm_a
dump_part /dev/mmcblk0p24 lk_a.img         lk_a
dump_part /dev/mmcblk0p25 tee_a.img        tee_a

dump_part /dev/mmcblk0p31 spmfw_b.img      spmfw_b
dump_part /dev/mmcblk0p32 pi_img_b.img     pi_img_b
dump_part /dev/mmcblk0p33 dpm_b.img        dpm_b
dump_part /dev/mmcblk0p34 medmcu_b.img     medmcu_b
dump_part /dev/mmcblk0p35 sspm_b.img       sspm_b
dump_part /dev/mmcblk0p36 mcupm_b.img      mcupm_b
dump_part /dev/mmcblk0p37 lk_b.img         lk_b
dump_part /dev/mmcblk0p38 tee_b.img        tee_b

dump_part /dev/mmcblk0p42 loader_ext_a.img  loader_ext_a
dump_part /dev/mmcblk0p43 loader_ext_b.img  loader_ext_b

sync

echo
echo "=================================================="
echo " Generating manifest"
echo "=================================================="

{
    echo "DOTYWRT MT6890 firmware dump"
    echo "Date: $(date 2>/dev/null || true)"
    echo
    for f in "$OUTDIR"/*; do
        [ -f "$f" ] || continue
        bytes="$(wc -c < "$f" | tr -d ' ')"
        echo "$(basename "$f")  $bytes bytes"
    done
} > "$OUTDIR/MANIFEST.txt"

if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$OUTDIR"
        sha256sum *.img > SHA256SUMS
    )
fi

echo
ls -lh "$OUTDIR"

echo
echo "=================================================="
echo " Creating archive"
echo "=================================================="

if command -v zip >/dev/null 2>&1; then
    rm -f "$ZIPOUT"
    (
        cd /tmp
        zip -r "$ZIPOUT" "$(basename "$OUTDIR")"
    )
    ARCHIVE="$ZIPOUT"
else
    echo "NOTE: 'zip' command not installed."
    echo "Creating tar.gz instead (BusyBox/OpenWrt compatible)."
    rm -f "$TGZOUT"
    tar -czf "$TGZOUT" -C /tmp "$(basename "$OUTDIR")"
    ARCHIVE="$TGZOUT"
fi

sync

echo
echo "=================================================="
echo " DONE"
echo "=================================================="
echo "Dump folder : $OUTDIR"
echo "Archive     : $ARCHIVE"
echo
ls -lh "$ARCHIVE"
echo
echo "Copy to PC with:"
echo "scp root@192.168.1.1:$ARCHIVE ./"
