import SwiftUI

struct GHRootView: View {
    @State private var loggedIn = GHToken.load() != nil
    @State private var entries = GHStore.load()
    @State private var showPicker = false
    @State private var showCertificate = false
    @State private var busyRepo: String?
    @State private var status = ""
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Group {
                if loggedIn {
                    List {
                        ForEach(entries) { entry in
                            Button {
                                Task { await open(entry.repo) }
                            } label: {
                                HStack {
                                    Text(entry.repo)
                                    Spacer()
                                    if busyRepo == entry.repo {
                                        Text(status).foregroundColor(.secondary)
                                        ProgressView()
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            entries.remove(atOffsets: offsets)
                            GHStore.save(entries)
                        }
                    }
                    .disabled(busyRepo != nil)
                } else {
                    GHLoginView { loggedIn = true }
                }
            }
            .navigationTitle("Builds")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showCertificate = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if loggedIn {
                        Button { showPicker = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                GHRepoPicker(registered: Set(entries.map(\.repo))) { repo in
                    entries.append(GHEntry(repo: repo))
                    GHStore.save(entries)
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showCertificate) {
            GHCertificateView()
        }
        .alert("エラー", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onOpenURL { url in
            // AltStore/SideStore から livecontainer://certificate?cert=...&password=... で戻ってくる
            guard url.host == "certificate" else { return }
            do {
                try ghSaveCertificate(from: url)
                // 開いたままの設定シートは状態表示が古いので閉じる
                showCertificate = false
            } catch {
                errorText = error.localizedDescription
            }
        }
        .task {
            // 前回ゲストアプリの起動に失敗していれば、中核が書いたエラーを出す
            if let error = UserDefaults.standard.string(forKey: "error") {
                UserDefaults.standard.removeObject(forKey: "error")
                errorText = error
            } else if UserDefaults.standard.bool(forKey: "SigningInProgress") {
                UserDefaults.standard.removeObject(forKey: "SigningInProgress")
                errorText = "lc.signer.crashDuringSignErr".loc
            }
        }
    }

    private func open(_ repo: String) async {
        busyRepo = repo
        defer { busyRepo = nil }
        do {
            status = "確認中"
            let artifact = try await ghLatestArtifact(repo: repo)
            guard let i = entries.firstIndex(where: { $0.repo == repo }) else { return }
            let installed = entries[i].bundlePath.flatMap {
                FileManager.default.fileExists(atPath: LCPath.bundlePath.appendingPathComponent($0).path) ? $0 : nil
            }
            if installed == nil || entries[i].artifactId != artifact.id {
                status = "ダウンロード中"
                let zip = try await ghDownload(artifact)
                status = "インストール中"
                entries[i].bundlePath = try await ghInstall(artifactZip: zip, replacing: installed)
                entries[i].artifactId = artifact.id
                GHStore.save(entries)
            }
            status = "起動中"
            try await ghLaunch(relativePath: entries[i].bundlePath!)
        } catch {
            errorText = error.localizedDescription
            loggedIn = GHToken.load() != nil
        }
    }
}

struct GHLoginView: View {
    let onLogin: () -> Void
    @State private var code: GHDeviceCode?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            if let code {
                Text("GitHubで次のコードを入力してください")
                Text(code.userCode)
                    .font(.largeTitle.monospaced())
                    .textSelection(.enabled)
                Button("GitHubを開く") { UIApplication.shared.open(code.verificationURL) }
                    .buttonStyle(.borderedProminent)
                ProgressView()
            } else {
                Button("GitHubでログイン") { Task { await login() } }
                    .buttonStyle(.borderedProminent)
            }
            if let errorText {
                Text(errorText).foregroundColor(.red)
            }
        }
        .padding()
    }

    private func login() async {
        errorText = nil
        do {
            let c = try await ghStartDeviceFlow()
            code = c
            try await ghWaitForToken(c)
            onLogin()
        } catch {
            errorText = error.localizedDescription
            code = nil
        }
    }
}

struct GHRepoPicker: View {
    let registered: Set<String>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [GHRepo]?
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Group {
                if let errorText {
                    Text(errorText).foregroundColor(.red).padding()
                } else if let repos {
                    // 登録済みを出すと同じリポジトリが二重に入り、ForEach の id が重複する
                    List(repos.filter { !registered.contains($0.full_name) }) { repo in
                        Button(repo.full_name) {
                            onPick(repo.full_name)
                            dismiss()
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("リポジトリを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .task {
                do {
                    repos = try await ghListRepos()
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

func ghSaveCertificate(from url: URL) throws {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(items.map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    guard let cert = query["cert"]?.removingPercentEncoding, let certData = Data(base64Encoded: cert),
          let password = query["password"] else {
        throw "証明書を受け取れませんでした"
    }
    let defaults = UserDefaults(suiteName: LCSharedUtils.appGroupID()) ?? .standard
    defaults.set(certData, forKey: "LCCertificateData")
    defaults.set(password, forKey: "LCCertificatePassword")
    defaults.set(Date(), forKey: "LCCertificateUpdateDate")
}

struct GHCertificateView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = LCUtils.store()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(LCSharedUtils.certificatePassword() != nil ? "取り込み済み" : "未設定")
                    if store == .AltStore || store == .SideStore {
                        Button(store == .AltStore ? "AltStoreから取り込む" : "SideStoreから取り込む") {
                            let scheme = store == .AltStore ? "altstore-classic" : "sidestore"
                            UIApplication.shared.open(URL(string: "\(scheme)://certificate?callback_template=livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29")!)
                        }
                    } else {
                        Text("AltStore/SideStoreで入れたときだけ取り込めます").foregroundColor(.secondary)
                    }
                } header: {
                    Text("署名用の証明書")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
