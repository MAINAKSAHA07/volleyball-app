//
//  PNGExportDocument.swift
//  BeeDataLoggerApp
//
//  FileDocument wrapper for exporting chart snapshots as PNG.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PNGExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Renders SwiftUI views (including Charts) to PNG for sharing / Files.
enum ChartImageExport {
    @MainActor
    static func pngData<V: View>(
        preferredSize: CGSize,
        scale: CGFloat = 3,
        @ViewBuilder content: () -> V
    ) -> Data? {
        let view = content()
            .frame(width: preferredSize.width, height: preferredSize.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage?.pngData()
    }
}
