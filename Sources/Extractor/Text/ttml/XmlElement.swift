//
//  XmlElement.swift
//  SEPlayer
//

import Foundation
import SEPlayerCommon

/// An element of an XML document, with its attributes and what it contains.
///
/// Names of elements and attributes are local: `tts:color` is `color`.
struct XmlElement {
    enum Child {
        case element(XmlElement)
        case text(String)
    }

    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [Child] = []

    /// The text the element contains directly.
    var text: String {
        children.reduce(into: "") { result, child in
            if case let .text(text) = child { result += text }
        }
    }

    /// The elements the element contains directly.
    var elements: [XmlElement] {
        children.compactMap { child in
            if case let .element(element) = child { element } else { nil }
        }
    }

    /// The element and all the elements in it, in document order.
    var descendantsAndSelf: [XmlElement] {
        [self] + elements.flatMap(\.descendantsAndSelf)
    }

    /// Reads the root element of the document in the readable bytes of `document`.
    init(document: BlockBufferReader) throws {
        let builder = XmlTreeBuilder()
        // Reads the bytes in place rather than a copy of them.
        let parser = XMLParser(stream: BlockBufferInputStream(reader: document))
        parser.delegate = builder
        // Reads the whole document, calling the builder for each element and text; false if it is malformed.
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError?.localizedDescription ?? "no root element"
            throw ParserError.createForMalformedDataOfUnknownType(message: "Malformed XML: \(reason)")
        }
        self = root
    }

    fileprivate init(qualifiedName: String, attributes: [String: String]) {
        name = Self.localName(qualifiedName)
        self.attributes = Dictionary(
            attributes.map { (Self.localName($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func localName(_ qualifiedName: String) -> String {
        guard let colon = qualifiedName.lastIndex(of: ":") else {
            return qualifiedName
        }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }
}

/// Builds the elements of a document as the parser reads it.
private final class XmlTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: XmlElement?

    private var stack: [XmlElement] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        stack.append(XmlElement(qualifiedName: elementName, attributes: attributes))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let element = stack.popLast() else { return }
        if stack.isEmpty {
            root = element
        } else {
            stack[stack.count - 1].children.append(.element(element))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(bytes: CDATABlock, encoding: .utf8) else { return }
        appendText(text)
    }

    /// Text comes in pieces, such as around entities: consecutive pieces make one text.
    private func appendText(_ string: String) {
        guard !stack.isEmpty else { return }
        let index = stack.count - 1
        guard case var .text(text) = stack[index].children.last else {
            stack[index].children.append(.text(string))
            return
        }

        // Taken out first, so the text has one owner and grows in place instead of being copied for each piece.
        stack[index].children.removeLast()
        text += string
        stack[index].children.append(.text(text))
    }
}
