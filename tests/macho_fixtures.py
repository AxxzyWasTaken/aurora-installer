# SPDX-License-Identifier: MIT
"""Synthetic Mach-O images for the lsm2 masker lattice tests.

Nothing here comes from macOS: the lattice is a made-up table that only
satisfies the structural rule (64 single bins, strictly increasing ends,
the last one 321), and the images are built from scratch.
"""
import struct

CPU_X86_64 = (0x01000007, 3)
CPU_ARM64E = (0x0100000C, 2)


def synthetic_lattice():
    """1..64, then 36 evenly widening ends up to 321. Not macOS's table."""
    ends = list(range(1, 65)) + [64 + -(-(j + 1) * 257 // 36) for j in range(36)]
    assert len(ends) == 100 and ends[-1] == 321
    return struct.pack("<100Q", *ends)


def other_lattice():
    """A second valid synthetic table, different from synthetic_lattice()."""
    ends = list(range(1, 65)) + [64 + -(-(j + 1) * 257 // 36) for j in range(36)]
    ends[70] += 1
    return struct.pack("<100Q", *ends)


def _section(name, segment, addr, size, offset, flags=0):
    return struct.pack("<16s16sQQIIIIIIII", name, segment, addr, size, offset,
                       3, 0, 0, flags, 0, 0, 0)


def thin(const, text=b"\0" * 64, cpu=CPU_ARM64E, const_addr_skew=0, const_sections=1,
         const_flags=0):
    """A 64-bit Mach-O image whose __TEXT segment holds __text then
    `const_sections` __const sections, each with the bytes `const`.
    `const_addr_skew` moves the __const address off its natural alignment."""
    base = 0x1000
    text_off = base
    const_off = text_off + ((len(text) + 15) & ~15)
    sections = [_section(b"__text", b"__TEXT", 0x100000000 + text_off, len(text), text_off)]
    body = bytearray(text) + bytearray(const_off - text_off - len(text))
    for _ in range(const_sections):
        off = text_off + len(body)
        sections.append(_section(b"__const", b"__TEXT", 0x100000000 + off + const_addr_skew,
                                 len(const), off, const_flags))
        body += const + bytearray((-len(const)) % 16)
    nsects = len(sections)
    cmdsize = 72 + 80 * nsects
    segment = struct.pack("<II16sQQQQiiII", 0x19, cmdsize, b"__TEXT", 0x100000000,
                          base + len(body), 0, base + len(body), 5, 5, nsects, 0)
    commands = segment + b"".join(sections)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu[0], cpu[1], 6, 1, len(commands), 0, 0)
    image = bytearray(header + commands)
    image += bytearray(base - len(image))
    image += body
    return bytes(image)


def fat(*images, cpus=(CPU_X86_64, CPU_ARM64E, (0x0100000C, 12))):
    """A universal (fat) file holding `images`, each slice 16 KiB aligned."""
    align = 0x4000
    table = bytearray(struct.pack(">II", 0xCAFEBABE, len(images)))
    out = bytearray()
    offset = align
    entries = []
    for image, cpu in zip(images, cpus):
        entries.append((cpu, offset, len(image)))
        offset = (offset + len(image) + align - 1) & ~(align - 1)
    for cpu, off, size in entries:
        table += struct.pack(">iiIII", cpu[0], cpu[1], off, size, 14)
    out = table + bytearray(align - len(table))
    for (cpu, off, size), image in zip(entries, images):
        out += bytearray(off - len(out))
        out += image
    return bytes(out)


def padded(lattice, before=24, after=40):
    """__const contents with the lattice between other constants, aligned."""
    return b"\x11" * before + lattice + b"\x22" * after
