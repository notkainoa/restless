import Foundation
import IOKit.pwr_mgt

final class PowerAssertion {
    private let type: String
    private var id: IOPMAssertionID?

    init(type: String) {
        self.type = type
    }

    func enable(reason: String = "Restless is keeping this Mac awake") {
        guard id == nil else { return }
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )
        if result == kIOReturnSuccess {
            id = newID
        }
    }

    func disable() {
        guard let id else { return }
        IOPMAssertionRelease(id)
        self.id = nil
    }
}
