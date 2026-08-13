import AVKit
import SwiftUI
import LiveKit

/// A LiveKit video renderer backed by iOS's native video-call Picture in Picture surface.
///
/// The inline and PiP renderers deliberately use `AVSampleBufferDisplayLayer` instead of Metal:
/// iOS suspends GPU work when an app backgrounds, while the sample-buffer path is safe to keep
/// rendering inside `AVPictureInPictureVideoCallViewController`.
struct SystemPictureInPictureVideoView: UIViewRepresentable {
    let track: VideoTrack
    @Binding var isRequested: Bool

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func makeCoordinator() -> Coordinator {
        Coordinator(isRequested: $isRequested)
    }

    func makeUIView(context: Context) -> VideoView {
        let videoView = VideoView()
        videoView.backgroundColor = .black
        videoView.renderMode = .sampleBuffer
        videoView.layoutMode = .fit
        videoView.pinchToZoomOptions = [.zoomIn, .zoomOut, .resetOnRelease]
        videoView.track = track
        context.coordinator.install(inlineVideoView: videoView, track: track)
        return videoView
    }

    func updateUIView(_ videoView: VideoView, context: Context) {
        videoView.track = track
        context.coordinator.update(binding: $isRequested, track: track, requested: isRequested)
    }

    static func dismantleUIView(_ videoView: VideoView, coordinator: Coordinator) {
        coordinator.tearDown()
        videoView.track = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
        private var isRequested: Binding<Bool>
        private weak var inlineVideoView: VideoView?
        private var pictureInPictureVideoView: VideoView?
        private var pictureInPictureViewController: AVPictureInPictureVideoCallViewController?
        private var pictureInPictureController: AVPictureInPictureController?
        private var possibleObservation: NSKeyValueObservation?
        private var requested = false

        init(isRequested: Binding<Bool>) {
            self.isRequested = isRequested
        }

        func install(inlineVideoView: VideoView, track: VideoTrack) {
            self.inlineVideoView = inlineVideoView
            guard Self.isPictureInPictureSupported else { return }

            let pipVideoView = VideoView()
            pipVideoView.backgroundColor = .black
            pipVideoView.renderMode = .sampleBuffer
            pipVideoView.layoutMode = .fit
            pipVideoView.track = track

            let pipViewController = AVPictureInPictureVideoCallViewController()
            pipViewController.preferredContentSize = CGSize(width: 16, height: 9)
            pipViewController.view.backgroundColor = .black
            pipVideoView.translatesAutoresizingMaskIntoConstraints = false
            pipViewController.view.addSubview(pipVideoView)
            NSLayoutConstraint.activate([
                pipVideoView.leadingAnchor.constraint(equalTo: pipViewController.view.leadingAnchor),
                pipVideoView.trailingAnchor.constraint(equalTo: pipViewController.view.trailingAnchor),
                pipVideoView.topAnchor.constraint(equalTo: pipViewController.view.topAnchor),
                pipVideoView.bottomAnchor.constraint(equalTo: pipViewController.view.bottomAnchor),
            ])

            let source = AVPictureInPictureController.ContentSource(
                activeVideoCallSourceView: inlineVideoView,
                contentViewController: pipViewController)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            // A call can contain several shared windows, and SwiftUI may keep off-screen TabView
            // pages alive. Automatic PiP on every page would let multiple controllers race when the
            // app backgrounds, so PiP starts only from the visible pane's explicit button.
            controller.canStartPictureInPictureAutomaticallyFromInline = false

            pictureInPictureVideoView = pipVideoView
            pictureInPictureViewController = pipViewController
            pictureInPictureController = controller
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.applyRequest() }
            }
        }

        func update(binding: Binding<Bool>, track: VideoTrack, requested: Bool) {
            isRequested = binding
            self.requested = requested
            pictureInPictureVideoView?.track = track
            applyRequest()
        }

        private func applyRequest() {
            guard let controller = pictureInPictureController else {
                if requested { setRequested(false) }
                return
            }
            if requested {
                guard !controller.isPictureInPictureActive,
                      controller.isPictureInPicturePossible else { return }
                controller.startPictureInPicture()
            } else if controller.isPictureInPictureActive {
                controller.stopPictureInPicture()
            }
        }

        private func setRequested(_ value: Bool) {
            requested = value
            guard isRequested.wrappedValue != value else { return }
            isRequested.wrappedValue = value
        }

        func tearDown() {
            possibleObservation?.invalidate()
            possibleObservation = nil
            if pictureInPictureController?.isPictureInPictureActive == true {
                pictureInPictureController?.stopPictureInPicture()
            }
            pictureInPictureController?.delegate = nil
            pictureInPictureController?.contentSource = nil
            pictureInPictureController = nil
            pictureInPictureVideoView?.track = nil
            pictureInPictureVideoView?.removeFromSuperview()
            pictureInPictureVideoView = nil
            pictureInPictureViewController = nil
            inlineVideoView = nil
        }

        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            setRequested(true)
        }

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            setRequested(false)
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
                @escaping (Bool) -> Void
        ) {
            // The source pane remains mounted in the call UI, so bringing JoeScreen forward is all
            // the system needs to restore the inline renderer.
            completionHandler(true)
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: any Error
        ) {
            setRequested(false)
        }

        private static var isPictureInPictureSupported: Bool {
            AVPictureInPictureController.isPictureInPictureSupported()
        }
    }
}
