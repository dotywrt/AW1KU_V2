#!/bin/sh

set -eu

OUTDIR="/tmp/fw_dump"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
ZIPOUT="/tmp/fw_dump_${STAMP}.zip"
TGZOUT="/tmp/fw_dump_${STAMP}.tar.gz"

echo "======================================================"
echo " DOTYWRT MT6890 - Missing Firmware Dump (A slot only)"
echo "======================================================"
echo
echo "Output: $OUTDIR"
echo

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

get_partname() {
    dev="$1"
    node="${dev##*/}"
    f="/sys/class/block/$node/uevent"

    [ -r "$f" ] || return 0
    sed -n 's/^PARTNAME=//p' "$f" | head -n 1
}

get_expected_bytes() {
    dev="$1"
    node="${dev##*/}"
    f="/sys/class/block/$node/size"

    [ -r "$f" ] || {
        echo 0
        return
    }

    sectors="$(cat "$f" 2>/dev/null || echo 0)"
    case "$sectors" in
        ''|*[!0-9]*) sectors=0 ;;
    esac

    echo $((sectors * 512))
}

dump_part() {
    dev="$1"
    expected_label="$2"
    outfile="$3"

    echo "------------------------------------------------------"
    echo "Partition : $expected_label"
    echo "Device    : $dev"
    echo "Filename  : $outfile"

    if [ ! -b "$dev" ]; then
        echo "ERROR: block device not found: $dev"
        exit 1
    fi

    actual_label="$(get_partname "$dev")"

    if [ -n "$actual_label" ]; then
        echo "GPT label : $actual_label"

        if [ "$actual_label" != "$expected_label" ]; then
            echo "ERROR: GPT label mismatch."
            echo "Expected : $expected_label"
            echo "Actual   : $actual_label"
            echo "STOPPED to avoid dumping the wrong partition."
            exit 1
        fi
    else
        echo "GPT label : unavailable"
        echo "ERROR: cannot safely verify partition mapping."
        exit 1
    fi

    expected="$(get_expected_bytes "$dev")"
    echo "Full size : $expected bytes"

    # No count= is used. This reads the ENTIRE partition.
    dd if="$dev" of="$OUTDIR/$outfile" bs=1M

    actual="$(wc -c < "$OUTDIR/$outfile" | tr -d ' ')"
    echo "Dumped    : $actual bytes"

    if [ "$expected" -gt 0 ] && [ "$actual" -ne "$expected" ]; then
        echo "ERROR: incomplete dump."
        echo "Expected : $expected bytes"
        echo "Got      : $actual bytes"
        exit 1
    fi

    echo "OK: FULL partition saved as $outfile"
    echo
}

# Scatter A-slot payloads.
# A/B entries reference the same firmware filename, so only A is dumped.
dump_part /dev/mmcblk0p18 spmfw_a     spmfw-verified.img
dump_part /dev/mmcblk0p19 pi_img_a    pi_img-verified.img
dump_part /dev/mmcblk0p20 dpm_a       dpm-verified.img
dump_part /dev/mmcblk0p21 medmcu_a    medmcu-verified.img
dump_part /dev/mmcblk0p22 sspm_a      sspm-verified.img
dump_part /dev/mmcblk0p23 mcupm_a     mcupm-verified.img
dump_part /dev/mmcblk0p24 lk_a        lk-verified.img
dump_part /dev/mmcblk0p25 tee_a       tee-verified.img
dump_part /dev/mmcblk0p42 loader_ext_a loader_ext-verified.img

sync

echo "======================================================"
echo " Creating manifest"
echo "======================================================"

{
    echo "DOTYWRT MT6890 missing firmware payload dump"
    echo "Source: A-slot partitions only"
    echo "Note: files are FULL raw partition dumps using original package filenames."
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

echo "======================================================"
echo " Creating archive"
echo "======================================================"

if command -v zip >/dev/null 2>&1; then
    rm -f "$ZIPOUT"
    (
        cd /tmp
        zip -r "$ZIPOUT" "$(basename "$OUTDIR")"
    )
    ARCHIVE="$ZIPOUT"
else
    echo "zip not installed; using tar.gz"
    rm -f "$TGZOUT"
    tar -czf "$TGZOUT" -C /tmp "$(basename "$OUTDIR")"
    ARCHIVE="$TGZOUT"
fi

sync

echo
echo "======================================================"
echo " DONE"
echo "======================================================"
echo "Folder  : $OUTDIR"
echo "Archive : $ARCHIVE"
echo
ls -lh "$ARCHIVE"
echo
echo "Copy to PC:"
echo "scp root@192.168.2.1:$ARCHIVE ./"
