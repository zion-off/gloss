#!/usr/bin/env python3
"""Writes a small EPUB and PDF for CLI smoke tests: make-fixtures.py <dir>"""
import sys, zipfile, zlib, os

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def epub(path, title, author, chapters):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', compress_type=zipfile.ZIP_DEFLATED)
        manifest = ''.join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(len(chapters)))
        spine = ''.join(f'<itemref idref="c{i}"/>' for i in range(len(chapters)))
        nav = ''.join(f'<li><a href="c{i}.xhtml">{t}</a></li>' for i, (t, _) in enumerate(chapters))
        z.writestr('OEBPS/content.opf', f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:language>en</dc:language></metadata><manifest>{manifest}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>{spine}</spine></package>', compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/nav.xhtml', f'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>{nav}</ol></nav></body></html>', compress_type=zipfile.ZIP_DEFLATED)
        for i, (t, body) in enumerate(chapters):
            z.writestr(f'OEBPS/c{i}.xhtml', f'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>{t}</title></head><body><h1>{t}</h1><p>{body}</p></body></html>', compress_type=zipfile.ZIP_DEFLATED)

def pdf(path, title, author, text):
    content = zlib.compress(f'BT /F1 12 Tf 72 720 Td ({text}) Tj ET'.encode())
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
        b'<< /Length %d /Filter /FlateDecode >>\nstream\n' % len(content) + content + b'\nendstream',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
        f'<< /Title ({title}) /Author ({author}) >>'.encode(),
    ]
    data = b'%PDF-1.7\n'
    offsets = []
    for n, body in enumerate(objects, 1):
        offsets.append(len(data))
        data += b'%d 0 obj\n' % n + body + b'\nendobj\n'
    xref = len(data)
    data += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objects) + 1)
    data += b''.join(b'%010d 00000 n \n' % o for o in offsets)
    data += b'trailer\n<< /Size %d /Root 1 0 R /Info 6 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objects) + 1, xref)
    open(path, 'wb').write(data)

epub(f'{out}/stranger.epub', 'The Stranger', 'Albert Camus',
     [('Part One', 'Mother died today. Or maybe yesterday, I don&#8217;t know.'),
      ('Part Two', 'The sun was the same as it had been the day I buried Maman.')])
epub(f'{out}/plague.epub', 'The Plague', 'Albert Camus',
     [('Part One', 'The unusual events described in this chronicle occurred in Oran.')])
pdf(f'{out}/myth.pdf', 'The Myth of Sisyphus', 'Albert Camus', 'One must imagine Sisyphus happy.')
print(out)
