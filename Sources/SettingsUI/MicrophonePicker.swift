import SwiftUI

/// Input device picker shared by the menu bar submenu and the settings tab.
struct MicrophonePicker: View {
    let label: String

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var deviceManager: AudioDeviceManager

    var body: some View {
        Picker(label, selection: $settings.selectedMicrophoneUID) {
            Text("System Default").tag(nil as String?)
            ForEach(deviceManager.inputDevices) { device in
                Text(device.name).tag(device.uid as String?)
            }
        }
    }
}
