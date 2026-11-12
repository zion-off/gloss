import Foundation

/// Builds small, valid EPUB files for tests.
public struct EPUBBuilder {
    public var title: String? = "The Stranger"
    public var authors: [String] = ["Albert Camus"]
    public var language: String? = "en"
    public var chapters: [(title: String, body: String)] = [("Part One", "<p>Mother died today.</p>")]
    public var epub3 = true
    public var coverPNG: Data? = nil
    public var opfDirectory = "OEBPS"

    public init() {}

    public static let tinyPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])

    public func build() throws -> Data {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", stored: true)
        let opfPath = opfDirectory.isEmpty ? "content.opf" : "\(opfDirectory)/content.opf"
        zip.add("META-INF/container.xml", """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        let prefix = opfDirectory.isEmpty ? "" : "\(opfDirectory)/"
        var manifest = ""
        var spine = ""
        for (index, chapter) in chapters.enumerated() {
            let name = "text/chapter \(index + 1).xhtml"
            manifest += "<item id=\"c\(index)\" href=\"\(name.replacingOccurrences(of: " ", with: "%20"))\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(index)\"/>\n"
            zip.add(prefix + name, """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(chapter.title)</title><style>p { margin: 0 }</style></head>
            <body><h1>\(chapter.title)</h1>\(chapter.body)</body></html>
            """)
        }
        var metadataExtras = ""
        if let coverPNG {
            if epub3 {
                manifest += "<item id=\"cover-img\" href=\"images/cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>\n"
            } else {
                manifest += "<item id=\"img1\" href=\"images/cover.png\" media-type=\"image/png\"/>\n"
                metadataExtras += "<meta name=\"cover\" content=\"img1\"/>\n"
            }
            zip.add(prefix + "images/cover.png", data: coverPNG)
        }
        let navPoints = chapters.enumerated().map { index, chapter in
            "<li><a href=\"text/chapter%20\(index + 1).xhtml\">\(chapter.title)</a></li>"
        }.joined(separator: "\n")
        if epub3 {
            manifest += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
            zip.add(prefix + "nav.xhtml", """
            <?xml version="1.0"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="landmarks"><ol><li><a href="text/chapter%201.xhtml">start</a></li></ol></nav>
            <nav epub:type="toc"><ol>\(navPoints)</ol></nav></body></html>
            """)
        } else {
            manifest += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
            let points = chapters.enumerated().map { index, chapter in
                "<navPoint id=\"n\(index)\" playOrder=\"\(index + 1)\"><navLabel><text>\(chapter.title)</text></navLabel><content src=\"text/chapter%20\(index + 1).xhtml#start\"/></navPoint>"
            }.joined(separator: "\n")
            zip.add(prefix + "toc.ncx", """
            <?xml version="1.0"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>\(points)</navMap></ncx>
            """)
        }
        let creators = authors.enumerated().map { index, author in
            epub3 ? "<dc:creator id=\"a\(index)\">\(author)</dc:creator>" : "<dc:creator opf:role=\"aut\">\(author)</dc:creator>"
        }.joined(separator: "\n")
        zip.add(opfPath, """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="\(epub3 ? "3.0" : "2.0")" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(title.map { "<dc:title>\($0)</dc:title>" } ?? "")
            \(creators)
            \(language.map { "<dc:language>\($0)</dc:language>" } ?? "")
            <dc:identifier id="uid">urn:uuid:1234</dc:identifier>
            \(metadataExtras)
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine\(epub3 ? "" : " toc=\"ncx\"")>\(spine)</spine>
        </package>
        """)
        return try zip.build()
    }
}
