#!/bin/sh
 

set -eu

BASE="/tmp/fw_dump"
RAWDIR="$BASE/raw"
FWDIR="$BASE/firmware"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
ZIPOUT="/tmp/fw_dump_${STAMP}.zip"
TGZOUT="/tmp/fw_dump_${STAMP}.tar.gz"
MANIFEST="$BASE/MANIFEST.txt"

MTK_MAGIC=1485313672      # 0x58881688
MTK_EXT_MAGIC=1485379209  # 0x58891689

rm -rf "$BASE"
mkdir -p "$RAWDIR" "$FWDIR"

echo "============================================================"
echo " DOTYWRT MT6890 VERIFIED IMAGE DUMPER"
echo "============================================================"
echo
echo "Raw backups : $RAWDIR"
echo "Firmware    : $FWDIR"
echo

get_partname() {
    dev="$1"
    node="${dev##*/}"
    f="/sys/class/block/$node/uevent"

    [ -r "$f" ] || return 0
    sed -n 's/^PARTNAME=//p' "$f" | head -n 1
}

get_block_bytes() {
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

# Read an unsigned little-endian 32-bit value from a binary file.
# Uses only dd + od, normally available in BusyBox.
read_u32_le() {
    file="$1"
    off="$2"

    set -- $(dd if="$file" bs=1 skip="$off" count=4 2>/dev/null |
        od -An -tu1 2>/dev/null)

    [ "$#" -eq 4 ] || {
        echo 0
        return
    }

    echo $(( $1 + ($2 << 8) + ($3 << 16) + ($4 << 24) ))
}

align_up() {
    value="$1"
    align="$2"

    [ "$align" -gt 0 ] || align=16
    echo $(( ((value + align - 1) / align) * align ))
}

# Parse a MediaTek verified image directly from the raw partition.
#
# MTK part header fields used:
#   +0x00 magic
#   +0x04 data size low
#   +0x30 extension magic
#   +0x34 header size
#   +0x40 image_list_end
#   +0x44 alignment
#   +0x48 data size high
#
# Each sub-image/certificate is:
#   header + payload + alignment padding
#
# image_list_end=1 identifies the last item in the image.
#
# Prints the detected image length in bytes.
detect_mtk_image_end() {
    raw="$1"
    total="$(wc -c < "$raw" | tr -d ' ')"

    case "$total" in
        ''|*[!0-9]*) return 1 ;;
    esac

    off=0
    item=0

    while [ "$item" -lt 128 ]; do
        [ $((off + 80)) -le "$total" ] || return 1

        magic="$(read_u32_le "$raw" "$off")"
        [ "$magic" -eq "$MTK_MAGIC" ] || return 1

        dsize_lo="$(read_u32_le "$raw" $((off + 4)))"
        ext_magic="$(read_u32_le "$raw" $((off + 48)))"
        hdr_size="$(read_u32_le "$raw" $((off + 52)))"
        image_end="$(read_u32_le "$raw" $((off + 64)))"
        align_size="$(read_u32_le "$raw" $((off + 68)))"
        dsize_hi="$(read_u32_le "$raw" $((off + 72)))"

        [ "$ext_magic" -eq "$MTK_EXT_MAGIC" ] || return 1

        # Current MTK images normally use a 512-byte header.
        # Keep validation broad enough for future header extensions.
        [ "$hdr_size" -ge 80 ] || return 1
        [ "$hdr_size" -le 65536 ] || return 1

        [ "$align_size" -gt 0 ] || align_size=16
        [ "$align_size" -le 1048576 ] || return 1

        # All target partitions here are small, but support 64-bit dsize field.
        if [ "$dsize_hi" -ne 0 ]; then
            dsize=$((dsize_lo + dsize_hi * 4294967296))
        else
            dsize="$dsize_lo"
        fi

        next=$((off + hdr_size + dsize))
        next="$(align_up "$next" "$align_size")"

        [ "$next" -gt "$off" ] || return 1
        [ "$next" -le "$total" ] || return 1

        item=$((item + 1))

        if [ "$image_end" -eq 1 ]; then
            echo "$next"
            return 0
        fi

        off="$next"
    done

    return 1
}

dump_one() {
    dev="$1"
    expected_label="$2"
    outfile="$3"

    raw="$RAWDIR/${expected_label}.raw"
    out="$FWDIR/$outfile"

    echo "------------------------------------------------------------"
    echo "GPT label : $expected_label"
    echo "Device    : $dev"
    echo "Output    : $outfile"

    if [ ! -b "$dev" ]; then
        echo "ERROR: missing block device: $dev"
        exit 1
    fi

    actual_label="$(get_partname "$dev")"

    if [ -z "$actual_label" ]; then
        echo "ERROR: kernel GPT PARTNAME unavailable for $dev"
        exit 1
    fi

    if [ "$actual_label" != "$expected_label" ]; then
        echo "ERROR: partition mismatch."
        echo "Expected : $expected_label"
        echo "Actual   : $actual_label"
        echo "STOPPED to avoid dumping the wrong partition."
        exit 1
    fi

    expected_bytes="$(get_block_bytes "$dev")"

    echo "Partition : $expected_bytes bytes"
    echo "Dumping FULL partition..."

    # No count=. bs=1M only controls I/O block size.
    dd if="$dev" of="$raw" bs=1M

    raw_bytes="$(wc -c < "$raw" | tr -d ' ')"

    if [ "$expected_bytes" -gt 0 ] && [ "$raw_bytes" -ne "$expected_bytes" ]; then
        echo "ERROR: incomplete raw dump."
        echo "Expected : $expected_bytes"
        echo "Got      : $raw_bytes"
        exit 1
    fi

    echo "RAW OK    : $raw_bytes bytes"

    echo "Parsing MTK verified-image structure..."

    if image_bytes="$(detect_mtk_image_end "$raw")"; then
        case "$image_bytes" in
            ''|*[!0-9]*)
                echo "ERROR: parser returned an invalid image size."
                exit 1
                ;;
        esac

        if [ "$image_bytes" -le 0 ] || [ "$image_bytes" -gt "$raw_bytes" ]; then
            echo "ERROR: detected image size is invalid: $image_bytes"
            exit 1
        fi

        # Use bs=1/count=N so the byte length is exact on BusyBox.
        dd if="$raw" of="$out" bs=1 count="$image_bytes" 2>/dev/null

        out_bytes="$(wc -c < "$out" | tr -d ' ')"

        if [ "$out_bytes" -ne "$image_bytes" ]; then
            echo "ERROR: extracted image size mismatch."
            rm -f "$out"
            exit 1
        fi

        echo "IMAGE OK  : $out_bytes bytes"
        echo "Saved     : $out"
        echo "$outfile|$expected_label|$dev|$raw_bytes|$out_bytes|MTK_PARSED" >> "$BASE/files.csv"
    else
        echo "WARNING: MTK image end could not be proven."
        echo "         FULL raw dump is SAFE and has been kept:"
        echo "         $raw"
        echo "         No guessed $outfile was created."
        echo "$outfile|$expected_label|$dev|$raw_bytes|0|RAW_ONLY_PARSE_FAILED" >> "$BASE/files.csv"
    fi

    echo
}

echo "filename|gpt_label|device|partition_bytes|image_bytes|status" > "$BASE/files.csv"

# Only one A-slot copy is exported under the original package filename.
# A/B partitions use the same firmware payload name in the MT6890 scatter.
dump_one /dev/mmcblk0p18 spmfw_a      spmfw-verified.img
dump_one /dev/mmcblk0p19 pi_img_a     pi_img-verified.img
dump_one /dev/mmcblk0p20 dpm_a        dpm-verified.img
dump_one /dev/mmcblk0p21 medmcu_a     medmcu-verified.img
dump_one /dev/mmcblk0p22 sspm_a       sspm-verified.img
dump_one /dev/mmcblk0p23 mcupm_a      mcupm-verified.img
dump_one /dev/mmcblk0p24 lk_a         lk-verified.img
dump_one /dev/mmcblk0p25 tee_a        tee-verified.img
dump_one /dev/mmcblk0p42 loader_ext_a loader_ext-verified.img

sync

{
    echo "DOTYWRT MT6890 verified-image dump"
    echo "Date: $(date 2>/dev/null || true)"
    echo
    echo "IMPORTANT:"
    echo "- raw/*.raw = FULL partition backup"
    echo "- firmware/*-verified.img = extracted only when MTK image_list_end was parsed"
    echo "- no zero/FF blind trimming is used"
    echo
    cat "$BASE/files.csv"
} > "$MANIFEST"

if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$BASE"
        : > SHA256SUMS
        for f in raw/*.raw firmware/*; do
            [ -f "$f" ] || continue
            sha256sum "$f" >> SHA256SUMS
        done
    )
fi

echo "============================================================"
echo " RESULT"
echo "============================================================"
echo
echo "Extracted firmware:"
ls -lh "$FWDIR" 2>/dev/null || true
echo
echo "Full raw backups:"
ls -lh "$RAWDIR" 2>/dev/null || true
echo

echo "============================================================"
echo " Creating archive"
echo "============================================================"

if command -v zip >/dev/null 2>&1; then
    rm -f "$ZIPOUT"
    (
        cd /tmp
        zip -r "$ZIPOUT" "$(basename "$BASE")"
    )
    ARCHIVE="$ZIPOUT"
else
    rm -f "$TGZOUT"
    tar -czf "$TGZOUT" -C /tmp "$(basename "$BASE")"
    ARCHIVE="$TGZOUT"
fi

sync

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
echo "Archive : $ARCHIVE"
ls -lh "$ARCHIVE"
echo
echo "Copy to PC:"
echo "scp root@192.168.2.1:$ARCHIVE ./"
