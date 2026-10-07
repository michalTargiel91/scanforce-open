#!/usr/bin/env python3
"""Writes a synthetic one-page invoice PDF for ScanForce Open demos (standard library only).

Every value is fictional and matches the mock provider's synthetic invoice result.

    python3 examples/demo/make_demo_invoice.py [output.pdf]
"""
import sys
from pathlib import Path

LINES = [
    (72, 740, 20, "INVOICE  MOCK-INV-0001"),
    (72, 712, 10, "SYNTHETIC DEMO DOCUMENT - NOT A REAL INVOICE"),
    (72, 670, 11, "Supplier: Example Supplies Ltd"),
    (72, 654, 11, "Tax ID: XX0000000000"),
    (340, 670, 11, "Customer: Sample Customer Inc"),
    (72, 622, 11, "Issue date: 2026-09-30"),
    (340, 622, 11, "Due date: 2026-10-30"),
    (72, 580, 11, "Description                     Qty    Unit price      Amount"),
    (72, 560, 11, "Synthetic service A                2        250.00      500.00"),
    (72, 544, 11, "Synthetic service B                1        500.00      500.00"),
    (72, 504, 11, "Net                                                   1000.00 EUR"),
    (72, 488, 11, "Tax                                                    230.00 EUR"),
    (72, 466, 11, "Total                                                 1230.00 EUR"),
]


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def build() -> bytes:
    stream = "".join(f"BT /F1 {size} Tf {x} {y} Td ({escape(text)}) Tj ET\n" for x, y, size, text in LINES).encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    out += b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets)
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


if __name__ == "__main__":
    target = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("synthetic-invoice.pdf"))
    target.write_bytes(build())
    print(f"Wrote {target} ({target.stat().st_size} bytes, synthetic data only)")
