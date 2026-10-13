import Foundation
import Security

let GH_CLIENT_ID = "Ov23lilj4ZETp4OibcSu"

// MARK: - トークン（Keychain）

enum GHToken {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "GHLauncher",
        kSecAttrAccount as String: "token",
    ]

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw "トークンを保存できませんでした (\(status))" }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 登録したリポジトリ

struct GHEntry: Codable, Identifiable {
    var repo: String               // "owner/name"
    var artifactId: Int? = nil     // 最後に入れた artifact
    var bundlePath: String? = nil  // LCAppInfo.relativeBundlePath
    var id: String { repo }
}

enum GHStore {
    private static let key = "GHEntries"

    static func load() -> [GHEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([GHEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [GHEntry]) {
        UserDefaults.standard.set(try! JSONEncoder().encode(entries), forKey: key)
    }
}

// MARK: - HTTP

private func checkStatus(_ resp: URLResponse, _ data: Data) throws {
    let code = (resp as! HTTPURLResponse).statusCode
    if code == 401 {
        // 取り消されたトークンのままだと、ログアウト手段がないので二度とログインし直せない
        GHToken.delete()
        throw "GitHubのログインが無効になりました。もう一度ログインしてください"
    }
    guard (200..<300).contains(code) else {
        throw "GitHub \(code): \(String(decoding: data, as: UTF8.self))"
    }
}

private func apiRequest(_ url: URL) throws -> URLRequest {
    guard let token = GHToken.load() else { throw "ログインしていません" }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

private func apiGet(_ path: String) async throws -> Data {
    let req = try apiRequest(URL(string: "https://api.github.com" + path)!)
    let (data, resp) = try await URLSession.shared.data(for: req)
    try checkStatus(resp, data)
    return data
}

private func postForm(_ url: String, _ params: [String: String]) async throws -> [String: Any] {
    var comps = URLComponents()
    comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = comps.percentEncodedQuery!.data(using: .utf8)
    let (data, resp) = try await URLSession.shared.data(for: req)
    try checkStatus(resp, data)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// MARK: - Device Flow

struct GHDeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let interval: Int
}

func ghStartDeviceFlow() async throws -> GHDeviceCode {
    let obj = try await postForm("https://github.com/login/device/code",
                                 ["client_id": GH_CLIENT_ID, "scope": "repo"])
    guard let device = obj["device_code"] as? String,
          let user = obj["user_code"] as? String,
          let uri = obj["verification_uri"] as? String,
          let interval = obj["interval"] as? Int else {
        throw (obj["error_description"] as? String) ?? "Device Flowを開始できませんでした"
    }
    return GHDeviceCode(deviceCode: device, userCode: user, verificationURL: URL(string: uri)!, interval: interval)
}

func ghWaitForToken(_ code: GHDeviceCode) async throws {
    var interval = code.interval
    while true {
        try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        let obj = try await postForm("https://github.com/login/oauth/access_token", [
            "client_id": GH_CLIENT_ID,
            "device_code": code.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        if let token = obj["access_token"] as? String {
            try GHToken.save(token)
            return
        }
        switch obj["error"] as? String {
        case "authorization_pending":
            continue
        case "slow_down":
            interval = (obj["interval"] as? Int) ?? interval + 5
        default:
            throw (obj["error_description"] as? String) ?? "ログインに失敗しました"
        }
    }
}

// MARK: - リポジトリ一覧

struct GHRepo: Decodable, Identifiable {
    let id: Int
    let full_name: String
}

func ghListRepos() async throws -> [GHRepo] {
    var all: [GHRepo] = []
    var page = 1
    while true {
        let data = try await apiGet("/user/repos?per_page=100&sort=pushed&page=\(page)")
        let repos = try JSONDecoder().decode([GHRepo].self, from: data)
        all += repos
        if repos.count < 100 { return all }
        page += 1
    }
}

// MARK: - artifact

struct GHArtifact: Decodable {
    struct Run: Decodable { let id: Int }
    let id: Int
    let name: String
    let expired: Bool
    let created_at: Date
    let archive_download_url: URL
    let workflow_run: Run?
}

private struct GHArtifactList: Decodable {
    let artifacts: [GHArtifact]
}

/// 最新の run が上げた artifact。1つならそれ、複数なら名前が .ipa で終わる1つ。
func ghLatestArtifact(repo: String) async throws -> GHArtifact {
    let data = try await apiGet("/repos/\(repo)/actions/artifacts?per_page=100")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let alive = try decoder.decode(GHArtifactList.self, from: data).artifacts.filter { !$0.expired }
    guard let newest = alive.max(by: { $0.created_at < $1.created_at }) else {
        throw "\(repo) に有効なartifactがありません"
    }
    let sameRun = alive.filter { $0.workflow_run?.id == newest.workflow_run?.id }
    if sameRun.count == 1 {
        return newest
    }
    let ipas = sameRun.filter { $0.name.lowercased().hasSuffix(".ipa") }
    guard ipas.count == 1 else {
        throw "最新のrunのartifactから.ipaを1つに絞れません: " + sameRun.map(\.name).joined(separator: ", ")
    }
    return ipas[0]
}

private class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// artifact の zip をダウンロードして一時ファイルの URL を返す
func ghDownload(_ artifact: GHArtifact) async throws -> URL {
    // 302 の転送先はストレージの別ホスト。自動で追うと Authorization ヘッダーが付いたまま送られうるので、
    // Location を受け取ってからトークンなしで取りに行く
    let req = try apiRequest(artifact.archive_download_url)
    let (data, resp) = try await URLSession.shared.data(for: req, delegate: NoRedirect())
    guard (resp as! HTTPURLResponse).statusCode == 302,
          let location = (resp as! HTTPURLResponse).value(forHTTPHeaderField: "Location") else {
        try checkStatus(resp, data)
        throw "artifactのダウンロードURLを取得できませんでした"
    }
    let (tmp, resp2) = try await URLSession.shared.download(from: URL(string: location)!)
    try checkStatus(resp2, Data())
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(artifact.id).zip")
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
    return dest
}
