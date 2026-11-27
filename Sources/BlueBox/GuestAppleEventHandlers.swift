import Graphite

/// Guest handler identities stored in Graphite's application/system dispatch tables.
/// Procedures are opaque guest UPP addresses; they are never cast to native function pointers.
final class GuestAppleEventHandlers {
    private let dispatcher = AppleEventDispatcher()

    func install(eventClass: UInt32, eventID: UInt32, procedure: UInt32,
                 referenceConstant: UInt32, isSystem: Bool) throws(MacError) {
        guard procedure != 0, procedure & 1 == 0 else { throw .parameter }
        dispatcher.install(AppleEventDispatcher.Entry(
            eventClass: FourCharCode(eventClass), eventID: FourCharCode(eventID), isSystem: isSystem,
            procedure: UInt(procedure), referenceConstant: UInt(referenceConstant), handler: { _, _ throws(MacError) in
                // A later guest callback bridge must provide descriptor marshaling and interpreter reentry.
                throw .unimplemented
            }
        ))
    }

    func handler(for event: AppleEvent) -> AppleEventDispatcher.Entry? {
        dispatcher.handler(eventClass: event.eventClass, eventID: event.eventID)
    }

    func entry(eventClass: UInt32, eventID: UInt32, isSystem: Bool) -> AppleEventDispatcher.Entry? {
        dispatcher.entry(eventClass: FourCharCode(eventClass), eventID: FourCharCode(eventID), isSystem: isSystem)
    }

    func remove(eventClass: UInt32, eventID: UInt32, procedure: UInt32, isSystem: Bool) throws(MacError) {
        try dispatcher.remove(eventClass: FourCharCode(eventClass), eventID: FourCharCode(eventID),
                              procedure: UInt(procedure), isSystem: isSystem)
    }
}
