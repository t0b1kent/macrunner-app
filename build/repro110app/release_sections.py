"""Executable section ranges reused from the release package path-mapping checks."""
import hashlib
import struct


def sections(data):
    result = []
    if data[:2] == b'MZ':
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        assert data[pe:pe + 4] == b'PE\0\0'
        count, optional = struct.unpack_from('<H', data, pe + 6)[0], struct.unpack_from('<H', data, pe + 20)[0]
        start = pe + 24 + optional
        assert 0 < count <= 10000 and start + count * 40 <= len(data)
        for i in range(count):
            at = start + 40 * i
            name = data[at:at + 8].split(b'\0')[0].decode('ascii')
            size, offset = struct.unpack_from('<II', data, at + 16)
            flags = struct.unpack_from('<I', data, at + 36)[0]
            assert offset + size <= len(data)
            result.append((name, offset, size, bool(flags & 0x20000000)))
    elif data[:4] == b'\xcf\xfa\xed\xfe':
        count = struct.unpack_from('<I', data, 16)[0]
        at = 32
        assert 0 < count <= 10000
        for _ in range(count):
            cmd, length = struct.unpack_from('<II', data, at)
            assert length >= 8 and at + length <= len(data)
            if cmd == 0x19:
                nsects = struct.unpack_from('<I', data, at + 64)[0]
                assert 72 + nsects * 80 <= length
                for i in range(nsects):
                    s = at + 72 + 80 * i
                    name = data[s:s + 16].split(b'\0')[0].decode('ascii')
                    seg = data[s + 16:s + 32].split(b'\0')[0].decode('ascii')
                    size = struct.unpack_from('<Q', data, s + 40)[0]
                    offset, flags = struct.unpack_from('<I', data, s + 48)[0], struct.unpack_from('<I', data, s + 64)[0]
                    if flags & 0xff in (0x1, 0xc, 0x12):
                        continue
                    assert offset + size <= len(data)
                    code = name == '__text' or bool(flags & 0x80000400)
                    result.append((seg + '/' + name, offset, size, code))
            at += length
    else:
        raise ValueError('Unsupported executable format')
    assert any(code for _, _, _, code in result)
    return result


def ranges(data):
    if data[:2] == b'MZ' or data[:4] == b'\xcf\xfa\xed\xfe':
        return sections(data)
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', data, 4)[0]
        assert 0 < count <= 16
        is64 = data[:4] == b'\xca\xfe\xba\xbf'
        size = 32 if is64 else 20
        out = []
        for i in range(count):
            at = 8 + i * size
            offset, length = struct.unpack_from('>QQ' if is64 else '>II', data, at + 8)
            assert offset + length <= len(data)
            for name, start, amount, code in ranges(data[offset:offset + length]):
                out.append((f'fat[{i}]/{name}', offset + start, amount, code))
        return out
    if data[:8] == b'!<arch>\n':
        out, at, number = [], 8, 0
        while at < len(data):
            header = data[at:at + 60]
            assert len(header) == 60 and header[58:60] == b'`\n'
            amount = int(header[48:58])
            name = header[:16].decode('ascii').strip()
            payload = at + 60
            assert payload + amount <= len(data)
            if name not in ('/', '//', '/SYM64/', '/<ECSYMBOLS>/'):
                value = data[payload:payload + amount]
                if name.startswith('#1/'):
                    extra = int(name[3:]); value = value[extra:]; payload += extra
                for sec, start, length, code in ranges(value):
                    out.append((f'ar[{number}]/{sec}', payload + start, length, code))
            else:
                out.append((f'ar[{number}]/INDEX', payload, amount, False))
            number += 1
            assert number <= 1000000
            at += 60 + amount + amount % 2
        assert at == len(data)
        return out
    if data[:4] == b'\x00\x00\xff\xff':
        version = struct.unpack_from('<H', data, 4)[0]
        if version in (0, 1):
            assert len(data) >= 20
            payload = struct.unpack_from('<I', data, 12)[0]
            assert payload + 20 <= len(data)
            return [('COFF_IMPORT_DATA', 0, len(data), False)]
        assert version == 2 and len(data) >= 56
        count = struct.unpack_from('<I', data, 44)[0]; start = 56
    else:
        machine, count = struct.unpack_from('<HH', data)
        assert machine in (0x14c, 0x8664, 0xaa64, 0xa641)
        optional = struct.unpack_from('<H', data, 16)[0]; start = 20 + optional
    assert 0 < count <= 10000 and start + count * 40 <= len(data)
    out = []
    for i in range(count):
        at = start + i * 40
        name = data[at:at + 8].split(b'\0')[0].decode('ascii')
        size, offset = struct.unpack_from('<II', data, at + 16)
        flags = struct.unpack_from('<I', data, at + 36)[0]
        assert offset + size <= len(data)
        out.append((f'coff[{i}]/{name}', offset, size, bool(flags & 0x20000020)))
    return out


def code_hashes(data):
    return {name: hashlib.sha256(data[start:start + size]).hexdigest()
            for name, start, size, code in ranges(data) if code}
