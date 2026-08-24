import Foundation

enum AppResources {
    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        let bundledResource = Bundle.main.resourceURL?
            .appendingPathComponent("BBCD4Mac_BBCD4Mac.bundle", isDirectory: true)
        let resourceBundle = bundledResource.flatMap(Bundle.init(url:))

        return Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? resourceBundle?.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.allBundles.lazy
                .compactMap { $0.url(forResource: name, withExtension: fileExtension) }
                .first
    }
}
