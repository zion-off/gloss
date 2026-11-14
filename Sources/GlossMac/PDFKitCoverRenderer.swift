import AppKit
import PDFKit
import GlossCore

/// Covers for PDFs: the first page, rendered by PDFKit as a PNG (the portable `GlossPDF` reads
/// text and metadata but doesn't render). Registered at the composition root with
/// `FormatRegistry.adding(coverExtractor:for:)`; imports call it off the main actor.
struct PDFKitCoverRenderer: CoverExtracting {
    /// The longest side of the rendered cover, in pixels.
    static let maxDimension: CGFloat = 900

    func extractCover(from data: Data) throws -> CoverImage? {
        guard let document = PDFDocument(data: data), document.pageCount > 0, let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = Self.maxDimension / max(bounds.width, bounds.height)
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return CoverImage(data: png, mimeType: "image/png")
    }
}
