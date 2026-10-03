#!/bin/bash
# Ventoy 1.1.17 ni macOS da fleshkaga o'rnatish (MBR usuli: Legacy BIOS + UEFI ikkisi ham)
# Ventoy'ning rasmiy Ventoy2Disk.sh mantiqi aynan takrorlanadi.
set -euo pipefail

VTDIR="/private/tmp/claude-501/-Users-baxrom-ish-full-test/886e36dd-3051-45c1-8a8c-ba4438d4fbe2/scratchpad/ventoy-1.1.17"
DISK="/dev/disk6"
RDISK="/dev/rdisk6"
XZ="/opt/homebrew/bin/xz"

# --- Kutilgan disk belgilari (xato diskni o'chirmaslik uchun) ---
EXPECT_BYTES=30784094208
EXPECT_NAME="SanDisk 3.2Gen1"

VENTOY_SECTOR_NUM=65536          # 32 MB VTOYEFI
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

[ "$(id -u)" = "0" ] || { red "sudo bilan ishga tushiring: sudo bash $0"; exit 1; }
[ -d "$VTDIR" ] || { red "Ventoy papkasi topilmadi: $VTDIR"; exit 1; }
[ -x "$XZ" ]    || { red "xz topilmadi: $XZ"; exit 1; }

# ---------- 1. Diskni tasdiqlash ----------
grn "==> 1/8  Diskni tekshirish: $DISK"
INFO=$(diskutil info "$DISK")
SIZE_BYTES=$(echo "$INFO" | awk -F'[()]' '/Disk Size/{print $2}' | awk '{print $1}')
MEDIA=$(echo "$INFO" | sed -n 's/.*Device \/ Media Name: *//p')
INTERNAL=$(echo "$INFO" | sed -n 's/.*Device Location: *//p')
REMOVABLE=$(echo "$INFO" | sed -n 's/.*Removable Media: *//p')

echo "    Media      : $MEDIA"
echo "    Size       : $SIZE_BYTES bytes"
echo "    Location   : $INTERNAL"
echo "    Removable  : $REMOVABLE"

if [ "$SIZE_BYTES" != "$EXPECT_BYTES" ] || [ "$MEDIA" != "$EXPECT_NAME" ]; then
    red "XATO: $DISK kutilgan fleshka emas (o'lcham yoki nom mos kelmadi). To'xtatildi."
    exit 1
fi
if [ "$INTERNAL" = "Internal" ]; then
    red "XATO: $DISK ichki disk! To'xtatildi."
    exit 1
fi

SECTOR_NUM=$(( SIZE_BYTES / 512 ))
# Ventoy: part1 = 2048 dan, part2 = oxirida >=32MB (65536 sektor).
# diskutil bo'limlarni 2048-sektor (1 MB) chegarasiga tekislaydi, shuning uchun
# part2 ga 2048 sektor zaxira qo'shamiz - aks holda u 32 MB dan kichik chiqadi.
PART1_SIZE_BYTES=$(( (SECTOR_NUM - 2048 - VENTOY_SECTOR_NUM - 2048) * 512 ))
echo "    Sectors    : $SECTOR_NUM"
echo "    Part1 size : $PART1_SIZE_BYTES bytes (exFAT 'Ventoy')"
echo ""
ylw "!!! $DISK dagi HAMMA ma'lumot o'chiriladi !!!"
printf "Davom etish uchun 'ventoy' deb yozing: "
read -r ANSWER
[ "$ANSWER" = "ventoy" ] || { red "Bekor qilindi."; exit 1; }

# ---------- 2. Eski ma'lumotni tozalash ----------
grn "==> 2/8  Diskni unmount qilish va boshini tozalash"
diskutil unmountDisk force "$DISK"
dd if=/dev/zero of="$RDISK" bs=512 count=64 conv=sync 2>/dev/null
sleep 1

# ---------- 3. Bo'limlarni yaratish ----------
# Boshida 1 MB bo'sh joy: Ventoy'ning core.img 1..2047 sektorlarga yoziladi.
grn "==> 3/8  Bo'limlarni yaratish (MBR: exFAT 'Ventoy' + FAT16 'VTOYEFI')"
diskutil partitionDisk "$DISK" MBR \
    "Free Space" gap 1m \
    ExFAT Ventoy "${PART1_SIZE_BYTES}b" \
    "MS-DOS FAT16" VTOYEFI R
sleep 2

# ---------- 4. Yaratilgan xaritani tekshirish ----------
grn "==> 4/8  Bo'limlar xaritasini tekshirish"
MAP=$(fdisk "$DISK" 2>/dev/null || true)
echo "$MAP"
# Haqiqiy jadvaldan o'qiymiz (diskutil info emas, fdisk aniqroq)
read -r P1_START P1_SIZE <<<"$(echo "$MAP" | sed -n 's/^ 1:.*\[ *\([0-9]*\) *- *\([0-9]*\)\].*/\1 \2/p')"
read -r P2_START P2_SIZE <<<"$(echo "$MAP" | sed -n 's/^ 2:.*\[ *\([0-9]*\) *- *\([0-9]*\)\].*/\1 \2/p')"

echo "    part1 : start=$P1_START  size=$P1_SIZE sektor"
echo "    part2 : start=$P2_START  size=$P2_SIZE sektor (kerak >= $VENTOY_SECTOR_NUM)"

if [ -z "${P1_START:-}" ] || [ -z "${P2_START:-}" ]; then
    red "XATO: partition jadvali o'qilmadi."
    exit 1
fi
if [ "$P1_START" -lt 2048 ]; then
    red "XATO: part1 2048-sektordan oldin boshlanadi ($P1_START) - core.img ustiga yozilib ketardi."
    exit 1
fi
if [ "$P2_SIZE" -lt "$VENTOY_SECTOR_NUM" ]; then
    red "XATO: VTOYEFI bo'limi kichik ($P2_SIZE sektor < $VENTOY_SECTOR_NUM)."
    exit 1
fi
if [ $(( P2_START + VENTOY_SECTOR_NUM )) -gt "$SECTOR_NUM" ]; then
    red "XATO: VTOYEFI disk chegarasidan chiqib ketadi."
    exit 1
fi
if [ $(( P1_START + P1_SIZE )) -gt "$P2_START" ]; then
    red "XATO: part1 va part2 ustma-ust tushadi."
    exit 1
fi

# ---------- 5. exFAT ni Ventoy parametrlari bilan qayta formatlash ----------
# 32 GB dan kichik disk -> 32 KB cluster (64 sektor), Ventoy'dagidek.
grn "==> 5/8  exFAT bo'limini formatlash (32 KB cluster, label: Ventoy)"
diskutil unmountDisk force "$DISK"
newfs_exfat -R -c 64 -v Ventoy "/dev/rdisk6s1"

# ---------- 6. Boot kodini yozish ----------
grn "==> 6/8  Boot kodi: MBR + core.img"
diskutil unmountDisk force "$DISK"

# Sektor 0 ni bitta amalda quramiz: boot.img[0:446] + mavjud partition jadvali + tuzatishlar
python3 - "$RDISK" "$VTDIR/boot/boot.img" <<'PY'
import os, sys
rdisk, bootimg = sys.argv[1], sys.argv[2]
fd = os.open(rdisk, os.O_RDWR)
sec0 = bytearray(os.read(fd, 512))
assert len(sec0) == 512, "sektor 0 o'qilmadi"
with open(bootimg, 'rb') as f:
    boot = f.read()
assert len(boot) >= 446

sec0[0:446] = boot[0:446]           # Ventoy MBR boot kodi (partition jadvali saqlanadi)
sec0[384:400] = os.urandom(16)      # Ventoy disk UUID
sec0[440:444] = os.urandom(4)       # MBR disk signature
sec0[446] = 0x80                    # partition 1 -> active/bootable
sec0[466] = 0xEF                    # partition 2 -> type 0xEF (EFI)
sec0[510:512] = b'\x55\xAA'

os.lseek(fd, 0, os.SEEK_SET)
os.write(fd, bytes(sec0))
os.fsync(fd)
os.close(fd)
print("    sektor 0 yozildi: boot kodi + active flag + 0xEF tip + UUID")
PY

"$XZ" -dc "$VTDIR/boot/core.img.xz" | dd of="$RDISK" bs=512 count=2047 seek=1 conv=sync 2>&1 | tail -1
echo "    core.img yozildi (sektor 1..2047)"

# ---------- 7. VTOYEFI obrazini yozish ----------
grn "==> 7/8  VTOYEFI (32 MB FAT16 obraz) -> sektor $P2_START"
diskutil unmountDisk force "$DISK"
"$XZ" -dc "$VTDIR/ventoy/ventoy.disk.img.xz" | dd of="$RDISK" bs=512 count="$VENTOY_SECTOR_NUM" seek="$P2_START" conv=sync 2>&1 | tail -1

sync
sleep 2

# ---------- 8. Natija ----------
grn "==> 8/8  Tayyor. Diskni qayta o'qish"
diskutil unmountDisk force "$DISK" >/dev/null 2>&1 || true
diskutil mountDisk "$DISK" >/dev/null 2>&1 || true
sleep 2
diskutil list "$DISK"
echo ""
fdisk "$DISK" 2>/dev/null | sed -n '1,20p'
echo ""
grn "Ventoy $(cat "$VTDIR/ventoy/version") o'rnatildi -> $DISK"
grn "Endi ISO fayllarni /Volumes/Ventoy ichiga ko'chiring."
