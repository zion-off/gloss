// Stand-in for UniformTypeIdentifiers, for scripts/mac-typecheck.py. Declarations
// copied from Apple's documentation JSON (documentation/uniformtypeidentifiers/...).

import Foundation

/// uniformtypeidentifiers/uttype — macOS 11.0+
public struct UTType: Hashable, Sendable {
    /// uniformtypeidentifiers/uttype-swift.struct/init(filenameextension:conformingto:) (macOS 11)
    /// — `init?(filenameExtension: String, conformingTo supertype: UTType = .data)`
    public init?(filenameExtension: String, conformingTo supertype: UTType = .data) {}
    public init?(_ identifier: String) {}
    public var identifier: String { "" }
    public var preferredFilenameExtension: String? { nil }
    public func conforms(to type: UTType) -> Bool { false }
    /// uniformtypeidentifiers/uttype-swift.struct/epub — `org.idpf.epub-container`
    public static var epub: UTType { fatalError() }
    /// uniformtypeidentifiers/uttype-swift.struct/pdf — `com.adobe.pdf`
    public static var pdf: UTType { fatalError() }
    /// uniformtypeidentifiers/uttype-swift.struct/image — `public.image`
    public static var image: UTType { fatalError() }
    public static var fileURL: UTType { fatalError() }
    public static var folder: UTType { fatalError() }
    public static var plainText: UTType { fatalError() }
    public static var html: UTType { fatalError() }
    public static var zip: UTType { fatalError() }
    public static var data: UTType { fatalError() }
}
