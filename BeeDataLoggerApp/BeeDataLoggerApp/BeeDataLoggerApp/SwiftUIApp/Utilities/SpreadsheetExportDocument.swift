//
//  SpreadsheetExportDocument.swift
//  BeeDataLoggerApp
//
//  FileDocument for multi-sheet Excel XML (.xls) exports.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SpreadsheetExportDocument: FileDocument {
    /// SpreadsheetML is XML; use `.xml` so `fileExporter` matches the payload (legacy `.xls` UTType is binary Excel).
    static var readableContentTypes: [UTType] { [.xml] }
    static var exportContentType: UTType { .xml }

    var data: Data

    init(workbookData: Data) {
        self.data = workbookData
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
