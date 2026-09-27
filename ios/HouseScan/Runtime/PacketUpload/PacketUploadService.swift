import Foundation
import HouseScanKit
import OSLog
import UIKit

/// Sends capture packets the homeowner chose to send, through the selected `PacketIntake`, and
/// picks up unfinished ones at launch. One per process, because a background session's
/// identifier can be in use only once.
///
/// An endpoint turns on the offer and the consent screen; sending also needs an intake
/// (`PacketIntakes`). With an endpoint and no intake, Send fails loudly and nothing leaves the
/// phone. The background session is made only when something is actually sent.
///
/// On disk, in a scan's folder: `packet-sending/`, the packet as it was when Send was pressed
/// (moved out of `packet/`, which the next bundle rewrites), and `packet-upload.json`
/// (`PacketUploadState`), saved after every change. While that file exists the folder outlives
/// launches (`KeyframeStore` leaves it); both go once the server says the packet is complete, or
/// when the scan is started over.
@MainActor
final class PacketUploadService {
    static let shared: PacketUploadService = {
        let options = LaunchOptions()
        return PacketUploadService(endpoint: options.packetUpload, intake: PacketIntakes.make(options))
    }()

    static let sendingFolderName = "packet-sending"

    let endpoint: PacketUploadEndpoint?
    private let intake: (any PacketIntake)?
    /// Whether the result offers to send the packet.
    var isEnabled: Bool { endpoint != nil }
    /// Whether Send can reach a server: an intake adapter is selected.
    var canSend: Bool { intake != nil }

    private struct Job {
        var task: Task<Void, Never>?
        var consent: PacketUploadConsent
        var onStatus: ((PacketUploadStatus) -> Void)?
        /// The last progress shown, and when, to update the screen a few times a second at most.
        var lastProgress: PacketUploadProgress?
        var lastReport = Date.distantPast
    }

    private var jobs: [URL: Job] = [:]
    private var transportInstance: BackgroundPacketTransport?
    private var eventsCompletion: (() -> Void)?

    init(endpoint: PacketUploadEndpoint?, intake: (any PacketIntake)?) {
        self.endpoint = endpoint
        self.intake = intake
    }

    /// Created on first use only, so a build without an endpoint never makes a background session.
    private var transport: BackgroundPacketTransport {
        if let transportInstance { return transportInstance }
        let made = BackgroundPacketTransport { [weak self] in
            Task { @MainActor in self?.finishEvents() }
        }
        transportInstance = made
        return made
    }

    // MARK: Launch

    /// At launch: resumes every unfinished upload a previous launch left, or, with nothing to
    /// send them through, deletes those scans like any other old scan.
    func resumePending() {
        let scans = KeyframeStore.scansDirectory
        let folders = (try? FileManager.default.contentsOfDirectory(at: scans, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let file = folder.appending(path: PacketUploadState.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard intake != nil, var state = try? PacketUploadState.load(from: file) else {
                RuntimeLog.engine.info("packet upload: dropping \(folder.lastPathComponent, privacy: .public) (\(self.intake == nil ? "no intake" : "unreadable state", privacy: .public))")
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            switch state.phase {
            case .complete:
                try? FileManager.default.removeItem(at: folder)
                continue
            case .failed(let failure) where !failure.isTransient:
                RuntimeLog.engine.error("packet upload: dropping \(folder.lastPathComponent, privacy: .public): \(failure.description, privacy: .public)")
                try? FileManager.default.removeItem(at: folder)
                continue
            case .failed, .sending:
                break
            }
            // A new launch gets a new retry budget; the waits still start where they were.
            if case .failed = state.phase { state.attempts = [:] }
            RuntimeLog.engine.info("packet upload: resuming \(folder.lastPathComponent, privacy: .public), \(state.stored.count) of \(state.request.files.count) files stored")
            jobs[folder] = Job(consent: state.request.consent)
            run(folder) { uploader, persist, events in
                await uploader.resume(state, folder: folder.appending(path: Self.sendingFolderName), persist: persist, events: events)
            }
        }
    }

    /// The system relaunched or woke the app for the background session's finished transfers.
    /// Their results reach the transport once the session exists again.
    func handleEvents(for identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundPacketTransport.identifier, intake != nil else {
            completion()
            return
        }
        eventsCompletion = completion
        _ = transport
    }

    private func finishEvents() {
        eventsCompletion?()
        eventsCompletion = nil
    }

    // MARK: A scan's upload

    /// Sends the packet in `packetFolder` for the scan in `scanFolder`, with the homeowner's
    /// consent. The packet moves to `packet-sending/`, so the next bundle can't change it.
    func send(scanFolder: URL, packetFolder: URL, consent: PacketUploadConsent, onStatus: @escaping (PacketUploadStatus) -> Void) {
        guard isEnabled, jobs[scanFolder] == nil else { return }
        guard intake != nil else {
            RuntimeLog.engine.error("packet upload: no intake is selected for \(self.endpoint?.baseURL.absoluteString ?? "", privacy: .public); nothing sent")
            onStatus(.failed(nil))
            return
        }
        let sending = scanFolder.appending(path: Self.sendingFolderName)
        do {
            try? FileManager.default.removeItem(at: sending)
            try FileManager.default.moveItem(at: packetFolder, to: sending)
        } catch {
            RuntimeLog.engine.error("packet upload: packet not moved for sending: \(String(describing: error), privacy: .public)")
            onStatus(.failed(nil))
            return
        }
        jobs[scanFolder] = Job(consent: consent, onStatus: onStatus)
        start(scanFolder)
    }

    /// "Try again": carries on from the saved state, or starts over from the packet when no
    /// state was saved (reading it failed).
    func retry(scanFolder: URL) {
        guard intake != nil, var job = jobs[scanFolder], job.task == nil else { return }
        job.lastProgress = nil
        jobs[scanFolder] = job
        let file = scanFolder.appending(path: PacketUploadState.fileName)
        guard var state = try? PacketUploadState.load(from: file) else {
            start(scanFolder)
            return
        }
        state.attempts = [:]
        report(scanFolder, .preparing)
        run(scanFolder) { uploader, persist, events in
            await uploader.resume(state, folder: scanFolder.appending(path: Self.sendingFolderName), persist: persist, events: events)
        }
    }

    /// "Start over": stops the scan's upload and cancels its transfers. Deletes the saved state
    /// now, so `KeyframeStore` deletes the folder with the rest of the scan.
    func cancel(scanFolder: URL) {
        let job = jobs.removeValue(forKey: scanFolder)
        job?.task?.cancel()
        let file = scanFolder.appending(path: PacketUploadState.fileName)
        if let state = try? PacketUploadState.load(from: file) {
            transportInstance?.cancelTransfers(scanID: state.scanID)
        }
        try? FileManager.default.removeItem(at: file)
        if job != nil { RuntimeLog.engine.info("packet upload: cancelled for \(scanFolder.lastPathComponent, privacy: .public)") }
    }

    private func start(_ scanFolder: URL) {
        guard let consent = jobs[scanFolder]?.consent else { return }
        let sending = scanFolder.appending(path: Self.sendingFolderName)
        let scanID = scanFolder.lastPathComponent.lowercased()
        report(scanFolder, .preparing)
        run(scanFolder) { uploader, persist, events in
            // Hashing the packet reads all of it: off the main actor.
            let read = await Task.detached(priority: .userInitiated) { Result { try PacketUploadPacket.read(folder: sending) } }.value
            switch read {
            case .success(let packet):
                return await uploader.send(packet, scanID: scanID, consent: consent, folder: sending, persist: persist, events: events)
            case .failure(let error):
                RuntimeLog.engine.error("packet upload: packet unreadable: \(String(describing: error), privacy: .public)")
                return .failed(.packetChanged(String(describing: error)))
            }
        }
    }

    private typealias Persist = @Sendable (PacketUploadState) async -> Void
    private typealias Events = @Sendable (PacketUploadEvent) -> Void

    private func run(_ scanFolder: URL, _ body: @escaping @MainActor (PacketUploader, @escaping Persist, @escaping Events) async -> PacketUploadResult) {
        guard let intake else { return }
        let uploader = PacketUploader(intake: intake, transport: transport)
        let persist: Persist = { [weak self] state in await self?.save(state, scanFolder) }
        let events: Events = { [weak self] event in Task { @MainActor in self?.handle(event, scanFolder) } }
        let task = Task { @MainActor [weak self] in
            let result = await body(uploader, persist, events)
            self?.finish(scanFolder, result)
        }
        jobs[scanFolder]?.task = task
    }

    private func save(_ state: PacketUploadState, _ scanFolder: URL) {
        // A cancelled upload must not write its state back: the folder is about to go.
        guard jobs[scanFolder] != nil else { return }
        do {
            try state.save(to: scanFolder.appending(path: PacketUploadState.fileName))
        } catch {
            RuntimeLog.engine.error("packet upload: state not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private func handle(_ event: PacketUploadEvent, _ scanFolder: URL) {
        guard var job = jobs[scanFolder], job.task != nil else { return }
        switch event {
        case .sending(let progress):
            // Byte counts arrive many times a second; a finished file always shows.
            let now = Date()
            guard progress.filesSent != job.lastProgress?.filesSent || now.timeIntervalSince(job.lastReport) >= 0.25 else { return }
            job.lastProgress = progress
            job.lastReport = now
            jobs[scanFolder] = job
            report(scanFolder, .sending(progress))
        case .waiting(let progress, let after):
            RuntimeLog.engine.info("packet upload: retrying in \(after) s")
            job.lastProgress = progress
            jobs[scanFolder] = job
            report(scanFolder, .waiting(progress))
        }
    }

    private func finish(_ scanFolder: URL, _ result: PacketUploadResult) {
        guard var job = jobs[scanFolder] else { return }
        job.task = nil
        jobs[scanFolder] = job
        let progress = job.lastProgress
        switch result {
        case .sent(let reference):
            RuntimeLog.engine.info("packet upload: complete for \(scanFolder.lastPathComponent, privacy: .public)\(reference.map { ", reference \($0)" } ?? "", privacy: .public)")
            report(scanFolder, .sent)
            // The server has it all; the copy and the state go. The scan itself stays until the
            // next scan, for Share scan.
            jobs[scanFolder] = nil
            let sending = scanFolder.appending(path: Self.sendingFolderName)
            let file = scanFolder.appending(path: PacketUploadState.fileName)
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: sending)
            }
        case .failed(let failure):
            RuntimeLog.engine.error("packet upload failed: \(failure.description, privacy: .public)")
            report(scanFolder, .failed(progress))
        case .cancelled, .disabled, .notConsented:
            break
        }
    }

    private func report(_ scanFolder: URL, _ status: PacketUploadStatus) {
        jobs[scanFolder]?.onStatus?(status)
    }
}
