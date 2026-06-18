//
//  CSVExportDocument.swift
//  BeeDataLoggerApp
//
//  FileDocument wrapper for exporting recorded readings to CSV.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CSVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var data: Data

    init(csvString: String) {
        self.data = Data(csvString.utf8)
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

