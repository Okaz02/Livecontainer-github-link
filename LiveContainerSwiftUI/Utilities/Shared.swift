import Foundation

struct LCPath {
    static let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
    static let bundlePath = docPath.appendingPathComponent("Applications")
    static let dataPath = docPath.appendingPathComponent("Data/Application")
    static let tweakPath = docPath.appendingPathComponent("Tweaks")

}

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }

    private static var enBundle: Bundle? = {
        let path = Bundle.main.path(forResource: "en", ofType: "lproj")
        return Bundle(path: path!)
    }()

    var loc: String {
        let message = NSLocalizedString(self, comment: "")
        if message != self {
            return message
        }
        return String.enBundle?.localizedString(forKey: self, value: nil, table: nil) ?? self
    }

    func sanitizeNonACSII() -> String {
        filter { $0.isASCII }
    }
}
