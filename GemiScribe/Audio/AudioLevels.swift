import Foundation
import Observation

/// Input levels, kept apart from `AppState` on purpose.
///
/// They change ten times a second. Anything that reads them is re-rendered that often,
/// so they live in their own observable and only the meters read it.
@MainActor
@Observable
final class AudioLevels {
    private(set) var system: Float = 0
    private(set) var microphone: Float = 0

    subscript(source: AudioMixer.Source) -> Float {
        switch source {
        case .system: return system
        case .microphone: return microphone
        }
    }

    /// Ignores changes too small to see, so an idle meter stops invalidating the view.
    func update(_ values: [AudioMixer.Source: Float]) {
        let newSystem = values[.system] ?? 0
        let newMicrophone = values[.microphone] ?? 0
        if abs(newSystem - system) > 0.02 { system = newSystem }
        if abs(newMicrophone - microphone) > 0.02 { microphone = newMicrophone }
    }

    func reset() {
        system = 0
        microphone = 0
    }
}
