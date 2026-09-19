import Foundation

/// The small, server-owned result needed after a direct attachment stage.
/// Returned paths and `ref_text` are preserved exactly; this type never derives
/// a path from a client filename or stores a client filesystem location.
struct DirectGatewayAttachmentReceipt: Equatable, Sendable {
    let kind: DirectGatewayAttachmentKind
    let referenceText: String?
    let detachPaths: [String]
    let filename: String?
    let pdfPageCount: Int?

    private init(
        kind: DirectGatewayAttachmentKind,
        referenceText: String?,
        detachPaths: [String],
        filename: String?,
        pdfPageCount: Int?
    ) {
        self.kind = kind
        self.referenceText = referenceText
        self.detachPaths = detachPaths
        self.filename = filename
        self.pdfPageCount = pdfPageCount
    }

    static func image(from result: JSONValue?) throws -> Self {
        let fields = try responseFields(result)
        try requireAttached(fields)
        let path = try requiredString(fields["path"])
        return Self(
            kind: .image,
            referenceText: nil,
            detachPaths: [path],
            filename: optionalString(fields["name"]),
            pdfPageCount: nil
        )
    }

    static func file(from result: JSONValue?) throws -> Self {
        let fields = try responseFields(result)
        try requireAttached(fields)
        let referenceText = try requiredString(fields["ref_text"])
        guard referenceText.hasPrefix("@file:"),
              !referenceText.dropFirst("@file:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectGatewayAttachmentReceiptError.missingReference
        }
        return Self(
            kind: .file,
            referenceText: referenceText,
            detachPaths: [],
            filename: optionalString(fields["name"]),
            pdfPageCount: nil
        )
    }

    static func pdf(from result: JSONValue?) throws -> Self {
        let fields = try responseFields(result)
        try requireAttached(fields)
        let pageCount = try requiredPositiveInt(fields["pages_attached"])
        guard case .array(let rawPages) = fields["pages"],
              rawPages.count == pageCount,
              !rawPages.isEmpty else {
            throw DirectGatewayAttachmentReceiptError.inconsistentPDFPages
        }

        var paths: [String] = []
        var pageNumbers = Set<Int>()
        for rawPage in rawPages {
            guard case .object(let page) = rawPage else {
                throw DirectGatewayAttachmentReceiptError.inconsistentPDFPages
            }
            let path = try requiredString(page["path"])
            let pageNumber = try requiredPositiveInt(page["page"])
            guard pageNumbers.insert(pageNumber).inserted else {
                throw DirectGatewayAttachmentReceiptError.inconsistentPDFPages
            }
            paths.append(path)
        }

        return Self(
            kind: .pdf,
            referenceText: nil,
            detachPaths: paths,
            filename: optionalString(fields["filename"]),
            pdfPageCount: pageCount
        )
    }

    private static func responseFields(_ result: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let fields) = result else {
            throw DirectGatewayAttachmentReceiptError.malformedResponse
        }
        return fields
    }

    private static func requireAttached(_ fields: [String: JSONValue]) throws {
        guard fields["attached"] == .bool(true) else {
            throw DirectGatewayAttachmentReceiptError.notAttached
        }
    }

    private static func requiredString(_ value: JSONValue?) throws -> String {
        guard case .string(let value) = value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectGatewayAttachmentReceiptError.missingReference
        }
        return value
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { return nil }
        return string
    }

    private static func requiredPositiveInt(_ value: JSONValue?) throws -> Int {
        guard case .number(let number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= 1,
              number < Double(Int.max) else {
            throw DirectGatewayAttachmentReceiptError.inconsistentPDFPages
        }
        return Int(number)
    }
}

enum DirectGatewayAttachmentReceiptError: Error, Equatable, Sendable {
    case malformedResponse
    case notAttached
    case missingReference
    case inconsistentPDFPages
}
