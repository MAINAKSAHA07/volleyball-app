//
//  DocumentExportPicker.swift
//  BeeDataLoggerApp
//
//  UIDocumentPicker export — reliable Save-to-Files on iPhone, iPad, and My Mac (Designed for iPad).
//

import SwiftUI
import UIKit

struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool
    var onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onFinished: onFinished)
    }

    func makeUIViewController(context: Context) -> DocumentExportAnchorViewController {
        let host = DocumentExportAnchorViewController()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(_ host: DocumentExportAnchorViewController, context: Context) {
        host.exportURL = url
        if !isPresented {
            host.resetPresentation()
        }
        host.tryPresentExportPicker()
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        @Binding var isPresented: Bool
        let onFinished: () -> Void

        init(isPresented: Binding<Bool>, onFinished: @escaping () -> Void) {
            _isPresented = isPresented
            self.onFinished = onFinished
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish()
        }

        private func finish() {
            isPresented = false
            onFinished()
        }
    }
}

/// Presents the export picker from `viewDidAppear` so the host is in the window hierarchy.
final class DocumentExportAnchorViewController: UIViewController {
    weak var coordinator: DocumentExportPicker.Coordinator?
    var exportURL: URL?
    private var didPresent = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tryPresentExportPicker()
    }

    func resetPresentation() {
        didPresent = false
    }

    func tryPresentExportPicker() {
        guard !didPresent, let url = exportURL, FileManager.default.fileExists(atPath: url.path) else { return }

        let presenter = Self.topViewController(startingFrom: self) ?? self
        guard presenter.presentedViewController == nil else { return }
        didPresent = true

        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = coordinator
        if let popover = picker.popoverPresentationController, let anchor = presenter.view {
            popover.sourceView = anchor
            let bounds = anchor.bounds
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(picker, animated: true)
    }

    private static func topViewController(startingFrom root: UIViewController) -> UIViewController? {
        if let windowRoot = keyWindowRootViewController() {
            return walkTop(from: windowRoot)
        }
        return walkTop(from: root)
    }

    private static func keyWindowRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    private static func walkTop(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return walkTop(from: presented)
        }
        if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
            return walkTop(from: visible)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return walkTop(from: selected)
        }
        return vc
    }
}

enum ExportStaging {
    private static var stagingDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BDLExportStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(data: Data, filename: String) throws -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let url = stagingDirectory.appendingPathComponent(safe)
        try data.write(to: url, options: [.atomic])
        return url
    }

    static func write(text: String, filename: String) throws -> URL {
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "ExportStaging", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode export as UTF-8."
            ])
        }
        return try write(data: data, filename: filename)
    }

    static func cleanup(_ url: URL?) {
        guard let url else { return }
        guard url.path.contains("BDLExportStaging") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
