import SwiftUI
import UIKit

/// Reads this window's interface orientation, including a 180° landscape turn with unchanged bounds.
struct FaceTrackingOrientationReader: UIViewControllerRepresentable {
    let onChange: @MainActor (FaceLandscapeOrientation) -> Void

    static func orientation(device: UIDeviceOrientation, interface: UIInterfaceOrientation) -> FaceLandscapeOrientation? {
        // UIDevice and UIInterface name landscape directions oppositely (charging-port convention).
        switch device {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: break
        }
        switch interface {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }

    func makeUIViewController(context: Context) -> Reader {
        let reader = Reader()
        reader.onChange = onChange
        return reader
    }

    func updateUIViewController(_ reader: Reader, context: Context) {
        reader.onChange = onChange
    }

    final class Reader: UIViewController {
        var onChange: (@MainActor (FaceLandscapeOrientation) -> Void)?
        private var last: FaceLandscapeOrientation?
        private var generatesNotifications = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if !generatesNotifications {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                generatesNotifications = true
            }
            reportOrientation()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if generatesNotifications {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                generatesNotifications = false
            }
        }

        override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.reportOrientation() }
        }

        func reportOrientation() {
            guard let scene = viewIfLoaded?.window?.windowScene else { return }
            guard let orientation = FaceTrackingOrientationReader.orientation(device: UIDevice.current.orientation,
                interface: scene.effectiveGeometry.interfaceOrientation), orientation != last else { return }
            last = orientation
            onChange?(orientation)
        }
    }
}
