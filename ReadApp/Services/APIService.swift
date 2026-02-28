import Foundation
import Combine
import UIKit

private actor ChapterContentCacheStore {
    struct ManifestEntry: Codable {
        let fileName: String
        var lastAccessTime: TimeInterval
    }
    
    private let maxDiskEntries = 300
    private let expirationInterval: TimeInterval = 7 * 24 * 60 * 60
    private let memoryCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 120
        return cache
    }()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let manifestURL: URL
    
    private var manifest: [String: ManifestEntry] = [:]
    private var isPrepared = false
    
    init() {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        self.cacheDirectory = root.appendingPathComponent("ReadAppChapterContentCache", isDirectory: true)
        self.manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
    }
    
    func get(for key: String) -> String? {
        if let memoryValue = memoryCache.object(forKey: key as NSString) {
            return memoryValue as String
        }
        
        ensurePrepared()
        
        guard let entry = manifest[key] else {
            return nil
        }
        
        if isExpired(entry) {
            removeEntry(for: key, entry: entry)
            saveManifest()
            return nil
        }
        
        let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            manifest.removeValue(forKey: key)
            saveManifest()
            return nil
        }
        
        memoryCache.setObject(content as NSString, forKey: key as NSString)
        manifest[key]?.lastAccessTime = Date().timeIntervalSince1970
        saveManifest()
        return content
    }
    
    func set(_ content: String, for key: String) {
        ensurePrepared()
        
        memoryCache.setObject(content as NSString, forKey: key as NSString)
        
        guard let data = content.data(using: .utf8) else {
            return
        }
        
        let fileName = "\(stableHash(key)).txt"
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL, options: .atomic)
            manifest[key] = ManifestEntry(fileName: fileName, lastAccessTime: Date().timeIntervalSince1970)
            cleanupExpiredAndOverflow()
            saveManifest()
        } catch {
            LogManager.shared.log("写入章节缓存失败: \(error)", category: "缓存错误")
        }
    }
    
    func removeAll() {
        ensurePrepared()
        
        memoryCache.removeAllObjects()
        manifest.removeAll()
        
        do {
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            saveManifest()
        } catch {
            LogManager.shared.log("清理章节缓存失败: \(error)", category: "缓存错误")
        }
    }
    
    private func ensurePrepared() {
        guard !isPrepared else {
            return
        }
        
        isPrepared = true
        
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: manifestURL),
               let decoded = try? JSONDecoder().decode([String: ManifestEntry].self, from: data) {
                manifest = decoded
            }
            cleanupExpiredAndOverflow()
            saveManifest()
        } catch {
            LogManager.shared.log("初始化章节缓存失败: \(error)", category: "缓存错误")
        }
    }
    
    private func isExpired(_ entry: ManifestEntry) -> Bool {
        Date().timeIntervalSince1970 - entry.lastAccessTime > expirationInterval
    }
    
    private func cleanupExpiredAndOverflow() {
        let now = Date().timeIntervalSince1970
        
        let expired = manifest.filter { now - $0.value.lastAccessTime > expirationInterval }
        for (key, entry) in expired {
            removeEntry(for: key, entry: entry)
        }
        
        if manifest.count > maxDiskEntries {
            let sorted = manifest.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
            let overflowCount = manifest.count - maxDiskEntries
            for (key, entry) in sorted.prefix(overflowCount) {
                removeEntry(for: key, entry: entry)
            }
        }
    }
    
    private func removeEntry(for key: String, entry: ManifestEntry) {
        let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
        try? fileManager.removeItem(at: fileURL)
        manifest.removeValue(forKey: key)
    }
    
    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else {
            return
        }
        try? data.write(to: manifestURL, options: .atomic)
    }
    
    private func stableHash(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

class APIService: ObservableObject {
    static let shared = APIService()
    static let apiVersion = 5
    
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // 章节内容缓存（内存 + 磁盘）
    private let chapterCache = ChapterContentCacheStore()
    
    // 并发去重，避免同章节重复请求
    private var inFlightChapterTasks: [String: Task<String, Error>] = [:]
    private let inFlightLock = NSLock()
    
    var baseURL: String {
        let serverURL = UserPreferences.shared.serverURL
        if serverURL.isEmpty {
            return "http://127.0.0.1:8080/api/\(Self.apiVersion)"
        }
        return "\(serverURL)/api/\(Self.apiVersion)"
    }
    
    var publicBaseURL: String? {
        let publicServerURL = UserPreferences.shared.publicServerURL
        guard !publicServerURL.isEmpty else { return nil }
        return "\(publicServerURL)/api/\(Self.apiVersion)"
    }
    
    private var accessToken: String {
        UserPreferences.shared.accessToken
    }
    
    private init() {}
    
    // MARK: - Failback 请求方法
    /// 通用网络请求方法，支持自动failback到公网服务器
    private func requestWithFailback(endpoint: String, queryItems: [URLQueryItem], timeoutInterval: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        // 先尝试局域网
        let localURL = "\(baseURL)/\(endpoint)"
        
        do {
            return try await performRequest(urlString: localURL, queryItems: queryItems, timeoutInterval: timeoutInterval)
        } catch let localError as NSError {
            // 检查是否是网络连接错误，如果是则尝试公网
            if shouldTryPublicServer(error: localError), let publicBase = publicBaseURL {
                LogManager.shared.log("局域网连接失败，尝试公网服务器...", category: "网络")
                let publicURL = "\(publicBase)/\(endpoint)"
                
                do {
                    return try await performRequest(urlString: publicURL, queryItems: queryItems, timeoutInterval: timeoutInterval)
                } catch {
                    // 公网也失败，抛出原始错误
                    LogManager.shared.log("公网服务器也失败: \(error)", category: "网络错误")
                    throw localError
                }
            }
            
            // 没有公网服务器或不需要failback，直接抛出错误
            throw localError
        }
    }
    
    /// 判断是否应该尝试公网服务器
    private func shouldTryPublicServer(error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost:
                return true
            default:
                return false
            }
        }
        return false
    }
    
    /// 执行实际的网络请求
    private func performRequest(urlString: String, queryItems: [URLQueryItem], timeoutInterval: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL: \(urlString)"])
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无法构建URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "无效的响应类型"])
        }
        
        return (data, httpResponse)
    }
    
    // MARK: - 登录
    func login(username: String, password: String) async throws -> String {
        let urlString = "\(baseURL)/login"
        LogManager.shared.log("登录请求 URL: \(urlString)", category: "网络")
        
        guard var components = URLComponents(string: urlString) else {
            let error = "无效的URL: \(urlString)"
            LogManager.shared.log(error, category: "网络错误")
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: error])
        }
        
        // 获取设备型号（在主线程同步获取）
        let deviceModel = await MainActor.run { UIDevice.current.model }
        
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "model", value: deviceModel)
        ]
        
        guard let url = components.url else {
            let error = "无法构建URL"
            LogManager.shared.log(error, category: "网络错误")
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: error])
        }
        
        LogManager.shared.log("完整登录 URL: \(url.absoluteString)", category: "网络")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let error = "无效的响应类型"
                LogManager.shared.log(error, category: "网络错误")
                throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: error])
            }
            
            LogManager.shared.log("HTTP 状态码: \(httpResponse.statusCode)", category: "网络")
            
            if httpResponse.statusCode != 200 {
                let responseText = String(data: data, encoding: .utf8) ?? "无法解析响应"
                let error = "服务器错误(状态码: \(httpResponse.statusCode)): \(responseText)"
                LogManager.shared.log(error, category: "网络错误")
                throw NSError(domain: "APIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }
            
            let apiResponse = try JSONDecoder().decode(APIResponse<LoginResponse>.self, from: data)
            
            if apiResponse.isSuccess, let loginData = apiResponse.data {
                LogManager.shared.log("登录成功", category: "网络")
                return loginData.accessToken
            } else {
                let error = apiResponse.errorMsg ?? "登录失败"
                LogManager.shared.log("登录失败: \(error)", category: "网络错误")
                throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: error])
            }
        } catch let error as NSError {
            // 检查是否是网络连接错误
            if error.domain == NSURLErrorDomain {
                var errorMsg = "网络连接失败: "
                switch error.code {
                case NSURLErrorTimedOut:
                    errorMsg += "请求超时，请检查服务器地址和网络连接"
                case NSURLErrorCannotConnectToHost:
                    errorMsg += "无法连接到服务器 \(baseURL)"
                case NSURLErrorNetworkConnectionLost:
                    errorMsg += "网络连接已断开"
                case NSURLErrorNotConnectedToInternet:
                    errorMsg += "设备未连接到互联网"
                default:
                    errorMsg += error.localizedDescription
                }
                LogManager.shared.log(errorMsg, category: "网络错误")
                throw NSError(domain: "APIService", code: error.code, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            throw error
        }
    }
    
    // MARK: - 获取用户信息
    func getUserInfo() async throws -> UserInfo {
        let urlString = "\(baseURL)/getUserInfo"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        components.queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken)
        ]
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        struct UserInfoData: Codable {
            let userInfo: UserInfo
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<UserInfoData>.self, from: data)
        
        if apiResponse.isSuccess, let userInfoData = apiResponse.data {
            return userInfoData.userInfo
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取用户信息失败"])
        }
    }
    
    // MARK: - 获取书架列表
    func fetchBookshelf() async throws {
        guard !accessToken.isEmpty else {
            throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先登录"])
        }
        
        let queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "version", value: "1.0.0")
        ]
        
        let (data, httpResponse) = try await requestWithFailback(endpoint: "getBookshelf", queryItems: queryItems)
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<[Book]>.self, from: data)
        
        if apiResponse.isSuccess, let books = apiResponse.data {
            await MainActor.run {
                self.books = books
            }
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取书架失败"])
        }
    }
    
    // MARK: - 获取章节列表
    func fetchChapterList(bookUrl: String, bookSourceUrl: String?) async throws -> [BookChapter] {
        var queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "url", value: bookUrl)
        ]
        
        if let bookSourceUrl = bookSourceUrl {
            queryItems.append(URLQueryItem(name: "bookSourceUrl", value: bookSourceUrl))
        }
        
        let (data, httpResponse) = try await requestWithFailback(endpoint: "getChapterList", queryItems: queryItems)
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<[BookChapter]>.self, from: data)
        
        if apiResponse.isSuccess, let chapters = apiResponse.data {
            return chapters
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取章节列表失败"])
        }
    }
    
    // MARK: - 获取章节内容
    func fetchChapterContent(bookUrl: String, bookSourceUrl: String?, index: Int, bookName: String? = nil) async throws -> String {
        let useSanitization = UserPreferences.shared.useReplaceRuleSanitization
        let cacheKey = buildChapterCacheKey(
            bookUrl: bookUrl,
            bookSourceUrl: bookSourceUrl,
            index: index,
            useReplaceRuleSanitization: useSanitization
        )
        
        if let cachedContent = await chapterCache.get(for: cacheKey) {
            return cachedContent
        }
        
        let (task, isNewTask) = taskForChapterContent(cacheKey: cacheKey) {
            Task<String, Error> { [weak self] in
                guard let self = self else {
                    throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务已释放"])
                }
                
                if let cachedContent = await self.chapterCache.get(for: cacheKey) {
                    return cachedContent
                }
                
                var queryItems = [
                    URLQueryItem(name: "accessToken", value: self.accessToken),
                    URLQueryItem(name: "url", value: bookUrl),
                    URLQueryItem(name: "index", value: "\(index)"),
                    URLQueryItem(name: "type", value: "0")
                ]
                
                if let bookSourceUrl = bookSourceUrl {
                    queryItems.append(URLQueryItem(name: "bookSourceUrl", value: bookSourceUrl))
                }
                
                let endpoint: String
                if useSanitization {
                    endpoint = "getBookContentNew"
                    if let bookName = bookName, !bookName.isEmpty {
                        queryItems.append(URLQueryItem(name: "bookname", value: bookName))
                    }
                    queryItems.append(URLQueryItem(name: "useReplaceRule", value: "1"))
                } else {
                    endpoint = "getBookContent"
                }
                
                let (data, httpResponse) = try await self.requestWithFailback(endpoint: endpoint, queryItems: queryItems)
                
                guard httpResponse.statusCode == 200 else {
                    throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
                }
                
                if useSanitization {
                    if let apiResponse = try? JSONDecoder().decode(APIResponse<ChapterContentResponse>.self, from: data),
                       apiResponse.isSuccess,
                       let contentResponse = apiResponse.data {
                        let content = contentResponse.text
                        await self.chapterCache.set(content, for: cacheKey)
                        return content
                    }
                    
                    // 兼容旧服务端返回结构
                    let fallback = try JSONDecoder().decode(APIResponse<String>.self, from: data)
                    if fallback.isSuccess, let content = fallback.data {
                        await self.chapterCache.set(content, for: cacheKey)
                        return content
                    } else {
                        throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: fallback.errorMsg ?? "获取章节内容失败"])
                    }
                } else {
                    let apiResponse = try JSONDecoder().decode(APIResponse<String>.self, from: data)
                    
                    if apiResponse.isSuccess, let content = apiResponse.data {
                        await self.chapterCache.set(content, for: cacheKey)
                        return content
                    } else {
                        throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取章节内容失败"])
                    }
                }
            }
        }
        
        if isNewTask {
            do {
                defer { removeInFlightTask(for: cacheKey) }
                return try await task.value
            }
        } else {
            return try await task.value
        }
    }
    
    // MARK: - 批量预载章节内容
    func preloadChapterContents(bookUrl: String, bookSourceUrl: String?, indices: [Int], bookName: String? = nil) async {
        let uniqueIndices = Array(Set(indices)).sorted()
        guard !uniqueIndices.isEmpty else {
            return
        }
        
        await withTaskGroup(of: Void.self) { group in
            for index in uniqueIndices {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    do {
                        _ = try await self.fetchChapterContent(bookUrl: bookUrl, bookSourceUrl: bookSourceUrl, index: index, bookName: bookName)
                    } catch {
                        LogManager.shared.log("章节预载失败 - index: \(index), error: \(error.localizedDescription)", category: "缓存")
                    }
                }
            }
        }
    }
    
    // MARK: - 保存阅读进度
    func saveBookProgress(bookUrl: String, index: Int, pos: Double, title: String?) async throws {
        let urlString = "\(baseURL)/saveBookProgress"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "url", value: bookUrl),
            URLQueryItem(name: "index", value: "\(index)"),
            URLQueryItem(name: "pos", value: "\(pos)")
        ]
        
        if let title = title {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        let apiResponse = try JSONDecoder().decode(APIResponse<String>.self, from: data)
        
        if !apiResponse.isSuccess {
            print("保存进度失败: \(apiResponse.errorMsg ?? "未知错误")")
        }
    }
    
    // MARK: - 获取 TTS 引擎列表
    func fetchTTSList() async throws -> [HttpTTS] {
        let urlString = "\(baseURL)/getalltts"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        components.queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken)
        ]
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<[HttpTTS]>.self, from: data)
        
        if apiResponse.isSuccess, let ttsList = apiResponse.data {
            return ttsList
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取TTS引擎列表失败"])
        }
    }
    
    // MARK: - 获取默认 TTS
    func fetchDefaultTTS() async throws -> String {
        let urlString = "\(baseURL)/getdefaulttts"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        components.queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken)
        ]
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        let apiResponse = try JSONDecoder().decode(APIResponse<String>.self, from: data)
        
        return apiResponse.data ?? ""
    }
    
    // MARK: - 构建 TTS 音频 URL
    func buildTTSAudioURL(ttsId: String, text: String, speechRate: Double) -> URL? {
        let urlString = "\(baseURL)/tts"
        guard var components = URLComponents(string: urlString) else {
            return nil
        }
        
        components.queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "id", value: ttsId),
            URLQueryItem(name: "speakText", value: text),
            URLQueryItem(name: "speechRate", value: "\(speechRate)")
        ]
        
        return components.url
    }
    
    // MARK: - 清除本地缓存
    func clearLocalCache() {
        clearAllInFlightChapterTasks()
        Task {
            await chapterCache.removeAll()
        }
    }
    
    // MARK: - 清除所有远程缓存
    func clearAllRemoteCache() async throws {
        let urlString = "\(baseURL)/cleancaches"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        components.queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken)
        ]
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "无效的服务器响应"])
        }
        
        if httpResponse.statusCode != 200 {
            let responseText = String(data: data, encoding: .utf8) ?? "无法解析响应"
            throw NSError(domain: "APIService", code: httpResponse.statusCode, 
                         userInfo: [NSLocalizedDescriptionKey: "服务器错误(状态码: \(httpResponse.statusCode)): \(responseText)"])
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<String>.self, from: data)
        if !apiResponse.isSuccess {
            throw NSError(domain: "APIService", code: 500, 
                         userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "清除缓存失败"])
        }
    }
    
    private func buildChapterCacheKey(bookUrl: String, bookSourceUrl: String?, index: Int, useReplaceRuleSanitization: Bool) -> String {
        "\(bookUrl)|\(bookSourceUrl ?? "default")|\(index)|san:\(useReplaceRuleSanitization ? 1 : 0)"
    }
    
    private func taskForChapterContent(cacheKey: String, create: () -> Task<String, Error>) -> (Task<String, Error>, Bool) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        
        if let existing = inFlightChapterTasks[cacheKey] {
            return (existing, false)
        }
        
        let task = create()
        inFlightChapterTasks[cacheKey] = task
        return (task, true)
    }
    
    private func removeInFlightTask(for key: String) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlightChapterTasks.removeValue(forKey: key)
    }
    
    private func clearAllInFlightChapterTasks() {
        inFlightLock.lock()
        let tasks = Array(inFlightChapterTasks.values)
        inFlightChapterTasks.removeAll()
        inFlightLock.unlock()
        
        tasks.forEach { $0.cancel() }
    }
}
