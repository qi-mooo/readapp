import Foundation
import NetworkExtension

// MARK: - API Response
struct APIResponse<T: Codable>: Codable {
    let isSuccess: Bool
    let errorMsg: String?
    let data: T?
}

// MARK: - Book Model
struct Book: Codable, Identifiable {
    var id: String { bookUrl ?? UUID().uuidString }
    let name: String?
    let author: String?
    let bookUrl: String?
    let origin: String?
    let originName: String?
    let coverUrl: String?
    let intro: String?
    let durChapterTitle: String?
    let durChapterIndex: Int?
    let durChapterPos: Double?
    let totalChapterNum: Int?
    let latestChapterTitle: String?
    let kind: String?
    let type: Int?
    let durChapterTime: Int64?  // 最后阅读时间（时间戳）
    
    var displayCoverUrl: String? {
        if let url = coverUrl, !url.isEmpty {
            // 如果是相对路径，拼接完整URL
            if url.hasPrefix("baseurl/") {
                return APIService.shared.baseURL.replacingOccurrences(of: "/api/\(APIService.apiVersion)", with: "") + "/" + url
            }
            return url
        }
        return nil
    }
}

// MARK: - Chapter Model
struct BookChapter: Codable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let index: Int
    let isVolume: Bool?
    let isPay: Bool?
}

// MARK: - Chapter Content Response
struct ChapterContentResponse: Codable {
    let rules: [ReplaceRule]?
    let text: String
}

struct ReplaceRule: Codable {
    let id: String?
    let name: String?
}

// MARK: - HttpTTS Model
struct HttpTTS: Codable, Identifiable {
    let id: String
    let userid: String?
    let name: String
    let url: String
    let contentType: String?
    let concurrentRate: String?
    let loginUrl: String?
    let loginUi: String?
    let header: String?
    let enabledCookieJar: Bool?
    let loginCheckJs: String?
    let lastUpdateTime: Int64?
}

// MARK: - Login Response Model
struct LoginResponse: Codable {
    let accessToken: String
}

// MARK: - User Info Model
struct UserInfo: Codable {
    let username: String?
    let phone: String?
    let email: String?
}

// MARK: - User Preferences
class UserPreferences: ObservableObject {
    static let shared = UserPreferences()
    
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
        }
    }
    
    @Published var accessToken: String {
        didSet {
            UserDefaults.standard.set(accessToken, forKey: "accessToken")
        }
    }
    
    @Published var username: String {
        didSet {
            UserDefaults.standard.set(username, forKey: "username")
        }
    }
    
    @Published var isLoggedIn: Bool {
        didSet {
            UserDefaults.standard.set(isLoggedIn, forKey: "isLoggedIn")
        }
    }
    
    @Published var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
        }
    }
    
    @Published var lineSpacing: CGFloat {
        didSet {
            UserDefaults.standard.set(lineSpacing, forKey: "lineSpacing")
        }
    }
    
    @Published var speechRate: Double {
        didSet {
            UserDefaults.standard.set(speechRate, forKey: "speechRate")
        }
    }
    
    @Published var selectedTTSId: String {
        didSet {
            UserDefaults.standard.set(selectedTTSId, forKey: "selectedTTSId")
        }
    }
    
    @Published var bookshelfSortByRecent: Bool {
        didSet {
            UserDefaults.standard.set(bookshelfSortByRecent, forKey: "bookshelfSortByRecent")
        }
    }
    
    @Published var ttsPreloadCount: Int {
        didSet {
            UserDefaults.standard.set(ttsPreloadCount, forKey: "ttsPreloadCount")
        }
    }
    
    @Published var useReplaceRuleSanitization: Bool {
        didSet {
            UserDefaults.standard.set(useReplaceRuleSanitization, forKey: "useReplaceRuleSanitization")
        }
    }

    @Published var ttsFadeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(ttsFadeEnabled, forKey: "ttsFadeEnabled")
        }
    }
    
    // TTS进度记录：bookUrl -> (chapterIndex, sentenceIndex)
    private var ttsProgress: [String: (Int, Int)] {
        get {
            if let data = UserDefaults.standard.data(forKey: "ttsProgress"),
               let dict = try? JSONDecoder().decode([String: [Int]].self, from: data) {
                return dict.mapValues { ($0[0], $0[1]) }
            }
            return [:]
        }
        set {
            let dict = newValue.mapValues { [$0.0, $0.1] }
            if let data = try? JSONEncoder().encode(dict) {
                UserDefaults.standard.set(data, forKey: "ttsProgress")
            }
        }
    }
    
    func saveTTSProgress(bookUrl: String, chapterIndex: Int, sentenceIndex: Int) {
        var progress = ttsProgress
        progress[bookUrl] = (chapterIndex, sentenceIndex)
        ttsProgress = progress
    }
    
    func getTTSProgress(bookUrl: String) -> (chapterIndex: Int, sentenceIndex: Int)? {
        return ttsProgress[bookUrl]
    }
    
    private init() {
        // 初始化所有属性
        let savedFontSize = CGFloat(UserDefaults.standard.float(forKey: "fontSize"))
        self.fontSize = savedFontSize == 0 ? 18 : savedFontSize
        
        let savedLineSpacing = CGFloat(UserDefaults.standard.float(forKey: "lineSpacing"))
        self.lineSpacing = savedLineSpacing == 0 ? 8 : savedLineSpacing
        
        let savedSpeechRate = UserDefaults.standard.double(forKey: "speechRate")
        self.speechRate = savedSpeechRate == 0 ? 10.0 : savedSpeechRate
        
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.accessToken = UserDefaults.standard.string(forKey: "accessToken") ?? ""
        self.username = UserDefaults.standard.string(forKey: "username") ?? ""
        self.isLoggedIn = UserDefaults.standard.bool(forKey: "isLoggedIn")
        self.selectedTTSId = UserDefaults.standard.string(forKey: "selectedTTSId") ?? ""
        self.bookshelfSortByRecent = UserDefaults.standard.bool(forKey: "bookshelfSortByRecent")
        
        let savedPreloadCount = UserDefaults.standard.integer(forKey: "ttsPreloadCount")
        self.ttsPreloadCount = savedPreloadCount == 0 ? 10 : savedPreloadCount
        
        if UserDefaults.standard.object(forKey: "useReplaceRuleSanitization") == nil {
            self.useReplaceRuleSanitization = true
        } else {
            self.useReplaceRuleSanitization = UserDefaults.standard.bool(forKey: "useReplaceRuleSanitization")
        }

        if UserDefaults.standard.object(forKey: "ttsFadeEnabled") == nil {
            self.ttsFadeEnabled = true
        } else {
            self.ttsFadeEnabled = UserDefaults.standard.bool(forKey: "ttsFadeEnabled")
        }
    }
    
    func logout() {
        accessToken = ""
        username = ""
        isLoggedIn = false
    }
}

// MARK: - Tailscale Tunnel Manager
@MainActor
class TailscaleTunnelManager: ObservableObject {
    static let shared = TailscaleTunnelManager()
    
    private let keychainAuthKeyKey = "readapp_tailscale_auth_key"
    private let controlURL = "https://controlplane.tailscale.com"
    private let nodeHostname = "readapp-ios"
    private let nodeDirName = "tailscale-node"
    
    private var tailscaleHandle: Int32?
    private var socksProxy: SocksProxy?
    
    @Published var status: NEVPNStatus = .invalid
    @Published var isConfigured = false
    @Published var lastError: String?
    
    private struct SocksProxy: Sendable {
        let host: String
        let port: Int
        let password: String
    }
    
    private struct StartResult: Sendable {
        let handle: Int32
        let proxy: SocksProxy
    }
    
    private init() {
        isConfigured = !getAuthKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        status = .disconnected
    }
    
    func refreshConfiguration() async {
        isConfigured = !getAuthKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if tailscaleHandle == nil {
            status = .disconnected
        }
    }
    
    func saveAuthKey(_ authKey: String) {
        let value = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            clearAuthKey()
            return
        }
        
        do {
            try KeychainStore.set(value, for: keychainAuthKeyKey)
            isConfigured = true
            lastError = nil
        } catch {
            lastError = "保存 Tailscale key 失败: \(error.localizedDescription)"
        }
    }
    
    func clearAuthKey() {
        disconnect()
        KeychainStore.delete(keychainAuthKeyKey)
        isConfigured = false
        lastError = nil
    }
    
    func getAuthKeyMasked() -> String {
        let key = getAuthKey()
        guard !key.isEmpty else { return "" }
        let prefix = key.prefix(6)
        return "\(prefix)******"
    }
    
    func getAuthKey() -> String {
        KeychainStore.get(keychainAuthKeyKey) ?? ""
    }
    
    func connect() async {
        if status == .connected || status == .connecting {
            return
        }
        
        let authKey = getAuthKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authKey.isEmpty else {
            lastError = "请先填写 Tailscale Auth Key"
            return
        }
        
        status = .connecting
        lastError = nil
        
        let dirPath: String
        do {
            dirPath = try Self.prepareNodeDirectoryPath(name: nodeDirName)
        } catch {
            status = .disconnected
            lastError = "准备 Tailscale 数据目录失败: \(error.localizedDescription)"
            return
        }
        let hostname = nodeHostname
        let controlPlaneURL = controlURL
        
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.startEmbeddedNode(
                    authKey: authKey,
                    statePath: dirPath,
                    hostname: hostname,
                    controlURL: controlPlaneURL
                )
            }.value
            
            tailscaleHandle = result.handle
            socksProxy = result.proxy
            isConfigured = true
            status = .connected
            lastError = nil
        } catch {
            tailscaleHandle = nil
            socksProxy = nil
            status = .disconnected
            lastError = "启动 Tailscale 失败: \(error.localizedDescription)"
        }
    }
    
    func disconnect() {
        guard let handle = tailscaleHandle else {
            status = .disconnected
            socksProxy = nil
            return
        }
        
        _ = tailscale_close(handle)
        tailscaleHandle = nil
        socksProxy = nil
        status = .disconnected
    }
    
    var statusText: String {
        switch status {
        case .invalid:
            return "未配置"
        case .disconnected:
            return "未连接"
        case .connecting:
            return "连接中"
        case .connected:
            return "已连接"
        case .reasserting:
            return "重连中"
        case .disconnecting:
            return "断开中"
        @unknown default:
            return "未知状态"
        }
    }
    
    func proxyConnectionDictionary() -> [String: Any]? {
        guard status == .connected else { return nil }
        guard let proxy = socksProxy else { return nil }
        return [
            "SOCKSEnable": 1,
            "SOCKSProxy": proxy.host,
            "SOCKSPort": proxy.port,
            "SOCKSUser": "tsnet",
            "SOCKSPassword": proxy.password
        ]
    }
    
    func proxyCredentials() -> (host: String, port: Int, password: String)? {
        guard status == .connected, let proxy = socksProxy else { return nil }
        return (proxy.host, proxy.port, proxy.password)
    }
    
    var canProxyRequests: Bool {
        status == .connected && socksProxy != nil
    }
    
    nonisolated private static func prepareNodeDirectoryPath(name: String) throws -> String {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "TailscaleTunnelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取 Application Support 路径"])
        }
        
        let dir = appSupport.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
    
    nonisolated private static func startEmbeddedNode(authKey: String, statePath: String, hostname: String, controlURL: String) throws -> StartResult {
        let handle = tailscale_new()
        guard handle > 0 else {
            throw NSError(domain: "TailscaleTunnelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "初始化内置 Tailscale 失败"])
        }
        
        func run(_ step: String, _ body: () -> Int32) throws {
            let code = body()
            guard code == 0 else {
                throw NSError(
                    domain: "TailscaleTunnelManager",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "\(step)失败: \(lastErrorMessage(handle: handle, fallbackCode: code))"]
                )
            }
        }
        
        do {
            try run("设置 Auth Key") { authKey.withCString { tailscale_set_authkey(handle, $0) } }
            try run("设置节点名称") { hostname.withCString { tailscale_set_hostname(handle, $0) } }
            try run("设置控制平面地址") { controlURL.withCString { tailscale_set_control_url(handle, $0) } }
            try run("设置节点数据目录") { statePath.withCString { tailscale_set_dir(handle, $0) } }
            try run("启动内置节点") { tailscale_start(handle) }
            try run("连接尾网") { tailscale_up(handle) }
            
            var addrBuffer = [CChar](repeating: 0, count: 96)
            var proxyBuffer = [CChar](repeating: 0, count: 33)
            var localAPIBuffer = [CChar](repeating: 0, count: 33)
            try run("初始化本地代理") {
                tailscale_loopback(
                    handle,
                    &addrBuffer,
                    addrBuffer.count,
                    &proxyBuffer,
                    &localAPIBuffer
                )
            }
            
            let address = String(cString: addrBuffer)
            let proxyPassword = String(cString: proxyBuffer)
            
            guard let (host, port) = parseHostPort(address) else {
                throw NSError(domain: "TailscaleTunnelManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "无效的本地代理地址: \(address)"])
            }
            
            return StartResult(handle: handle, proxy: SocksProxy(host: host, port: port, password: proxyPassword))
        } catch {
            _ = tailscale_close(handle)
            throw error
        }
    }
    
    nonisolated private static func parseHostPort(_ address: String) -> (String, Int)? {
        if let components = URLComponents(string: "socks5://\(address)"),
           let host = components.host,
           let port = components.port {
            return (host, port)
        }
        
        if let idx = address.lastIndex(of: ":"),
           let port = Int(address[address.index(after: idx)...]) {
            let host = String(address[..<idx])
            if !host.isEmpty {
                return (host, port)
            }
        }
        
        return nil
    }
    
    nonisolated private static func lastErrorMessage(handle: Int32, fallbackCode: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = tailscale_errmsg(handle, &buffer, buffer.count)
        if result == 0 {
            return String(cString: buffer)
        }
        return "错误码: \(fallbackCode)"
    }
}
