import os
import plistlib
import struct
import subprocess
from pathlib import Path

DISK = '/dev/disk6'
RAW = '/dev/rdisk6'
BACKUP = Path('/Users/baxrom/ish_full/test/ventoy-layout-backup')

def info(device):
    return plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', device]))

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

device = info(DISK)
require(device.get('TotalSize') == 30784094208, 'Unexpected disk size')
require(device.get('MediaName') == 'SanDisk 3.2Gen1', 'Unexpected disk model')
require(device.get('Internal') is False and device.get('BusProtocol') == 'USB', 'Not external USB')
subprocess.run(['diskutil', 'unmountDisk', DISK], check=True)
try:
    with open(RAW, 'r+b', buffering=0) as disk:
        original = disk.read(512)
        require(len(original) == 512 and original[510:] == b'\x55\xaa', 'Invalid MBR')
        p1, n1 = struct.unpack_from('<II', original, 454)
        p2, n2 = struct.unpack_from('<II', original, 470)
        require(original[450] == 7 and original[466] == 239, 'Unexpected partition types')
        require((p1, n1, p2, n2) == (2048, 60055552, 60059648, 65536), 'Unexpected partition layout')
        require(original[478:510] == bytes(32), 'Unexpected additional partitions')
        disk.seek(p1 * 512)
        exfat = disk.read(512)
        require(exfat[3:11] == b'EXFAT   ', 'Missing exFAT signature')
        require(struct.unpack_from('<Q', exfat, 72)[0] <= n1, 'exFAT exceeds partition')
        disk.seek(p2 * 512)
        efi = disk.read(512)
        require(efi[510:512] == b'\x55\xaa' and (efi[54:57] == b'FAT' or efi[82:85] == b'FAT'), 'EFI filesystem not recognized')
        BACKUP.mkdir(exist_ok=True)
        with open(BACKUP / 'mbr-before.bin', 'xb') as saved:
            saved.write(original)
            saved.flush()
            os.fsync(saved.fileno())
        (BACKUP / 'exfat-boot.bin').write_bytes(exfat)
        (BACKUP / 'efi-boot.bin').write_bytes(efi)
        patched = bytearray(original)
        # Include the unused gap in partition 1; exFAT and EFI data stay in place.
        struct.pack_into('<I', patched, 458, p2 - p1)
        disk.seek(0)
        require(disk.write(patched) == 512, 'Short MBR write')
        os.fsync(disk.fileno())
        disk.seek(0)
        require(disk.read(512) == patched, 'MBR readback mismatch')
        print('FIXED: partition 1 now ends exactly where partition 2 starts.')
        print('Original MBR saved to', BACKUP)
finally:
    subprocess.run(['diskutil', 'mountDisk', DISK], check=False)
