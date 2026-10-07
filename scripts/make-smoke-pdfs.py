#!/usr/bin/env python3
"""Generate valid, synthetic, one-page PDFs at exact binary upload boundaries."""

from pathlib import Path
import sys

LIMIT = 5 * 1024 * 1024


def pdf(padding):
    stream = (
        b"BT /F1 12 Tf 20 100 Td (Connector synthetic smoke test) Tj ET\n%"
        + b"x" * padding
        + b"\n"
    )
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 150] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length "
        + str(len(stream)).encode()
        + b" >>\nstream\n"
        + stream
        + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    body = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, obj in enumerate(objects, 1):
        offsets.append(len(body))
        body.extend(f"{number} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(body)
    body.extend(b"xref\n0 6\n0000000000 65535 f \n")
    for offset in offsets:
        body.extend(f"{offset:010d} 00000 n \n".encode())
    body.extend(
        f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    )
    return body


def sized_pdf(size):
    padding = size - len(pdf(0))
    for _ in range(10):
        assert padding >= 0, "Size too small for a valid PDF"
        body = pdf(padding)
        if len(body) == size:
            return body
        padding += size - len(body)
    raise ValueError("Could not produce exact PDF size")


if __name__ == "__main__":
    destination = Path(sys.argv[1])
    destination.mkdir(parents=True, exist_ok=True)
    for name, size in (
        ("small", 1024),
        ("approx-4.9-MiB", round(4.9 * 1024 * 1024)),
        ("below-limit", LIMIT - 1),
        ("at-limit", LIMIT),
        ("over-limit", LIMIT + 1),
    ):
        path = destination / f"{name}.pdf"
        path.write_bytes(sized_pdf(size))
        print(f"{path}: {size} bytes")
