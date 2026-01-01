import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeManager {
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var displaySleepAssertionID: IOPMAssertionID = 0

    var isActive: Bool { systemSleepAssertionID != 0 }

    func start(keepDisplayAwake: Bool) {
        guard systemSleepAssertionID == 0 else { return }

        let reason = "Barista Keep Awake" as CFString

        var systemID: IOPMAssertionID = 0
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemID
        )

        guard systemResult == kIOReturnSuccess else {
            systemSleepAssertionID = 0
            return
        }

        systemSleepAssertionID = systemID

        if keepDisplayAwake {
            var displayID: IOPMAssertionID = 0
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &displayID
            )
            if displayResult == kIOReturnSuccess {
                displaySleepAssertionID = displayID
            } else {
                displaySleepAssertionID = 0
            }
        } else {
            displaySleepAssertionID = 0
        }
    }

    func stop() {
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }

        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }
    }

    func restart(keepDisplayAwake: Bool) {
        stop()
        start(keepDisplayAwake: keepDisplayAwake)
    }
}
