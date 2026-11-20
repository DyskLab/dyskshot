import AppKit
import CryptoKit
import Network
import Security

/// Google Drive upload with OAuth for an installed app (loopback redirect + PKCE).
/// The user provides their own OAuth client ID (type "Desktop app") in Settings → Cloud.
@MainActor
final class GoogleDrive {
    static let shared = GoogleDrive()

    enum DriveError: LocalizedError {
        case notConfigured, notSignedIn, auth(String), http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your Google OAuth Client ID in Settings → Cloud"
            case .notSignedIn: "Sign in to Google Drive in Settings → Cloud"
            case .auth(let s): "Google sign-in failed: \(s)"
            case .http(let code, let s): "Google Drive error \(code): \(s)"
            }
        }
    }

    private static let scope = "https://www.googleapis.com/auth/drive.file openid email"
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var listener: NWListener?

    var clientID: String { Prefs.string("cloud.clientID").trimmingCharacters(in: .whitespacesAndNewlines) }
    var clientSecret: String { Prefs.string("cloud.clientSecret").trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSignedIn: Bool { Keychain.get("gdrive.refresh") != nil }
    var email: String { Prefs.string("cloud.email") }

    // MARK: Sign in / out

    func signIn() async throws {
        guard !clientID.isEmpty else { throw DriveError.notConfigured }
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)

        let (port, codeTask) = try await startLoopback(state: state)
        let redirect = "http://127.0.0.1:\(port)"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(c.url!)
        let code: String
        do { code = try await codeTask.value } catch { stopLoopback(); throw error }
        stopLoopback()

        var form = ["code": code, "client_id": clientID, "code_verifier": verifier,
                    "redirect_uri": redirect, "grant_type": "authorization_code"]
        if !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        let json = try await Self.postForm("https://oauth2.googleapis.com/token", form)
        guard let refresh = json["refresh_token"] as? String, let access = json["access_token"] as? String else {
            throw DriveError.auth(json["error_description"] as? String ?? json["error"] as? String ?? "no token")
        }
        Keychain.set(refresh, for: "gdrive.refresh")
        accessToken = access
        accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let idToken = json["id_token"] as? String, let mail = Self.jwtEmail(idToken) {
            Prefs.d.set(mail, forKey: "cloud.email")
        }
        Prefs.d.set("", forKey: "cloud.folderID")
        NSApp.activate(ignoringOtherApps: true)
    }

    func signOut() {
        if let t = Keychain.get("gdrive.refresh") {
            var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(t)")!)
            r.httpMethod = "POST"
            URLSession.shared.dataTask(with: r).resume()
        }
        Keychain.delete("gdrive.refresh")
        accessToken = nil
        Prefs.d.set("", forKey: "cloud.email")
        Prefs.d.set("", forKey: "cloud.folderID")
    }

    private func token() async throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = Keychain.get("gdrive.refresh") else { throw DriveError.notSignedIn }
        guard !clientID.isEmpty else { throw DriveError.notConfigured }
        var form = ["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"]
        if !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        let json = try await Self.postForm("https://oauth2.googleapis.com/token", form)
        guard let access = json["access_token"] as? String else {
            if json["error"] as? String == "invalid_grant" { Keychain.delete("gdrive.refresh") }
            throw DriveError.auth(json["error_description"] as? String ?? json["error"] as? String ?? "refresh failed")
        }
        accessToken = access
        accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        return access
    }

    // MARK: Loopback listener

    func startLoopback(state: String) async throws -> (UInt16, Task<String, Error>) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let l = try NWListener(using: params)
        listener = l
        let codeStream = AsyncThrowingStream<String, Error> { cont in
            l.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let items = URLComponents(string: "http://x\(path)")?.queryItems ?? []
                    let value = { (n: String) in items.first { $0.name == n }?.value }
                    var ok = false
                    if value("state") == state, let code = value("code") {
                        ok = true
                        cont.yield(code)
                        cont.finish()
                    } else if let err = value("error") {
                        cont.finish(throwing: DriveError.auth(err))
                    }
                    if path.hasPrefix("/favicon") { conn.cancel(); return }
                    let body = ok
                        ? "<h2 style='font-family:-apple-system'>DyskShot is connected to Google Drive.</h2><p style='font-family:-apple-system'>You can close this tab.</p>"
                        : "<h2 style='font-family:-apple-system'>Sign-in was not completed.</h2>"
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            l.stateUpdateHandler = { st in
                guard !resumed else { return }
                switch st {
                case .ready: resumed = true; cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: DispatchQueue(label: "dyskshot.oauth.listener"))
        }
        let task = Task<String, Error> {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    for try await code in codeStream { return code }
                    throw DriveError.auth("cancelled")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw DriveError.auth("timed out")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }
        return (port, task)
    }

    func stopLoopback() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Upload

    /// Uploads a file into the DyskShot folder and returns a shareable link.
    func upload(_ file: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let access = try await token()
        let folder = try await folderID(access)
        let mime = Self.mimeType(file)

        // Resumable session
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": file.lastPathComponent, "parents": [folder]])
        let (sData, sResp) = try await URLSession.shared.data(for: start)
        let sHTTP = sResp as? HTTPURLResponse
        guard sHTTP?.statusCode == 200, let loc = sHTTP?.value(forHTTPHeaderField: "Location"), let locURL = URL(string: loc) else {
            if sHTTP?.statusCode == 404 { Prefs.d.set("", forKey: "cloud.folderID") }
            throw DriveError.http(sHTTP?.statusCode ?? 0, Self.message(sData))
        }

        var put = URLRequest(url: locURL)
        put.httpMethod = "PUT"
        put.setValue(mime, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgress(progress)
        let (data, resp) = try await URLSession.shared.upload(for: put, fromFile: file, delegate: delegate)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { throw DriveError.http(code, Self.message(data)) }

        if Prefs.bool("cloud.public") {
            var perm = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/permissions")!)
            perm.httpMethod = "POST"
            perm.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            perm.setValue("application/json", forHTTPHeaderField: "Content-Type")
            perm.httpBody = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
            _ = try? await URLSession.shared.data(for: perm)
        }
        return json["webViewLink"] as? String ?? "https://drive.google.com/file/d/\(id)/view"
    }

    private func folderID(_ access: String) async throws -> String {
        let cached = Prefs.string("cloud.folderID")
        if !cached.isEmpty { return cached }
        let name = Prefs.string("cloud.folderName").isEmpty ? "DyskShot" : Prefs.string("cloud.folderName")
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [.init(name: "q", value: "name='\(escaped)' and mimeType='application/vnd.google-apps.folder' and trashed=false"),
                        .init(name: "fields", value: "files(id)"), .init(name: "spaces", value: "drive")]
        var list = URLRequest(url: c.url!)
        list.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (lData, lResp) = try await URLSession.shared.data(for: list)
        guard (lResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw DriveError.http((lResp as? HTTPURLResponse)?.statusCode ?? 0, Self.message(lData))
        }
        if let json = try JSONSerialization.jsonObject(with: lData) as? [String: Any],
           let id = (json["files"] as? [[String: Any]])?.first?["id"] as? String {
            Prefs.d.set(id, forKey: "cloud.folderID")
            return id
        }
        var create = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        create.httpMethod = "POST"
        create.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": "application/vnd.google-apps.folder"])
        let (cData, cResp) = try await URLSession.shared.data(for: create)
        guard (cResp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: cData) as? [String: Any], let id = json["id"] as? String else {
            throw DriveError.http((cResp as? HTTPURLResponse)?.statusCode ?? 0, Self.message(cData))
        }
        Prefs.d.set(id, forKey: "cloud.folderID")
        return id
    }

    // MARK: Helpers

    private static func postForm(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: r)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func message(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }

    private static func jwtEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        case "tiff", "tif": "image/tiff"
        case "gif": "image/gif"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let handler: (@Sendable (Double) -> Void)?
    init(_ h: (@Sendable (Double) -> Void)?) { handler = h }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.dysklab.dyskshot"

    static func set(_ value: String, for account: String) {
        delete(account)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecValueData: Data(value.utf8)] as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                          kSecAttrAccount: account, kSecReturnData: true] as CFDictionary, &out)
        guard status == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}

// MARK: - UI entry point

@MainActor
enum Cloud {
    private static var uploading = 0

    static func upload(_ capture: Capture) {
        guard let url = Output.tempFile(capture) else { return }
        upload(file: url)
    }

    static func upload(file: URL) {
        let drive = GoogleDrive.shared
        guard !drive.clientID.isEmpty, drive.isSignedIn else {
            Toast.show(drive.clientID.isEmpty ? "Set up Google Drive in Settings → Cloud" : "Sign in to Google Drive in Settings → Cloud",
                       symbol: "icloud.slash")
            PreferencesWindow.show(tab: PreferencesWindow.cloudTab)
            return
        }
        uploading += 1
        Toast.show("Uploading \(file.lastPathComponent)…", symbol: "icloud.and.arrow.up")
        Task { @MainActor in
            defer { uploading -= 1 }
            do {
                let link = try await drive.upload(file)
                if Prefs.bool("cloud.copyLink") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(link, forType: .string)
                }
                if Prefs.bool("cloud.openLink"), let u = URL(string: link) { NSWorkspace.shared.open(u) }
                Toast.show(Prefs.bool("cloud.copyLink") ? "Uploaded · link copied" : "Uploaded to Google Drive", symbol: "checkmark.icloud")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.icloud")
            }
        }
    }
}
