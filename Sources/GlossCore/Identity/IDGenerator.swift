import Foundation

/// Mints new identifiers. Injected so tests get deterministic IDs.
public protocol IDGenerator: Sendable {
    func next() -> GlossID
}

extension IDGenerator {
    public func make<Entity>(_: Entity.Type = Entity.self) -> Identifier<Entity> {
        Identifier(next())
    }
}

/// Production generator: UUIDv7 from a time source and the system RNG.
public struct UUIDv7Generator: IDGenerator {
    private let time: any TimeSource

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
    }

    public func next() -> GlossID {
        var rng = SystemRandomNumberGenerator()
        let ms = UInt64(max(0, time.now().timeIntervalSince1970 * 1000))
        return GlossID.uuidV7(milliseconds: ms, random: (rng.next(), rng.next()))
    }
}
