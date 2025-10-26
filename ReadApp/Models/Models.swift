import Foundation

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
        self.ttsPreloadCount = savedPreloadCount == 0 ? 3 : savedPreloadCount
    }
    
    func logout() {
        accessToken = ""
        username = ""
        isLoggedIn = false
    }
}

