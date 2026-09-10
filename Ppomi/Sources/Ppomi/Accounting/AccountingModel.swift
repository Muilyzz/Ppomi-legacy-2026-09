import Foundation

/// Amounts are positive integers in this unit's smallest precision (10^-scale).
/// A unit is data: the accounting engine does not recognize individual currencies or activities.
struct AccountingUnit: Codable, Equatable {
    enum Dimension: String, Codable { case currency, time, quantity }
    var id: String
    var name: String
    var symbol: String
    var dimension: Dimension
    var scale: Int
}

struct AccountingBook: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case financial, resource }
    var id: String
    var name: String
    var ownerID: String
    var kind: Kind
    var unit: AccountingUnit
    /// Missing scope preserves legacy records as unclassified; it never implies personal ownership.
    var scope: RecordScope?

    init(id: String, name: String, ownerID: String, kind: Kind, unit: AccountingUnit, scope: RecordScope? = nil) {
        self.id = id; self.name = name; self.ownerID = ownerID; self.kind = kind; self.unit = unit; self.scope = scope
    }

    var effectiveScope: RecordScope { scope ?? RecordScope(kind: .unclassified, ownerID: ownerID) }
}

struct AccountingAccount: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case asset, liability, equity, income, expense }
    var id: String
    var bookID: String
    var name: String
    var kind: Kind
    var parentID: String?

    init(id: String, bookID: String, name: String, kind: Kind, parentID: String? = nil) {
        self.id = id; self.bookID = bookID; self.name = name; self.kind = kind; self.parentID = parentID
    }
}

struct AccountingPosting: Codable, Equatable {
    enum Side: String, Codable {
        case debit, credit
        var opposite: Side { self == .debit ? .credit : .debit }
    }
    var accountID: String
    var side: Side
    var amount: Int
}

/// A separate assessment of a source entry. Revisions append a successor instead of changing prior judgments.
struct AccountingAssessment: Codable, Equatable {
    var sourceEntryID: String
    var rationale: String
    var confidenceBasisPoints: Int
    var model: String?
    var replacesEntryID: String?

    init(sourceEntryID: String, rationale: String, confidenceBasisPoints: Int,
         model: String? = nil, replacesEntryID: String? = nil) {
        self.sourceEntryID = sourceEntryID; self.rationale = rationale
        self.confidenceBasisPoints = confidenceBasisPoints; self.model = model
        self.replacesEntryID = replacesEntryID
    }
}

struct AccountingEntry: Codable, Equatable, Identifiable {
    enum Layer: String, Codable { case recorded, adjustment }
    var id: String
    var eventID: String
    var bookID: String
    var occurredAt: Date
    var recordedAt: Date
    var memo: String
    var source: String
    var sourceRecordID: String?
    var postings: [AccountingPosting]
    var layer: Layer
    var assessment: AccountingAssessment?

    init(id: String = UUID().uuidString, eventID: String, bookID: String, occurredAt: Date,
         recordedAt: Date = Date(), memo: String, source: String, sourceRecordID: String? = nil,
         postings: [AccountingPosting], layer: Layer = .recorded, assessment: AccountingAssessment? = nil) {
        self.id = id; self.eventID = eventID; self.bookID = bookID; self.occurredAt = occurredAt
        self.recordedAt = recordedAt; self.memo = memo; self.source = source; self.sourceRecordID = sourceRecordID
        self.postings = postings; self.layer = layer; self.assessment = assessment
    }
}

struct AccountingArchive: Codable, Equatable {
    var formatVersion: Int
    var books: [AccountingBook]
    var accounts: [AccountingAccount]
    var entries: [AccountingEntry]

    init(formatVersion: Int = 1, books: [AccountingBook] = [], accounts: [AccountingAccount] = [],
         entries: [AccountingEntry] = []) {
        self.formatVersion = formatVersion; self.books = books; self.accounts = accounts; self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, books, accounts, entries }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        books = try values.decodeIfPresent([AccountingBook].self, forKey: .books) ?? []
        accounts = try values.decodeIfPresent([AccountingAccount].self, forKey: .accounts) ?? []
        entries = try values.decodeIfPresent([AccountingEntry].self, forKey: .entries) ?? []
    }
}

enum AccountingError: LocalizedError {
    case validation(String), conflict(String), database(String)
    var errorDescription: String? {
        switch self {
        case .validation(let message), .conflict(let message), .database(let message): return message
        }
    }
}
