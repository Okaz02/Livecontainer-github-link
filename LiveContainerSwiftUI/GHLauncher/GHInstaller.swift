import Foundation

private func unzip(_ file: URL) async throws -> URL {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let result = await Task.detached { extract(file.path, dest.path, Progress()) }.value
    guard result == 0 else { throw "\(file.lastPathComponent) を展開できませんでした" }
    return dest
}

/// artifact の zip から .ipa を取り出して入れ、relativeBundlePath を返す。
/// replacing があればその場所を置き換え、データの入れ物（コンテナ）を引き継ぐ。
func ghInstall(artifactZip: URL, replacing oldPath: String?) async throws -> String {
    let fm = FileManager.default
    let artifactDir = try await unzip(artifactZip)
    defer {
        try? fm.removeItem(at: artifactDir)
        try? fm.removeItem(at: artifactZip)
    }
    let ipa = fm.enumerator(at: artifactDir, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .first { $0.pathExtension.lowercased() == "ipa" }
    guard let ipa else { throw "artifactの中に.ipaがありません" }

    let ipaDir = try await unzip(ipa)
    defer { try? fm.removeItem(at: ipaDir) }
    let payload = ipaDir.appendingPathComponent("Payload")
    guard let appName = try fm.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
        throw ".ipaの中に.appがありません"
    }
    guard let newInfo = LCAppInfo(bundlePath: payload.appendingPathComponent(appName).path) else {
        throw "Info.plistを読めません"
    }

    try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
    var relativePath = "\(newInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
    var dataUUID: String?
    var containerInfo: [[AnyHashable: Any]]?
    if let oldPath, fm.fileExists(atPath: LCPath.bundlePath.appendingPathComponent(oldPath).path) {
        relativePath = oldPath
        let oldInfo = LCAppInfo(bundlePath: LCPath.bundlePath.appendingPathComponent(oldPath).path)!
        dataUUID = oldInfo.dataUUID
        containerInfo = oldInfo.containerInfo
        try fm.removeItem(at: LCPath.bundlePath.appendingPathComponent(oldPath))
    } else if fm.fileExists(atPath: LCPath.bundlePath.appendingPathComponent(relativePath).path) {
        relativePath = "\(newInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"
    }
    let outputFolder = LCPath.bundlePath.appendingPathComponent(relativePath)
    try fm.moveItem(at: payload.appendingPathComponent(appName), to: outputFolder)

    let finalInfo = LCAppInfo(bundlePath: outputFolder.path)!
    finalInfo.containerInfo = containerInfo
    finalInfo.dataUUID = dataUUID
    finalInfo.spoofSDKVersion = true
    return relativePath
}

/// 署名して LiveContainer をゲストアプリとして再起動する
func ghLaunch(relativePath: String) async throws {
    // 証明書がないと署名が飛ばされ、JIT を前提とした起動になって失敗する
    guard LCSharedUtils.certificatePassword() != nil else {
        throw "証明書がありません。歯車からAltStore/SideStoreの証明書を取り込んでください"
    }
    let info = LCAppInfo(bundlePath: LCPath.bundlePath.appendingPathComponent(relativePath).path)!

    if info.dataUUID == nil {
        let folderName = UUID().uuidString
        let folder = LCPath.dataPath.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let containerPlist: [String: Any] = [
            "appIdentifier": info.bundleIdentifier()!,
            "name": folderName,
            "keychainGroupId": Int.random(in: 0..<128),
            "isolateAppGroup": false,
            "spoofIdentifierForVendor": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: containerPlist, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent("LCContainerInfo.plist"))
        info.containerInfo = [["folderName": folderName, "name": folderName]]
        info.dataUUID = folderName
    }

    let signError: String? = await withCheckedContinuation { c in
        info.patchExecAndSignIfNeed(completionHandler: { success, error in
            c.resume(returning: success ? nil : (error ?? "署名に失敗しました"))
        }, progressHandler: { _ in }, forceSign: false)
    }
    if let signError { throw signError.loc }

    // 再起動後に中核が Tweaks/TweakLoader.dylib のシンボリックリンクを張る。フォルダがないと張れず、
    // 署名時に注入した @loader_path/../../Tweaks/TweakLoader.dylib が見つからずに起動が止まる
    try FileManager.default.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)

    UserDefaults.standard.set(relativePath, forKey: "selected")
    UserDefaults.standard.set(info.dataUUID, forKey: "selectedContainer")
    if #available(iOS 26.0, *) {
        let metalAngle = "\(info.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE"
        if FileManager.default.fileExists(atPath: metalAngle) {
            let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("preloadLibraries.txt")
            try metalAngle.data(using: .utf8)!.write(to: url)
        }
    }
    LCSharedUtils.launchToGuestApp()
}
