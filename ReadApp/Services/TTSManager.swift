import Foundation
import AVFoundation
import MediaPlayer

class TTSManager: NSObject, ObservableObject {
    static let shared = TTSManager()
    private let logger = LogManager.shared
    
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentSentenceIndex = 0
    @Published var totalSentences = 0
    @Published var isLoading = false
    @Published var preloadedIndices: Set<Int> = []  // 已预载成功的段落索引
    
    private var audioPlayer: AVAudioPlayer?
    private var sentences: [String] = []
    var currentChapterIndex: Int = 0  // 公开给ReadingView使用
    private var chapters: [BookChapter] = []
    var bookUrl: String = ""  // 公开给ReadingView使用
    private var bookSourceUrl: String?
    private var bookTitle: String = ""
    private var onChapterChange: ((Int) -> Void)?
    private var currentSentenceObserver: Any?
    
    // 预载缓存
    private var audioCache: [Int: Data] = [:]  // 索引 -> 音频数据
    private var preloadingIndices: Set<Int> = []  // 正在预载的索引
    
    // 下一章预载
    private var nextChapterSentences: [String] = []  // 下一章的段落
    private var nextChapterCache: [Int: Data] = [:]  // 下一章的音频缓存
    
    // 章节名朗读
    private var isReadingChapterTitle = false  // 是否正在朗读章节名
    
    private override init() {
        super.init()
        logger.log("TTSManager 初始化", category: "TTS")
        setupAudioSession()
        setupRemoteCommands()
        setupNotifications()
    }
    
    // MARK: - 配置音频会话
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            logger.log("配置音频会话 - Category: playback, Mode: default", category: "TTS")
            
            // 使用更简单的配置，先设置category
            try audioSession.setCategory(.playback, options: [])
            
            // 然后激活会话
            try audioSession.setActive(true)
            
            logger.log("音频会话配置成功", category: "TTS")
        } catch {
            logger.log("音频会话设置失败: \(error.localizedDescription)", category: "TTS错误")
            logger.log("错误详情: \(error)", category: "TTS错误")
        }
    }
    
    // MARK: - 设置远程控制
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextChapter()
            return .success
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousChapter()
            return .success
        }
    }
    
    // MARK: - 设置通知监听
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }
    
    // MARK: - 播放完成通知
    @objc private func playerDidFinishPlaying(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentSentenceIndex += 1
            self.speakNextSentence()
        }
    }
    
    // MARK: - 更新锁屏信息
    private func updateNowPlayingInfo(chapterTitle: String) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = chapterTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = bookTitle
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying && !isPaused ? 1.0 : 0.0
        
        if totalSentences > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(totalSentences)
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentSentenceIndex)
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    // MARK: - 开始朗读
    func startReading(text: String, chapters: [BookChapter], currentIndex: Int, bookUrl: String, bookSourceUrl: String?, bookTitle: String, onChapterChange: @escaping (Int) -> Void, resumeFromProgress: Bool = true) {
        logger.log("开始朗读 - 书名: \(bookTitle), 章节: \(currentIndex)/\(chapters.count)", category: "TTS")
        logger.log("内容长度: \(text.count) 字符", category: "TTS")
        
        self.chapters = chapters
        self.currentChapterIndex = currentIndex
        self.bookUrl = bookUrl
        self.bookSourceUrl = bookSourceUrl
        self.bookTitle = bookTitle
        self.onChapterChange = onChapterChange
        
        // 清空缓存和预载状态
        audioCache.removeAll()
        preloadedIndices.removeAll()
        nextChapterCache.removeAll()
        nextChapterSentences.removeAll()
        
        // 分句
        sentences = splitTextIntoSentences(text)
        totalSentences = sentences.count
        
        // 尝试恢复进度
        if resumeFromProgress, let progress = UserPreferences.shared.getTTSProgress(bookUrl: bookUrl) {
            if progress.chapterIndex == currentIndex && progress.sentenceIndex < sentences.count {
                currentSentenceIndex = progress.sentenceIndex
                logger.log("恢复TTS进度 - 章节: \(currentIndex), 段落: \(currentSentenceIndex)", category: "TTS")
            } else {
                currentSentenceIndex = 0
            }
        } else {
            currentSentenceIndex = 0
        }
        
        logger.log("分句完成 - 共 \(totalSentences) 句, 从第 \(currentSentenceIndex + 1) 句开始", category: "TTS")
        
        // 更新锁屏信息
        if currentIndex < chapters.count {
            updateNowPlayingInfo(chapterTitle: chapters[currentIndex].title)
        }
        
        isPlaying = true
        isPaused = false
        
        // 如果从头开始播放，先朗读章节名
        if currentSentenceIndex == 0 {
            speakChapterTitle()
        } else {
            speakNextSentence()
        }
    }
    
    // MARK: - 上一段
    func previousSentence() {
        if currentSentenceIndex > 0 {
            currentSentenceIndex -= 1
            audioPlayer?.stop()
            audioPlayer = nil
            
            // 保存进度
            UserPreferences.shared.saveTTSProgress(bookUrl: bookUrl, chapterIndex: currentChapterIndex, sentenceIndex: currentSentenceIndex)
            
            if isPlaying {
                speakNextSentence()
            }
        }
    }
    
    // MARK: - 下一段
    func nextSentence() {
        if currentSentenceIndex < sentences.count - 1 {
            currentSentenceIndex += 1
            audioPlayer?.stop()
            audioPlayer = nil
            
            // 保存进度
            UserPreferences.shared.saveTTSProgress(bookUrl: bookUrl, chapterIndex: currentChapterIndex, sentenceIndex: currentSentenceIndex)
            
            if isPlaying {
                speakNextSentence()
            }
        }
    }
    
    // MARK: - 过滤SVG标签
    private func removeSVGTags(_ text: String) -> String {
        var result = text
        
        // 移除SVG标签（包括多行SVG）
        let svgPattern = "<svg[^>]*>.*?</svg>"
        if let svgRegex = try? NSRegularExpression(pattern: svgPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = svgRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        
        // 只移除常见的HTML标签，保留文本内容
        // 先移除img标签
        let imgPattern = "<img[^>]*>"
        if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = imgRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        
        // 移除其他标签但保留内容
        let htmlPattern = "<[^>]+>"
        if let htmlRegex = try? NSRegularExpression(pattern: htmlPattern, options: []) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = htmlRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        
        // 清理HTML实体
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        
        logger.log("原始文本长度: \(text.count), 过滤后: \(result.count)", category: "TTS")
        return result
    }
    
    // MARK: - 智能分段（优化版）
    private func splitTextIntoSentences(_ text: String) -> [String] {
        // 先过滤SVG和HTML标签
        let filtered = removeSVGTags(text)
        
        // 按换行符分割，保持原文分段
        let paragraphs = filtered.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }  // 移除每段的前后空白
            .filter { !$0.isEmpty }  // 过滤空段落
        
        return paragraphs
    }
    
    // MARK: - 朗读章节名
    private func speakChapterTitle() {
        guard currentChapterIndex < chapters.count else {
            speakNextSentence()
            return
        }
        
        let chapterTitle = chapters[currentChapterIndex].title
        logger.log("开始朗读章节名: \(chapterTitle)", category: "TTS")
        
        isReadingChapterTitle = true
        
        // 检查是否选择了 TTS 引擎
        let ttsId = UserPreferences.shared.selectedTTSId
        if ttsId.isEmpty {
            logger.log("未选择 TTS 引擎，跳过章节名朗读", category: "TTS")
            isReadingChapterTitle = false
            speakNextSentence()
            return
        }
        
        let speechRate = UserPreferences.shared.speechRate
        
        // 构建 TTS 音频 URL
        guard let audioURL = APIService.shared.buildTTSAudioURL(
            ttsId: ttsId,
            text: chapterTitle,
            speechRate: speechRate
        ) else {
            logger.log("构建章节名音频 URL 失败", category: "TTS错误")
            isReadingChapterTitle = false
            speakNextSentence()
            return
        }
        
        // 播放音频
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: audioURL)
                
                await MainActor.run {
                    // 检查HTTP响应
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200,
                       let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                       contentType.contains("audio"),
                       data.count >= 10000 {
                        playAudioWithData(data: data)
                    } else {
                        logger.log("章节名音频无效，跳过", category: "TTS")
                        isReadingChapterTitle = false
                        speakNextSentence()
                    }
                }
            } catch {
                logger.log("章节名音频下载失败: \(error)", category: "TTS错误")
                await MainActor.run {
                    isReadingChapterTitle = false
                    speakNextSentence()
                }
            }
        }
    }
    
    // MARK: - 朗读下一句
    private func speakNextSentence() {
        guard currentSentenceIndex < sentences.count else {
            logger.log("当前章节朗读完成，准备下一章", category: "TTS")
            // 当前章节读完，自动读下一章
            nextChapter()
            return
        }
        
        // 保存进度
        UserPreferences.shared.saveTTSProgress(bookUrl: bookUrl, chapterIndex: currentChapterIndex, sentenceIndex: currentSentenceIndex)
        
        // 检查是否选择了 TTS 引擎
        let ttsId = UserPreferences.shared.selectedTTSId
        if ttsId.isEmpty {
            logger.log("未选择 TTS 引擎，停止播放", category: "TTS错误")
            stop()
            return
        }
        
        let sentence = sentences[currentSentenceIndex]
        let speechRate = UserPreferences.shared.speechRate
        
        logger.log("朗读句子 \(currentSentenceIndex + 1)/\(totalSentences) - 语速: \(speechRate)", category: "TTS")
        logger.log("句子内容: \(sentence.prefix(50))...", category: "TTS")
        
        // 构建 TTS 音频 URL
        guard let audioURL = APIService.shared.buildTTSAudioURL(
            ttsId: ttsId,
            text: sentence,
            speechRate: speechRate
        ) else {
            logger.log("构建音频 URL 失败", category: "TTS错误")
            currentSentenceIndex += 1
            speakNextSentence()
            return
        }
        
        // 播放音频
        playAudio(url: audioURL)
        
        // 更新锁屏信息
        if currentChapterIndex < chapters.count {
            updateNowPlayingInfo(chapterTitle: chapters[currentChapterIndex].title)
        }
    }
    
    // MARK: - 播放音频
    private func playAudio(url: URL) {
        isLoading = true
        
        logger.log("TTS 音频 URL: \(url.absoluteString)", category: "TTS")
        
        // 检查缓存
        if let cachedData = audioCache[currentSentenceIndex] {
            logger.log("✅ 使用缓存音频 - 索引: \(currentSentenceIndex)", category: "TTS")
            playAudioWithData(data: cachedData)
            // 触发下一批预载
            startPreloading()
            return
        }
        
        // 下载音频数据并使用 AVAudioPlayer 播放
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                logger.log("✅ URL可访问，数据大小: \(data.count) 字节", category: "TTS")
                
                var isValidAudio = false
                if let httpResponse = response as? HTTPURLResponse {
                    logger.log("HTTP状态码: \(httpResponse.statusCode)", category: "TTS")
                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                    logger.log("Content-Type: \(contentType)", category: "TTS")
                    
                    // 验证是否是有效的音频数据
                    if httpResponse.statusCode == 200 && contentType.contains("audio") && data.count >= 10000 {
                        isValidAudio = true
                    }
                }
                
                // 检查数据是否为有效音频
                if !isValidAudio || data.count < 10000 {
                    logger.log("❌ 数据无效或太小（需要至少10KB），实际: \(data.count) 字节", category: "TTS错误")
                    if data.count < 2000, let text = String(data: data, encoding: .utf8) {
                        logger.log("返回内容: \(text.prefix(500))", category: "TTS错误")
                    }
                    await MainActor.run {
                        isLoading = false
                        currentSentenceIndex += 1
                        speakNextSentence()
                    }
                    return
                }
                
                // 在主线程创建并播放音频
                await MainActor.run {
                    playAudioWithData(data: data)
                    // 触发预载
                    startPreloading()
                }
            } catch {
                logger.log("❌ URL不可访问: \(error.localizedDescription)", category: "TTS错误")
                await MainActor.run {
                    isLoading = false
                    currentSentenceIndex += 1
                    speakNextSentence()
                }
            }
        }
    }
    
    // MARK: - 开始预载
    private func startPreloading() {
        let preloadCount = UserPreferences.shared.ttsPreloadCount
        guard preloadCount > 0 else { return }
        
        let startIndex = currentSentenceIndex + 1
        let endIndex = min(startIndex + preloadCount, sentences.count)
        
        // 预载当前章节的段落
        for index in startIndex..<endIndex {
            // 如果已经缓存或正在预载，跳过
            if audioCache[index] != nil || preloadingIndices.contains(index) {
                continue
            }
            
            preloadingIndices.insert(index)
            preloadAudio(at: index)
        }
        
        // 如果接近章节末尾（剩余段落少于预载数量的一半），开始预载下一章
        let remainingSentences = sentences.count - currentSentenceIndex
        if remainingSentences <= preloadCount / 2 && currentChapterIndex < chapters.count - 1 {
            logger.log("接近章节末尾，开始预载下一章", category: "TTS")
            preloadNextChapter()
        }
    }
    
    // MARK: - 预载音频
    private func preloadAudio(at index: Int) {
        guard index < sentences.count else { return }
        
        let sentence = sentences[index]
        let speechRate = UserPreferences.shared.speechRate
        
        guard let encodedText = sentence.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        
        // 使用完整的API路径（与APIService.buildTTSAudioURL保持一致）
        let urlString = "\(UserPreferences.shared.serverURL)/api/\(APIService.apiVersion)/tts?accessToken=\(UserPreferences.shared.accessToken)&id=\(UserPreferences.shared.selectedTTSId)&speakText=\(encodedText)&speechRate=\(speechRate)"
        
        guard let url = URL(string: urlString) else { return }
        
        logger.log("预载索引: \(index), URL: \(url.absoluteString)", category: "TTS")
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                await MainActor.run {
                    // 检查HTTP响应
                    if let httpResponse = response as? HTTPURLResponse {
                        logger.log("预载索引: \(index) - HTTP状态: \(httpResponse.statusCode), Content-Type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"), 大小: \(data.count) 字节", category: "TTS")
                        
                        // 验证是否是有效的音频数据
                        if httpResponse.statusCode == 200,
                           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                           contentType.contains("audio"),
                           data.count >= 10000 {  // 音频数据至少应该有10KB
                            audioCache[index] = data
                            preloadedIndices.insert(index)  // 标记为已预载
                            logger.log("✅ 预载成功 - 索引: \(index), 大小: \(data.count) 字节", category: "TTS")
                        } else {
                            // 数据无效，记录详细信息
                            if data.count < 10000 {
                                if let text = String(data: data, encoding: .utf8) {
                                    logger.log("❌ 预载失败 - 索引: \(index), 数据太小或非音频数据，内容: \(text.prefix(200))", category: "TTS错误")
                                } else {
                                    logger.log("❌ 预载失败 - 索引: \(index), 数据太小: \(data.count) 字节", category: "TTS错误")
                                }
                            }
                        }
                    }
                    preloadingIndices.remove(index)
                }
            } catch {
                await MainActor.run {
                    preloadingIndices.remove(index)
                    logger.log("❌ 预载网络错误 - 索引: \(index), 错误: \(error.localizedDescription)", category: "TTS错误")
                }
            }
        }
    }
    
    private func playAudioWithData(data: Data) {
        do {
            // 使用 AVAudioPlayer 播放下载的数据
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.volume = 1.0
            
            logger.log("创建 AVAudioPlayer 成功", category: "TTS")
            logger.log("音频时长: \(audioPlayer?.duration ?? 0) 秒", category: "TTS")
            logger.log("音频格式: \(audioPlayer?.format.description ?? "unknown")", category: "TTS")
            
            let success = audioPlayer?.play() ?? false
            if success {
                logger.log("✅ 音频开始播放", category: "TTS")
                isLoading = false
            } else {
                logger.log("❌ 音频播放失败", category: "TTS错误")
                isLoading = false
                currentSentenceIndex += 1
                speakNextSentence()
            }
        } catch {
            logger.log("❌ 创建 AVAudioPlayer 失败: \(error.localizedDescription)", category: "TTS错误")
            logger.log("错误详情: \(error)", category: "TTS错误")
            isLoading = false
            currentSentenceIndex += 1
            speakNextSentence()
        }
    }
    
    
    // MARK: - 暂停
    func pause() {
        logger.log("收到暂停命令 - isPlaying: \(isPlaying), isPaused: \(isPaused), audioPlayer: \(audioPlayer != nil)", category: "TTS")
        
        if isPlaying && !isPaused {
            if let player = audioPlayer {
                player.pause()
                isPaused = true
                logger.log("✅ TTS 暂停", category: "TTS")
                updatePlaybackRate()
            } else {
                logger.log("⚠️ audioPlayer 不存在，无法暂停", category: "TTS")
            }
        } else if isPaused {
            logger.log("TTS 已经处于暂停状态", category: "TTS")
        } else {
            logger.log("TTS 未在播放，无法暂停", category: "TTS")
        }
    }
    
    // MARK: - 继续
    func resume() {
        logger.log("收到恢复命令 - isPlaying: \(isPlaying), isPaused: \(isPaused), audioPlayer: \(audioPlayer != nil)", category: "TTS")
        
        if isPlaying && isPaused {
            // 检查 audioPlayer 是否存在
            if let player = audioPlayer {
                player.play()
                isPaused = false
                logger.log("✅ TTS 恢复播放", category: "TTS")
                updatePlaybackRate()
            } else {
                // audioPlayer 不存在，重新播放当前句子
                logger.log("⚠️ audioPlayer 不存在，重新播放当前句子", category: "TTS")
                isPaused = false
                speakNextSentence()
            }
        } else if !isPlaying {
            // 如果已经停止，重新开始
            logger.log("TTS 未在播放，重新开始", category: "TTS")
            isPlaying = true
            isPaused = false
            speakNextSentence()
        } else {
            // isPlaying = true 但 isPaused = false，已经在播放中
            logger.log("TTS 已经在播放中", category: "TTS")
        }
    }
    
    // MARK: - 预载下一章
    private func preloadNextChapter() {
        // 如果已经在预载下一章或已有下一章数据，跳过
        guard nextChapterSentences.isEmpty else { return }
        guard currentChapterIndex < chapters.count - 1 else { return }
        
        let nextChapterIndex = currentChapterIndex + 1
        logger.log("开始预载下一章: \(nextChapterIndex)", category: "TTS")
        
        Task {
            do {
                let content = try await APIService.shared.fetchChapterContent(
                    bookUrl: bookUrl,
                    bookSourceUrl: bookSourceUrl,
                    index: nextChapterIndex
                )
                
                await MainActor.run {
                    // 分段
                    nextChapterSentences = splitTextIntoSentences(content)
                    logger.log("下一章分段完成，共 \(nextChapterSentences.count) 段", category: "TTS")
                    
                    // 预载下一章的前几个段落
                    let preloadCount = min(3, nextChapterSentences.count)  // 最多预载3个段落
                    for i in 0..<preloadCount {
                        preloadNextChapterAudio(at: i)
                    }
                }
            } catch {
                logger.log("预载下一章失败: \(error)", category: "TTS错误")
            }
        }
    }
    
    // MARK: - 预载下一章的音频
    private func preloadNextChapterAudio(at index: Int) {
        guard index < nextChapterSentences.count else { return }
        guard nextChapterCache[index] == nil else { return }
        
        let sentence = nextChapterSentences[index]
        let speechRate = UserPreferences.shared.speechRate
        let ttsId = UserPreferences.shared.selectedTTSId
        
        guard !ttsId.isEmpty else { return }
        guard let encodedText = sentence.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        
        let urlString = "\(UserPreferences.shared.serverURL)/api/\(APIService.apiVersion)/tts?accessToken=\(UserPreferences.shared.accessToken)&id=\(ttsId)&speakText=\(encodedText)&speechRate=\(speechRate)"
        
        guard let url = URL(string: urlString) else { return }
        
        logger.log("预载下一章音频 - 索引: \(index)", category: "TTS")
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                await MainActor.run {
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200,
                       let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                       contentType.contains("audio"),
                       data.count >= 10000 {
                        nextChapterCache[index] = data
                        logger.log("✅ 下一章预载成功 - 索引: \(index), 大小: \(data.count) 字节", category: "TTS")
                    }
                }
            } catch {
                logger.log("下一章预载失败 - 索引: \(index), 错误: \(error)", category: "TTS错误")
            }
        }
    }
    
    // MARK: - 停止
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        isPaused = false
        currentSentenceIndex = 0
        sentences = []
        isLoading = false
        // 清理缓存
        audioCache.removeAll()
        preloadingIndices.removeAll()
        nextChapterCache.removeAll()
        nextChapterSentences.removeAll()
        logger.log("TTS 停止", category: "TTS")
    }
    
    // MARK: - 下一章
    func nextChapter() {
        guard currentChapterIndex < chapters.count - 1 else { return }
        currentChapterIndex += 1
        onChapterChange?(currentChapterIndex)
        loadAndReadChapter()
    }
    
    // MARK: - 上一章
    func previousChapter() {
        guard currentChapterIndex > 0 else { return }
        currentChapterIndex -= 1
        onChapterChange?(currentChapterIndex)
        loadAndReadChapter()
    }
    
    // MARK: - 加载并朗读章节
    private func loadAndReadChapter() {
        stop()
        
        // 检查是否有预载的下一章数据
        if !nextChapterSentences.isEmpty {
            logger.log("使用已预载的下一章数据", category: "TTS")
            
            // 使用预载的数据
            sentences = nextChapterSentences
            totalSentences = sentences.count
            currentSentenceIndex = 0
            
            // 将下一章的缓存移动到当前章节
            audioCache = nextChapterCache
            preloadedIndices = Set(nextChapterCache.keys)
            
            // 清空下一章缓存
            nextChapterCache.removeAll()
            nextChapterSentences.removeAll()
            
            isPlaying = true
            isPaused = false
            
            if currentChapterIndex < chapters.count {
                updateNowPlayingInfo(chapterTitle: chapters[currentChapterIndex].title)
            }
            
            // 先朗读章节名
            speakChapterTitle()
            
            return
        }
        
        // 没有预载数据，正常加载
        Task {
            do {
                let content = try await APIService.shared.fetchChapterContent(
                    bookUrl: bookUrl,
                    bookSourceUrl: bookSourceUrl,
                    index: currentChapterIndex
                )
                
                await MainActor.run {
                    sentences = splitTextIntoSentences(content)
                    totalSentences = sentences.count
                    currentSentenceIndex = 0
                    
                    // 清空当前章节的缓存
                    audioCache.removeAll()
                    preloadedIndices.removeAll()
                    
                    isPlaying = true
                    isPaused = false
                    
                    if currentChapterIndex < chapters.count {
                        updateNowPlayingInfo(chapterTitle: chapters[currentChapterIndex].title)
                    }
                    
                    // 先朗读章节名
                    speakChapterTitle()
                }
            } catch {
                logger.log("加载章节失败: \(error)", category: "TTS错误")
            }
        }
    }
    
    // MARK: - 更新播放速率
    private func updatePlaybackRate() {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying && !isPaused ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        logger.log("TTSManager 销毁", category: "TTS")
    }
}

// MARK: - AVAudioPlayerDelegate
extension TTSManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        logger.log("音频播放完成 - 成功: \(flag)", category: "TTS")
        
        // 如果正在朗读章节名，播放完后开始朗读内容
        if isReadingChapterTitle {
            isReadingChapterTitle = false
            speakNextSentence()
            return
        }
        
        if flag {
            // 播放下一句
            currentSentenceIndex += 1
            speakNextSentence()
        } else {
            logger.log("音频播放失败，跳过", category: "TTS错误")
            currentSentenceIndex += 1
            speakNextSentence()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            logger.log("❌ 音频解码错误: \(error.localizedDescription)", category: "TTS错误")
        }
        // 跳过这一句
        currentSentenceIndex += 1
        speakNextSentence()
    }
}
