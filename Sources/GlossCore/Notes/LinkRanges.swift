import GlossMarkdown

/// Where a page links to something: used to put the caret on the link a marker came from.
public enum LinkRanges {
    /// UTF-16 ranges of every link in `body` whose destination is `link`.
    public static func ranges(of link: GlossLink, in body: String) -> [Range<Int>] {
        LinkScanner.links(in: body).filter { GlossLink(string: $0.destination) == link }.map(\.range)
    }
}
