import Combine
import Foundation
import SwiftUI
import Translation

@MainActor
final class TranslationService: ObservableObject {
    enum ServiceError: LocalizedError {
        case requestAlreadyRunning

        var errorDescription: String? {
            "Another translation is already running."
        }
    }

    struct Request {
        let id = UUID()
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    @Published fileprivate var configuration: TranslationSession.Configuration?
    fileprivate var request: Request?
    private var hostWindow: NSWindow?

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard request == nil else { throw ServiceError.requestAlreadyRunning }

        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)

        if #available(macOS 26.0, *) {
            let availability = await LanguageAvailability().status(
                from: sourceLanguage,
                to: targetLanguage
            )
            if availability == .installed {
                let session = TranslationSession(
                    installedSource: sourceLanguage,
                    target: targetLanguage
                )
                return try await session.translate(text).targetText
            }
        }

        ensureHostIsInstalled()

        return try await withCheckedThrowingContinuation { continuation in
            request = Request(text: text, continuation: continuation)
            configuration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: targetLanguage
            )
            showHostIfNeeded()
        }
    }

    fileprivate func perform(using session: TranslationSession) async {
        guard let request else { return }

        do {
            let response = try await session.translate(request.text)
            finish(request, with: .success(response.targetText))
        } catch {
            finish(request, with: .failure(error))
        }
    }

    private func finish(_ completedRequest: Request, with result: Result<String, Error>) {
        guard request?.id == completedRequest.id else { return }
        request = nil
        configuration = nil
        hostWindow?.orderOut(nil)
        completedRequest.continuation.resume(with: result)
    }

    private func ensureHostIsInstalled() {
        guard hostWindow == nil else { return }

        let host = NSHostingController(rootView: TranslationHostView(service: self))
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hostWindow = window
    }

    fileprivate func showHostIfNeeded() {
        guard let window = hostWindow, !window.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x + 10, y: mouse.y - window.frame.height - 10))
        window.orderFrontRegardless()
        NSApp.activate()
    }
}

private struct TranslationHostView: View {
    @ObservedObject var service: TranslationService

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing system translation…")
                .font(.callout)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .translationTask(service.configuration) { session in
            await service.perform(using: session)
        }
    }
}
