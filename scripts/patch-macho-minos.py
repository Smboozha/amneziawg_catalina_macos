#!/usr/bin/env python3
"""patch-macho-minos.py -- сброс минимальной версии macOS в Mach-O.

Переписывает в бинарниках поля минимальной версии ОС:
  * LC_VERSION_MIN_MACOSX (0x24) -- поле version (u32),  смещение +8
  * LC_BUILD_VERSION      (0x32) -- поле minos   (u32),  смещение +0xC

Поддерживает тонкие (MH_MAGIC_64) и универсальные (fat32/fat64) бинарники,
в т.ч. с big-endian слайсами. Никаких внешних зависимостей -- только struct.

ПРИМЕЧАНИЕ (важно): занижение версии убирает ПРОВЕРКУ, которую делает
загрузчик (dyld/LaunchServices). Если сам код реально вызывает API, которого
нет в целевой macOS, приложение всё равно упадёт при запуске. Этот инструмент
предназначен для бинарников, чей КОД совместим с целевой версией, но у которых
неправильно проставлена метка минимальной версии в заголовке.

Usage:
  python3 patch-macho-minos.py <файл> [10.15.8] [--dry-run]
Exit code 0 если ничего не патчилось/патчилось успешно, 2 если не Mach-O.
"""
import struct, sys, os, shutil

LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32

# сигнатуры (4 байта, как лежат в файле)
S_THIN64 = b'\xfe\xed\xfa\xcf'  # MH_MAGIC_64 (LE)
S_THIN32 = b'\xce\xfa\xed\xfe'  # MH_MAGIC   (LE)
S_BE64   = b'\xcf\xfa\xed\xfe'  # MH_CIGAM_64
S_BE32   = b'\xfe\xed\xfa\xce'  # MH_CIGAM
S_FAT    = b'\xca\xfe\xba\xbe'  # FAT_MAGIC
S_FAT64  = b'\xca\xfe\xba\xbf'  # FAT_MAGIC_64

def version_to_packed(v):
    parts = v.split(".")
    major = int(parts[0]) if len(parts) > 0 else 0
    minor = int(parts[1]) if len(parts) > 1 else 0
    patch = int(parts[2]) if len(parts) > 2 else 0
    if not (0 <= major <= 0x3FF and 0 <= minor <= 0xFF and 0 <= patch <= 0xFF):
        raise ValueError("плохая версия: %r (ожидается X.Y.Z, каждое 0..255/1023)" % v)
    return (major << 16) | (minor << 8) | patch

def patch_slice(b, base, end, ver, dry):
    """Патчит один mach-o слайс, начинающийся на offset `base`."""
    sig = b[base:base + 4]
    if sig == S_THIN64:   e = '<'; hdr = 32
    elif sig == S_BE64:   e = '>'; hdr = 32
    elif sig == S_THIN32: e = '<'; hdr = 28
    elif sig == S_BE32:   e = '>'; hdr = 28
    else:
        raise ValueError("не mach-o слайс по смещению %#x" % base)
    (magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds) = \
        struct.unpack_from(e + 'IIIIII', b, base + 0)
    cur = base + hdr
    lim = min(cur + sizeofcmds, end)
    changed = []
    for _ in range(ncmds):
        if cur + 8 > lim:
            break
        cmd, cmdsize = struct.unpack_from(e + 'II', b, cur)
        if cmdsize < 8 or cur + cmdsize > lim:
            break
        if cmd == LC_VERSION_MIN_MACOSX and cmdsize >= 12:
            old = struct.unpack_from(e + 'I', b, cur + 8)[0]
            if old != ver:
                if not dry:
                    struct.pack_into(e + 'I', b, cur + 8, ver)
                changed.append((cur + 8, old, ver, 'LC_VERSION_MIN_MACOSX'))
        elif cmd == LC_BUILD_VERSION and cmdsize >= 16:
            old = struct.unpack_from(e + 'I', b, cur + 0xC)[0]
            if old != ver:
                if not dry:
                    struct.pack_into(e + 'I', b, cur + 0xC, ver)
                changed.append((cur + 0xC, old, ver, 'LC_BUILD_VERSION'))
        cur += cmdsize
    return changed

def walk(blob, ver, dry):
    """Обрабатывает blob (bytes) и возвращает список [(kind, off, old, new, name)]."""
    out = []
    sig = blob[0:4]
    if sig in (S_FAT, S_FAT64):
        e = '>'
        base = 8
        if sig == S_FAT:
            nfat = struct.unpack_from('>I', blob, 4)[0]
            ent = 20
            for i in range(nfat):
                cputype, cpusubtype, off, size, align = struct.unpack_from(
                    '>IIIII', blob, base + i * ent)
                try:
                    out += patch_slice(blob, off, off + size, ver, dry)
                except ValueError:
                    pass
        else:  # FAT_MAGIC_64
            nfat = struct.unpack_from('>I', blob, 4)[0]
            ent = 32
            for i in range(nfat):
                cputype, cpusubtype, off, size, align = struct.unpack_from(
                    '>IIQII', blob, base + i * ent)[:5]
                try:
                    out += patch_slice(blob, off, off + size, ver, dry)
                except ValueError:
                    pass
    elif sig in (S_THIN64, S_THIN32, S_BE64, S_BE32):
        try:
            out += patch_slice(blob, 0, len(blob), ver, dry)
        except ValueError:
            pass
    else:
        raise ValueError("не Mach-O")
    return out

def main():
    args = [a for a in sys.argv[1:]]
    if not args:
        sys.stderr.write("usage: patch-macho-minos.py <файл|dir> [10.15.8] [--dry-run]\n")
        return 2
    dry = '--dry-run' in args
    args = [a for a in args if a != '--dry-run']
    path = args[0]
    ver = version_to_packed(args[1]) if len(args) > 1 else version_to_packed('10.15.8')
    if os.path.isdir(path):
        files = []
        for root, _, names in os.walk(path):
            for n in names:
                p = os.path.join(root, n)
                if os.path.isfile(p) and not os.path.islink(p):
                    files.append(p)
    else:
        files = [path]
    total = 0
    for p in files:
        with open(p, 'rb') as f:
            blob = bytearray(f.read())
        try:
            changes = walk(blob, ver, dry)
        except ValueError:
            continue
        if not changes:
            continue
        for off, old, new, name in changes:
            oldv = '%d.%d.%d' % (old >> 16, (old >> 8) & 0xFF, old & 0xFF)
            newv = '%d.%d.%d' % (new >> 16, (new >> 8) & 0xFF, new & 0xFF)
            print('[macho] %s: %s %s -> %s' % (p, name, oldv, newv))
            total += 1
        if not dry:
            tmp = p + '.__path_minos_tmp'
            with open(tmp, 'wb') as f:
                f.write(blob)
            os.chmod(tmp, os.stat(p).st_mode & 0o7777)
            os.replace(tmp, p)
    print('[macho] итого сброшено полей: %d' % total)
    return 0

if __name__ == '__main__':
    sys.exit(main())
