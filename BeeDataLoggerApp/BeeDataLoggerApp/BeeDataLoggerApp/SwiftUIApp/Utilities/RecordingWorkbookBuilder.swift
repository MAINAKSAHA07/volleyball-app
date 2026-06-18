//
//  RecordingWorkbookBuilder.swift
//  BeeDataLoggerApp
//
//  Excel-compatible workbook (SpreadsheetML) with one worksheet tab per pair.
//

import Foundation

enum RecordingWorkbookBuilder {

    struct Sheet {
        let name: String
        /// First row = column headers; following rows = data (same column count).
        let rows: [[String]]
    }

    /// Excel 2003 XML — opens in Excel / Numbers with separate tabs per worksheet.
    static func buildSpreadsheetML(sheets: [Sheet]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?mso-application progid="Excel.Sheet"?>
        <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
         xmlns:o="urn:schemas-microsoft-com:office:office"
         xmlns:x="urn:schemas-microsoft-com:office:excel"
         xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
        <Styles>
          <Style ss:ID="hdr"><Font ss:Bold="1"/></Style>
        </Styles>

        """
        for sheet in sheets where !sheet.rows.isEmpty {
            xml += worksheetXML(name: sheet.name, rows: sheet.rows)
        }
        xml += "</Workbook>"
        return Data(xml.utf8)
    }

    /// True when the workbook XML includes at least one worksheet (non-empty export).
    static func containsWorksheets(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("<Worksheet")
    }

    static func sanitizeSheetName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: ":\\/?*[]")
        var s = name.components(separatedBy: bad).joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "Sheet" }
        if s.count > 31 { s = String(s.prefix(31)) }
        return s
    }

    private static func worksheetXML(name: String, rows: [[String]]) -> String {
        var out = "<Worksheet ss:Name=\"\(xmlEscape(sanitizeSheetName(name)))\"><Table>\n"
        for (i, row) in rows.enumerated() {
            let rowTag = i == 0 ? "<Row ss:StyleID=\"hdr\">" : "<Row>"
            out += rowTag
            for cell in row {
                out += cellXML(cell, header: i == 0)
            }
            out += "</Row>\n"
        }
        out += "</Table></Worksheet>\n"
        return out
    }

    private static func cellXML(_ value: String, header: Bool) -> String {
        if Double(value) != nil, !header, value.rangeOfCharacter(from: CharacterSet.letters) == nil {
            return "<Cell><Data ss:Type=\"Number\">\(value)</Data></Cell>"
        }
        return "<Cell><Data ss:Type=\"String\">\(xmlEscape(value))</Data></Cell>"
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
