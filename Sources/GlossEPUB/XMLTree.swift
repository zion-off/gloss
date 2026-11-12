import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A tiny DOM built with `XMLParser`, enough for container.xml, OPF, NCX and nav documents.
/// Element names are stored without namespace prefixes (`dc:title` → `title`).
final class XMLNode: @unchecked Sendable {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Attribute by local name (`epub:type` matches `type`).
    func attribute(_ local: String) -> String? {
        if let value = attributes[local] { return value }
        return attributes.first { $0.key.split(separator: ":").last.map(String.init) == local }?.value
    }

    func first(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// Depth-first search.
    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }

    /// All text inside this node, whitespace-normalised.
    var allText: String {
        let joined = ([text] + children.map(\.allText)).joined(separator: " ")
        return joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw EPUBError.malformed(parser.parserError?.localizedDescription ?? "unreadable xml")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLNode(name: local, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
