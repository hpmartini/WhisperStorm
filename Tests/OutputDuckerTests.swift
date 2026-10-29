import CoreAudio
import XCTest

private final class FakeVolume: OutputVolumeControl {
    var defaultDevice: AudioDeviceID? = 42
    /// Missing entry = device gone or volume not settable.
    var volumes: [AudioDeviceID: Float] = [42: 0.5]
    var uids: [AudioDeviceID: String] = [42: "speakers", 7: "headphones"]
    var setCalls = 0

    func defaultOutputDevice() -> AudioDeviceID? { defaultDevice }
    func volume(of device: AudioDeviceID) -> Float? { volumes[device] }
    func uid(of device: AudioDeviceID) -> String? { uids[device] }
    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool {
        guard volumes[device] != nil else { return false }
        setCalls += 1
        volumes[device] = volume
        return true
    }
}

final class OutputDuckerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var fake: FakeVolume!
    private var logLines: [String] = []

    override func setUp() {
        suiteName = "OutputDuckerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        fake = FakeVolume()
        logLines = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeDucker() -> OutputDucker {
        OutputDucker(control: fake, defaults: defaults, log: { self.logLines.append($0) })
    }

    // AC-1, AC-2: every end path (stop, Esc, error, device loss) ends in `restore()`.
    func testDuckLowersToTenPercentAndRestoreReturnsOriginal() {
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertEqual(fake.volumes[42]!, 0.05, accuracy: 0.0001)
        ducker.restore()
        XCTAssertEqual(fake.volumes[42]!, 0.5, accuracy: 0.0001)
        XCTAssertFalse(ducker.isDucked)
    }

    // AC-2: restore goes to the ducked device even after the default output switched.
    func testRestoreTargetsTheDuckedDeviceAfterDefaultOutputChanged() {
        fake.volumes[7] = 0.8
        let ducker = makeDucker()
        ducker.duck()
        fake.defaultDevice = 7
        ducker.restore()
        XCTAssertEqual(fake.volumes[42]!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(fake.volumes[7]!, 0.8, accuracy: 0.0001)
    }

    // AC-2: the ducked device disappeared (unplugged headphones) — nothing to set, state cleared.
    func testRestoreWithDuckedDeviceGoneClearsState() {
        let ducker = makeDucker()
        ducker.duck()
        fake.volumes[42] = nil
        ducker.restore()
        XCTAssertFalse(ducker.isDucked)
        XCTAssertTrue(logLines.contains { $0.contains("is gone") })
    }

    // A second start while ducked must not record the ducked level as "original".
    func testDuckTwiceKeepsFirstOriginal() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.duck()
        ducker.restore()
        XCTAssertEqual(fake.volumes[42]!, 0.5, accuracy: 0.0001)
    }

    func testRestoreWithoutDuckDoesNothing() {
        makeDucker().restore()
        XCTAssertEqual(fake.setCalls, 0)
    }

    // AC-3
    func testUserChangeDuringRecordingIsKept() {
        let ducker = makeDucker()
        ducker.duck()
        fake.volumes[42] = 0.3
        ducker.restore()
        XCTAssertEqual(fake.volumes[42]!, 0.3, accuracy: 0.0001)
        XCTAssertFalse(ducker.isDucked)
    }

    // AC-4: a fresh instance (next launch) undoes the duck persisted by the crashed one.
    func testRecoverAfterCrashRestoresOriginal() {
        makeDucker().duck()
        XCTAssertEqual(fake.volumes[42]!, 0.05, accuracy: 0.0001)
        let relaunched = makeDucker()
        XCTAssertTrue(relaunched.isDucked)
        relaunched.recoverAfterCrash()
        XCTAssertEqual(fake.volumes[42]!, 0.5, accuracy: 0.0001)
        XCTAssertFalse(relaunched.isDucked)
    }

    // AC-4: after a reboot the stored ID may name another device — leave that one alone.
    func testRecoverySkipsDeviceWhoseUIDChanged() {
        makeDucker().duck()
        fake.uids[42] = "hdmi-monitor"
        fake.volumes[42] = 0.9
        makeDucker().recoverAfterCrash()
        XCTAssertEqual(fake.volumes[42]!, 0.9, accuracy: 0.0001)
    }

    // AC-5
    func testDeviceWithoutSettableVolumeIsSkippedAndLogged() {
        fake.volumes = [:]
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertFalse(ducker.isDucked)
        XCTAssertEqual(fake.setCalls, 0)
        XCTAssertTrue(logLines.contains { $0.contains("no settable volume") })
        ducker.restore()
        XCTAssertEqual(fake.setCalls, 0)
    }

    func testNoDefaultOutputIsSkipped() {
        fake.defaultDevice = nil
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertFalse(ducker.isDucked)
    }
}
