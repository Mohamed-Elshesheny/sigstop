import zlib, struct

def write_png(path, pixels, w, h, scale=1):
    """Minimal PNG writer. pixels = list of rows of (r,g,b,a) tuples."""
    raw = b""
    for y in range(h):
        for _ in range(scale):
            row = b"\x00"
            for x in range(w):
                r, g, b, a = pixels[y][x]
                row += bytes((r, g, b, a)) * scale
            raw += row
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)
