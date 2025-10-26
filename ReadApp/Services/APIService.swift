import Foundation
import Combine
import UIKit

class APIService: ObservableObject {
    static let shared = APIService()
    static let apiVersion = 5
    
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // 章节内容缓存
    private var contentCache: [String: String] = [:]
    
    var baseURL: String {
        let serverURL = UserPreferences.shared.serverURL
        if serverURL.isEmpty {
            return "http://127.0.0.1:8080/api/\(Self.apiVersion)"
        }
        return "\(serverURL)/api/\(Self.apiVersion)"
    }
    
    private var accessToken: String {
        UserPreferences.shared.accessToken
    }
    
    private init() {}
    
    // MARK: - 登录
    func login(username: String, password: String) async throws -> String {
        let urlString = "\(baseURL)/login"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        // 获取设备型号（在主线程同步获取）
        let deviceModel = await MainActor.run { UIDevice.current.model }
        
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "model", value: deviceModel)
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
        
        let apiResponse = try JSONDecoder().decode(APIResponse<LoginResponse>.self, from: data)
        
        if apiResponse.isSuccess, let loginData = apiResponse.data {
            return loginData.accessToken
        } else {
            throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "登录失败"])
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
        
        let urlString = "\(baseURL)/getBookshelf"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        components.queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "version", value: "1.0.0")
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
        let urlString = "\(baseURL)/getChapterList"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "url", value: bookUrl)
        ]
        
        if let bookSourceUrl = bookSourceUrl {
            queryItems.append(URLQueryItem(name: "bookSourceUrl", value: bookSourceUrl))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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
    func fetchChapterContent(bookUrl: String, bookSourceUrl: String?, index: Int) async throws -> String {
        // 生成缓存key
        let cacheKey = "\(bookUrl)_\(index)"
        
        // 检查缓存
        if let cachedContent = contentCache[cacheKey] {
            return cachedContent
        }
        
        let urlString = "\(baseURL)/getBookContent"
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "url", value: bookUrl),
            URLQueryItem(name: "index", value: "\(index)"),
            URLQueryItem(name: "type", value: "0")
        ]
        
        if let bookSourceUrl = bookSourceUrl {
            queryItems.append(URLQueryItem(name: "bookSourceUrl", value: bookSourceUrl))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<String>.self, from: data)
        
        if apiResponse.isSuccess, let content = apiResponse.data {
            // 保存到缓存
            contentCache[cacheKey] = content
            return content
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取章节内容失败"])
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
        contentCache.removeAll()
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
}

