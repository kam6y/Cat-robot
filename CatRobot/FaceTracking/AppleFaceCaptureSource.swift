import AVFoundation
import Foundation
import ImageIO
import OSLog
import Vision

/// Main-actor bridge. Creating it neither asks permission nor opens the camera.
@MainActor
final class AppleFaceCaptureSource: FaceCaptureSource {
    private let clock: any RobotClock
    private let stream: AsyncStream<FaceCaptureEvent>
    private let continuation: AsyncStream<FaceCaptureEvent>.Continuation
    private let gate = FaceCaptureGenerationGate()
    private let worker: FaceCaptureWorker

    init(clock: any RobotClock) {
        self.clock = clock
        let channel = FaceCapturePolicy.makeEventStream()
        stream = channel.stream
        continuation = channel.continuation
        worker = FaceCaptureWorker(gate: gate, continuation: channel.continuation)
    }

    deinit {
        gate.replace(with: nil)
        worker.stop()
        continuation.finish()
    }

    var authorization: FaceCameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    func requestAuthorization() async -> FaceCameraAuthorization {
        if authorization == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        return authorization
    }

    func events() -> AsyncStream<FaceCaptureEvent> { stream }

    func start(generation: UUID, orientation: FaceLandscapeOrientation) {
        gate.replace(with: generation)
        let before = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let robotNow = clock.now
        let after = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard authorization == .authorized,
              let mapping = FaceCaptureTimeMapping(hostAnchor: (before + after) / 2, robotAnchor: robotNow) else {
            worker.stop()
            continuation.yield(.unavailable(generation: generation))
            return
        }
        worker.start(generation: generation, orientation: orientation, mapping: mapping)
    }

    func stop() {
        // Invalidate synchronously, including Vision already running on the worker queue.
        gate.replace(with: nil)
        worker.stop()
    }
}

/// This is the only state shared between the main actor and capture queue; every access is locked.
private final class FaceCaptureGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?
    func replace(with value: UUID?) { lock.withLock { generation = value } }
    func isCurrent(_ value: UUID) -> Bool { lock.withLock { generation == value } }
}

/// All mutable AVFoundation/Vision state is confined to `queue`, including delegate callbacks.
/// The Sendable boundary carries only immutable request values and FaceCaptureEvent DTOs.
private final class FaceCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kamby.CatRobot.faceCapture", qos: .userInitiated)
    private let gate: FaceCaptureGenerationGate
    private let continuation: AsyncStream<FaceCaptureEvent>.Continuation
    private let logger = Logger(subsystem: "com.kamby.CatRobot", category: "FaceCapture")
    private var active: CaptureRun?
    private var notificationTokens: [NSObjectProtocol] = []

    private struct CaptureRun {
        let session: AVCaptureSession
        let output: AVCaptureVideoDataOutput
        let generation: UUID
        let orientation: FaceLandscapeOrientation
        let imageOrientation: CGImagePropertyOrientation
        let configuration: FaceCaptureConfiguration
        let optics: FaceCaptureOptics
        let mapping: FaceCaptureTimeMapping
        var previousCaptureTime: TimeInterval?
        var frameCount = 0
    }

    private enum CaptureError: Error { case unsupportedConfiguration }

    init(gate: FaceCaptureGenerationGate, continuation: AsyncStream<FaceCaptureEvent>.Continuation) {
        self.gate = gate
        self.continuation = continuation
    }

    func start(generation: UUID, orientation: FaceLandscapeOrientation, mapping: FaceCaptureTimeMapping) {
        queue.async { [self] in
            stopOnQueue()
            guard gate.isCurrent(generation) else { return }
            do {
                let run = try configure(generation: generation, orientation: orientation, mapping: mapping)
                guard gate.isCurrent(generation) else {
                    run.output.setSampleBufferDelegate(nil, queue: nil)
                    return
                }
                active = run
                observeFailures(of: run.session, generation: generation)
                run.session.startRunning()
                if !gate.isCurrent(generation) { stopOnQueue() }
            } catch {
                fail(generation: generation, interrupted: false)
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        guard let run = active else { return }
        active = nil
        run.output.setSampleBufferDelegate(nil, queue: nil)
        // Even an interrupted/not-yet-running session can retain a start request for foreground return.
        run.session.stopRunning()
    }

    private func configure(generation: UUID, orientation: FaceLandscapeOrientation,
                           mapping: FaceCaptureTimeMapping) throws -> CaptureRun {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CaptureError.unsupportedConfiguration
        }
        let session = AVCaptureSession()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device) // video only; no audio input
        guard session.canAddInput(input), session.canSetSessionPreset(.inputPriority) else {
            throw CaptureError.unsupportedConfiguration
        }
        session.addInput(input)
        session.sessionPreset = .inputPriority
        let descriptors = device.formats.enumerated().map { index, format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return FaceCaptureFormat(id: index, width: Int(size.width), height: Int(size.height),
                horizontalFieldOfView: Double(format.videoFieldOfView),
                frameRateRanges: format.videoSupportedFrameRateRanges.map {
                    .init(minimum: $0.minFrameRate, maximum: $0.maxFrameRate)
                })
        }
        guard let selected = FaceCapturePolicy.select(descriptors) else { throw CaptureError.unsupportedConfiguration }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = device.formats[selected.formatID]
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 5)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 5)
        device.videoZoomFactor = 1
        if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = false }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = false
        guard session.canAddOutput(output) else { throw CaptureError.unsupportedConfiguration }
        session.addOutput(output)
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) else {
            throw CaptureError.unsupportedConfiguration
        }
        connection.videoRotationAngle = 0
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        let pixelFormats = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
        guard let pixelFormat = pixelFormats.first(where: { output.availableVideoPixelFormatTypes.contains($0) }) else {
            throw CaptureError.unsupportedConfiguration
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                                kCVPixelBufferWidthKey as String: selected.width,
                                kCVPixelBufferHeightKey as String: selected.height]
        // iOS 27 supplies the sensor-specific static rotation; never guess from front-camera conventions.
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            .videoRotationAngleRelative(toDeviceOrientation: orientation == .landscapeRight ? .landscapeRight : .landscapeLeft)
        let imageOrientation: CGImagePropertyOrientation
        switch rotation {
        case 0: imageOrientation = .up
        case 90: imageOrientation = .right
        case 180: imageOrientation = .down
        case 270: imageOrientation = .left
        default: throw CaptureError.unsupportedConfiguration
        }
        guard let optics = FaceCapturePolicy.uprightOptics(nativeFieldOfView: selected.horizontalFieldOfView,
            nativeAspect: Double(selected.width) / Double(selected.height), rotationDegrees: Double(rotation)) else {
            throw CaptureError.unsupportedConfiguration
        }
        output.setSampleBufferDelegate(self, queue: queue)
        #if DEBUG
        logger.debug("configured width=\(selected.width) height=\(selected.height) interval=\(selected.frameDuration) rotation=\(Double(rotation))")
        #endif
        return .init(session: session, output: output, generation: generation, orientation: orientation,
                     imageOrientation: imageOrientation, configuration: selected, optics: optics, mapping: mapping)
    }

    private func observeFailures(of session: AVCaptureSession, generation: UUID) {
        for (name, interrupted) in [(AVCaptureSession.wasInterruptedNotification, true),
                                    (AVCaptureSession.runtimeErrorNotification, false)] {
            let token = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [self] in
                    guard active?.generation == generation else { return }
                    fail(generation: generation, interrupted: interrupted)
                }
            }
            notificationTokens.append(token)
        }
    }

    private func fail(generation: UUID, interrupted: Bool) {
        stopOnQueue()
        guard gate.isCurrent(generation) else { return }
        #if DEBUG
        logger.debug("capture unavailable interrupted=\(interrupted)")
        #endif
        continuation.yield(interrupted ? .interrupted(generation: generation) : .unavailable(generation: generation))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var run = active, output === run.output, gate.isCurrent(run.generation) else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let sessionClock = run.session.synchronizationClock else {
            fail(generation: run.generation, interrupted: false)
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostPTS = CMSyncConvertTime(pts, from: sessionClock, to: CMClockGetHostTimeClock())
        guard let capturedAt = run.mapping.robotTime(hostTime: hostPTS.seconds),
              FaceCapturePolicy.acceptsFrame(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                  at: capturedAt, previous: run.previousCaptureTime, configuration: run.configuration) else {
            #if DEBUG
            logger.debug("invalid frame width=\(CVPixelBufferGetWidth(buffer)) height=\(CVPixelBufferGetHeight(buffer))")
            #endif
            fail(generation: run.generation, interrupted: false)
            return
        }
        let interval = run.previousCaptureTime.map { capturedAt - $0 } ?? 0
        run.previousCaptureTime = capturedAt
        run.frameCount += 1
        active = run
        do {
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: run.imageOrientation).perform([request])
            guard gate.isCurrent(run.generation),
                  let completedAt = run.mapping.robotTime(hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds) else { return }
            let faces = (request.results ?? []).map { observation in
                let box = observation.boundingBox
                return FaceCapturePolicy.rawRectangle(fromUpright: .init(x: box.minX, y: box.minY,
                    width: box.width, height: box.height), orientation: run.orientation)
            }
            #if DEBUG
            if run.frameCount == 1 || run.frameCount % 25 == 0 {
                logger.debug("frame width=\(CVPixelBufferGetWidth(buffer)) height=\(CVPixelBufferGetHeight(buffer)) interval=\(interval) processing=\(completedAt - capturedAt) faces=\(faces.count)")
            }
            #endif
            continuation.yield(.observation(.init(generation: run.generation, capturedAt: capturedAt,
                completedAt: completedAt, orientation: run.orientation, horizontalFieldOfView: run.optics.fieldOfView,
                aspectRatio: run.optics.aspectRatio, faces: faces)))
        } catch {
            fail(generation: run.generation, interrupted: false)
        }
    }
}
