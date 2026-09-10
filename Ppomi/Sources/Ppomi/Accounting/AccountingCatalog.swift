import Foundation

/// Examples and account names are data, never branches in the posting engine.
/// Reading this template does not create a book or insert synthetic entries.
enum AccountingCatalog {
    static func templateData() throws -> Data {
        guard let url = AppResources.bundle.url(forResource: "example", withExtension: "json", subdirectory: "AccountingData") else {
            throw LifeError.missing("분개장 예시 파일을 찾을 수 없습니다.")
        }
        let data = try Data(contentsOf: url)
        let archive = try LifeJSON.decoder().decode(AccountingArchive.self, from: data)
        try AccountingEngine.validate(archive)
        return data
    }
}
