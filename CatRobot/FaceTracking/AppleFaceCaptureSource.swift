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

    func start(generation: UUID) {
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
        worker.start(generation: generation, mapping: mapping)
    }

    func requestSnapshot(id: UUID, generation: UUID,
                         completion: @escaping @Sendable (Result<CameraSnapshot, CameraSnapshotError>) -> Void) {
        worker.requestSnapshot(id: id, generation: generation, completion: completion)
    }

    func cancelSnapshot(id: UUID) { worker.cancelSnapshot(id: id) }

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
/// Only immutable events and explicitly requested CGImages cross the Sendable boundary.
private final class FaceCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kamby.CatRobot.faceCapture", qos: .userInitiated)
    private let gate: FaceCaptureGenerationGate
    private let continuation: AsyncStream<FaceCaptureEvent>.Continuation
    private let logger = Logger(subsystem: "com.kamby.CatRobot", category: "FaceCapture")
    private var active: CaptureRun?
    private var notificationTokens: [NSObjectProtocol] = []
    private var frameCache = CameraFrameCache()
    private var snapshotRequest: SnapshotRequest?

    private struct SnapshotRequest {
        let id: UUID
        let generation: UUID
        let completion: @Sendable (Result<CameraSnapshot, CameraSnapshotError>) -> Void
    }

    private struct CaptureRun {
        let session: AVCaptureSession
        let output: AVCaptureVideoDataOutput
        let generation: UUID
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

    func start(generation: UUID, mapping: FaceCaptureTimeMapping) {
        queue.async { [self] in
            stopOnQueue()
            guard gate.isCurrent(generation) else { return }
            do {
                let run = try configure(generation: generation, mapping: mapping)
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

    func requestSnapshot(id: UUID, generation: UUID,
                         completion: @escaping @Sendable (Result<CameraSnapshot, CameraSnapshotError>) -> Void) {
        queue.async { [self] in
            guard gate.isCurrent(generation), active?.generation == generation else {
                completion(.failure(.unavailable))
                return
            }
            guard snapshotRequest == nil else { completion(.failure(.busy)); return }
            snapshotRequest = .init(id: id, generation: generation, completion: completion)
            fulfillSnapshotIfFresh()
        }
    }

    func cancelSnapshot(id: UUID) {
        queue.async { [self] in if snapshotRequest?.id == id { snapshotRequest = nil } }
    }

    private func fulfillSnapshotIfFresh() {
        guard let request = snapshotRequest, let run = active,
              request.generation == run.generation, gate.isCurrent(run.generation),
              let now = run.mapping.robotTime(hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds) else { return }
        do {
            guard let snapshot = try frameCache.snapshot(generation: run.generation, now: now) else { return }
            guard gate.isCurrent(run.generation) else { return }
            snapshotRequest = nil
            request.completion(.success(snapshot))
        } catch {
            snapshotRequest = nil
            request.completion(.failure(.unavailable))
        }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        frameCache.clear()
        snapshotRequest = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        guard let run = active else { return }
        active = nil
        run.output.setSampleBufferDelegate(nil, queue: nil)
        // Even an interrupted/not-yet-running session can retain a start request for foreground return.
        run.session.stopRunning()
    }

    private func configure(generation: UUID,
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
        let frameDuration = CMTime(seconds: selected.frameDuration, preferredTimescale: 600)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
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
        // The mount fixes the front camera to the screen's left (port on the right).
        // iOS 27 supplies the sensor-specific rotation for that fixed orientation.
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            .videoRotationAngleRelative(toDeviceOrientation: .landscapeRight)
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
        return .init(session: session, output: output, generation: generation,
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
        let mappedCaptureTime = run.mapping.robotTime(hostTime: hostPTS.seconds)
        guard let capturedAt = mappedCaptureTime,
              FaceCapturePolicy.acceptsFrame(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                  at: capturedAt, previous: run.previousCaptureTime, configuration: run.configuration) else {
            #if DEBUG
            let delta = mappedCaptureTime.flatMap { current in run.previousCaptureTime.map { current - $0 } } ?? -1
            logger.debug("invalid frame width=\(CVPixelBufferGetWidth(buffer)) height=\(CVPixelBufferGetHeight(buffer)) interval=\(delta) configured=\(run.configuration.frameDuration) minimum=0.2 captured=\(mappedCaptureTime ?? -1) previous=\(run.previousCaptureTime ?? -1) hostPTS=\(hostPTS.seconds) frames=\(run.frameCount)")
            #endif
            fail(generation: run.generation, interrupted: false)
            return
        }
        let interval = run.previousCaptureTime.map { capturedAt - $0 } ?? 0
        run.previousCaptureTime = capturedAt
        run.frameCount += 1
        active = run
        frameCache.store(buffer, generation: run.generation, capturedAt: capturedAt,
                         imageOrientation: run.imageOrientation)
        fulfillSnapshotIfFresh()
        do {
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: run.imageOrientation).perform([request])
            guard gate.isCurrent(run.generation),
                  let completedAt = run.mapping.robotTime(hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds) else { return }
            let faces = (request.results ?? []).map { observation in
                let box = observation.boundingBox
                return FaceRectangle(x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
            #if DEBUG
            if run.frameCount == 1 || run.frameCount % 25 == 0 {
                logger.debug("frame width=\(CVPixelBufferGetWidth(buffer)) height=\(CVPixelBufferGetHeight(buffer)) interval=\(interval) processing=\(completedAt - capturedAt) faces=\(faces.count) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
            }
            #endif
            continuation.yield(.observation(.init(generation: run.generation, capturedAt: capturedAt,
                completedAt: completedAt, horizontalFieldOfView: run.optics.fieldOfView,
                aspectRatio: run.optics.aspectRatio, faces: faces)))
        } catch {
            fail(generation: run.generation, interrupted: false)
        }
    }
}
