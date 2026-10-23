import Foundation

struct SVGDocument: Sendable {
    var markup: String
    var size: CGSize
    static func load(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let parser = XMLParser(data: data)
        let metadata = SVGMetadataReader()
        parser.delegate = metadata; parser.shouldResolveExternalEntities = false
        guard parser.parse(), metadata.isSVG else { throw CocoaError(.fileReadCorruptFile) }
        return Self(markup: text, size: metadata.size)
    }
    func html() -> String {
        // WebKit renders vectors at the requested scale. CSP and disabled JS
        // prevent remote/file dependencies from being fetched or executed.
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; frame-src 'none'; connect-src 'none'; script-src 'none'">
        <style>html,body{margin:0;background:transparent;overflow:auto}body{min-width:100vw;min-height:100vh;display:grid;place-items:center}body>svg{display:block;width:\(size.width)px;height:\(size.height)px;flex:none}</style>
        </head><body>\(markup)</body></html>
        """
    }
}

private final class SVGMetadataReader: NSObject, XMLParserDelegate {
    var isSVG = false
    var size = CGSize(width: 1000, height: 1000)
    private var sawRoot = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard !sawRoot else { return }; sawRoot = true
        isSVG = elementName.split(separator: ":").last == "svg"
        let box = (attributes["viewBox"] ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
        if box.count == 4, box[2].isFinite, box[3].isFinite, box[2] > 0, box[3] > 0 {
            size = CGSize(width: box[2], height: box[3])
        }
    }
}
