import Foundation

/// Minimal namespace-aware DOM node. Exchange's XML is small, so a DOM is simpler
/// than streaming. Matching is by local name; prefixes in the wild vary (d:/D:, r:/Z:).
public final class RVPXMLNode {
    public let name: String
    public let namespace: String?
    public internal(set) var children: [RVPXMLNode] = []
    public internal(set) var text: String = ""

    init(name: String, namespace: String?) {
        self.name = name
        self.namespace = namespace
    }

    /// First direct child with this local name.
    public func child(_ name: String) -> RVPXMLNode? {
        children.first { $0.name == name }
    }

    /// Depth-first search for the first descendant with this local name.
    public func first(_ name: String) -> RVPXMLNode? {
        for c in children {
            if c.name == name { return c }
            if let hit = c.first(name) { return hit }
        }
        return nil
    }

    /// All descendants with this local name.
    public func all(_ name: String) -> [RVPXMLNode] {
        var out: [RVPXMLNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.all(name))
        }
        return out
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RVPXMLError: Error {
    case parseFailed(String)
}

final class RVPXMLParser: NSObject, XMLParserDelegate {
    private var stack: [RVPXMLNode] = []
    private var root: RVPXMLNode?

    static func parse(_ data: Data) throws -> RVPXMLNode {
        let delegate = RVPXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw RVPXMLError.parseFailed(parser.parserError?.localizedDescription ?? "unknown")
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let node = RVPXMLNode(name: elementName, namespace: namespaceURI)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

enum XMLText {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Wraps text in CDATA, splitting any embedded "]]>".
    static func cdata(_ s: String) -> String {
        "<![CDATA[" + s.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
    }
}
