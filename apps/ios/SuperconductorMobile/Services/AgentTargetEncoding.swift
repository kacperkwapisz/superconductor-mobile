import Foundation

enum AgentTargetEncoding {
    static func encode(_ target: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
    }
}