import Foundation

enum SpatialCatalog {
    /// Preview/export only. This never inserts example geometry into private storage.
    static func templateData() throws -> Data {
        guard let url = AppResources.bundle.url(forResource: "example", withExtension: "json", subdirectory: "SpatialData") else {
            throw SpatialError.invalid("공간 자료 예시 파일을 찾을 수 없습니다.")
        }
        let data = try SpatialStore.readFile(url)
        _ = try SpatialStore.decode(data)
        return data
    }
}
