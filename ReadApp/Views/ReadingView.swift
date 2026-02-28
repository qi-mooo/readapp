import SwiftUI
import UIKit

private struct ChapterHeaderMinYPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReadingView: View {
    let book: Book
    @EnvironmentObject var apiService: APIService
    @StateObject private var ttsManager = TTSManager.shared
    @StateObject private var preferences = UserPreferences.shared
    
    @State private var chapters: [BookChapter] = []
    @State private var currentChapterIndex: Int
    @State private var currentContent = ""
    @State private var contentSentences: [String] = []  // 分段的内容
    @State private var isLoading = false
    @State private var showChapterList = false
    @State private var showTTSControls = false
    @State private var errorMessage: String?
    @State private var showUIControls = true  // 控制UI显示/隐藏（TTS播放时的沉浸模式）
    @State private var scrollProxy: ScrollViewProxy?  // 保存ScrollViewProxy引用
    @State private var lastTTSSentenceIndex: Int?  // 上次TTS播放的段落索引
    @State private var preloadTask: Task<Void, Never>?
    @State private var appendTask: Task<Void, Never>?
    @State private var continuousChapters: [ContinuousChapterContent] = []
    @State private var continuousChapterIndices: Set<Int> = []
    @State private var isAppendingNextChapter = false
    @State private var continuousSessionID = UUID()
    @State private var lastUserScrollInteractionAt = Date.distantPast
    @State private var autoChapterSwitchDisabledUntil = Date.distantPast
    @State private var latestChapterHeaderMinYs: [Int: CGFloat] = [:]
    @State private var chapterSwitchDebounceTask: Task<Void, Never>?
    @State private var pendingScrollToChapterTopIndex: Int?
    @State private var pendingScrollToParagraph: (chapterIndex: Int, paragraphIndex: Int)?
    @State private var shouldRestorePositionAfterTTSStop = true
    
    private struct ContinuousChapterContent: Identifiable {
        let chapterIndex: Int
        let title: String
        let paragraphs: [String]
        
        var id: Int { chapterIndex }
    }
    
    init(book: Book) {
        self.book = book
        _currentChapterIndex = State(initialValue: book.durChapterIndex ?? 0)
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 内容区域
                GeometryReader { scrollGeometry in
                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // TTS模式显示当前章节标题
                            if showUIControls && ttsManager.isPlaying {
                                if currentChapterIndex < chapters.count {
                                    Text(chapters[currentChapterIndex].title)
                                        .font(.title)
                                        .fontWeight(.bold)
                                        .padding(.bottom, 8)
                                }
                            }
                        
                            // 正文内容
                            if !contentSentences.isEmpty && ttsManager.isPlaying {
                                // TTS播放模式：使用分句显示并高亮当前句子
                                VStack(alignment: .leading, spacing: preferences.fontSize * 0.8) {
                                    ForEach(Array(contentSentences.enumerated()), id: \.offset) { index, sentence in
                                        Text("　　" + sentence.trimmingCharacters(in: .whitespacesAndNewlines))
                                            .font(.system(size: preferences.fontSize))
                                            .lineSpacing(preferences.lineSpacing)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(
                                                        // 当前播放：蓝色高亮
                                                        index == ttsManager.currentSentenceIndex
                                                            ? Color.blue.opacity(0.25)
                                                            // 已预载且未播放：绿色高亮
                                                            : (ttsManager.preloadedIndices.contains(index) && index > ttsManager.currentSentenceIndex)
                                                                ? Color.green.opacity(0.15)
                                                                : Color.clear
                                                    )
                                                    .animation(.easeInOut(duration: 0.3), value: ttsManager.currentSentenceIndex)
                                                    .animation(.easeInOut(duration: 0.3), value: ttsManager.preloadedIndices.count)
                                            )
                                            .id(index)
                                            .scaleEffect(index == ttsManager.currentSentenceIndex ? 1.02 : 1.0)
                                            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: ttsManager.currentSentenceIndex)
                                    }
                                }
                            } else {
                                // 普通阅读模式：连续章节流（当前章/下一章）
                                if !continuousChapters.isEmpty {
                                    LazyVStack(alignment: .leading, spacing: 28) {
                                        ForEach(continuousChapters) { chapterContent in
                                            VStack(alignment: .leading, spacing: preferences.fontSize * 0.8) {
                                                Text(chapterContent.title)
                                                    .font(.title2)
                                                    .fontWeight(.bold)
                                                    .padding(.bottom, 8)
                                                    .id(chapterHeaderID(chapterIndex: chapterContent.chapterIndex))
                                                    .background(
                                                        GeometryReader { titleGeometry in
                                                            Color.clear.preference(
                                                                key: ChapterHeaderMinYPreferenceKey.self,
                                                                value: [chapterContent.chapterIndex: titleGeometry.frame(in: .named("reading-scroll")).minY]
                                                            )
                                                        }
                                                    )
                                                
                                                ForEach(Array(chapterContent.paragraphs.enumerated()), id: \.offset) { index, sentence in
                                                    Text("　　" + sentence.trimmingCharacters(in: .whitespacesAndNewlines))
                                                        .font(.system(size: preferences.fontSize))
                                                        .lineSpacing(preferences.lineSpacing)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                        .padding(.vertical, 6)
                                                        .padding(.horizontal, 8)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 4)
                                                                .fill(
                                                                    chapterContent.chapterIndex == currentChapterIndex && index == lastTTSSentenceIndex
                                                                        ? Color.orange.opacity(0.2)
                                                                        : Color.clear
                                                                )
                                                                .animation(.easeInOut(duration: 0.3), value: lastTTSSentenceIndex)
                                                        )
                                                        .id(paragraphID(chapterIndex: chapterContent.chapterIndex, paragraphIndex: index))
                                                }
                                            }
                                        }
                                        
                                        if isAppendingNextChapter {
                                            HStack {
                                                Spacer()
                                                ProgressView("加载后续章节...")
                                                    .font(.caption)
                                                Spacer()
                                            }
                                            .padding(.vertical, 8)
                                        }
                                    }
                                } else {
                                    // 如果没有句子，显示原始内容
                                    Text(currentContent)
                                        .font(.system(size: preferences.fontSize))
                                        .lineSpacing(preferences.lineSpacing)
                                }
                            }
                        }
                        .padding()
                    }
                    .coordinateSpace(name: "reading-scroll")
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { _ in
                                lastUserScrollInteractionAt = Date()
                            }
                            .onEnded { _ in
                                lastUserScrollInteractionAt = Date()
                                scheduleVisibleChapterEvaluation(
                                    switchLineY: min(scrollGeometry.size.height * 0.22, 150)
                                )
                            }
                    )
                    .onPreferenceChange(ChapterHeaderMinYPreferenceKey.self) { chapterHeaderMinYs in
                        guard !ttsManager.isPlaying else { return }
                        latestChapterHeaderMinYs = chapterHeaderMinYs
                    }
                    .contentShape(Rectangle())  // 使整个区域可点击
                    .onTapGesture {
                        // 点击内容区域切换UI显示（TTS播放或普通阅读模式都支持）
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showUIControls.toggle()
                        }
                    }
                    .onChange(of: ttsManager.currentSentenceIndex) { newIndex in
                        // 自动滚动到当前朗读的段落
                        if ttsManager.isPlaying && !contentSentences.isEmpty {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        // 保存proxy引用，用于后续滚动
                        scrollProxy = proxy
                    }
                }
                
                }
                
                // 底部控制栏（UI隐藏时不显示）
                if showUIControls {
                    if ttsManager.isPlaying && !contentSentences.isEmpty {
                        TTSControlBar(
                            ttsManager: ttsManager,
                            currentChapterIndex: currentChapterIndex,
                            chaptersCount: chapters.count,
                            onPreviousChapter: previousChapter,
                            onNextChapter: nextChapter,
                            onShowChapterList: { showChapterList = true }
                        )
                    } else {
                        NormalControlBar(
                            currentChapterIndex: currentChapterIndex,
                            chaptersCount: chapters.count,
                            onPreviousChapter: previousChapter,
                            onNextChapter: nextChapter,
                            onShowChapterList: { showChapterList = true },
                            onToggleTTS: toggleTTS
                        )
                    }
                }
            }
            
            // 加载指示器
            if isLoading {
                ProgressView("加载中...")
                    .padding()
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(10)
                    .shadow(radius: 10)
            }
        }
        .navigationTitle(book.name ?? "阅读")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(!showUIControls)  // UI隐藏时隐藏导航栏
        .statusBar(hidden: !showUIControls)  // 同时隐藏状态栏
        .sheet(isPresented: $showChapterList) {
            ChapterListView(
                chapters: chapters,
                currentIndex: currentChapterIndex,
                onSelectChapter: { index in
                    currentChapterIndex = index
                    pendingScrollToChapterTopIndex = index
                    pendingScrollToParagraph = nil
                    if ttsManager.isPlaying {
                        shouldRestorePositionAfterTTSStop = false
                    }
                    loadChapterContent()
                    showChapterList = false
                }
            )
        }
        .task {
            await loadChapters()
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") {
                errorMessage = nil
            }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
        .onDisappear {
            saveProgress()
            preloadTask?.cancel()
            appendTask?.cancel()
            chapterSwitchDebounceTask?.cancel()
        }
        .onChange(of: ttsManager.isPlaying) { isPlaying in
            // 当TTS停止播放时，自动显示UI并更新高亮位置
            if !isPlaying {
                showUIControls = true
                if shouldRestorePositionAfterTTSStop {
                    restorePositionAfterTTSStop()
                } else {
                    shouldRestorePositionAfterTTSStop = true
                }
            }
        }
    }
    
    // MARK: - 移除SVG标签
    private func removeHTMLAndSVG(_ text: String) -> String {
        var result = text
        
        // 只移除SVG标签（包括多行SVG）
        let svgPattern = "<svg[^>]*>.*?</svg>"
        if let svgRegex = try? NSRegularExpression(pattern: svgPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = svgRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        
        // 移除img标签
        let imgPattern = "<img[^>]*>"
        if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = imgRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        
        return result
    }
    
    // MARK: - 按原文分段（保持原始分段，优化缩进）
    private func splitIntoParagraphs(_ text: String) -> [String] {
        // 按换行符分割，保持原文分段
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }  // 移除每段的前后空白
            .filter { !$0.isEmpty }  // 过滤空段落
        
        return paragraphs
    }
    
    private func paragraphID(chapterIndex: Int, paragraphIndex: Int) -> String {
        "chapter-\(chapterIndex)-paragraph-\(paragraphIndex)"
    }
    
    private func chapterHeaderID(chapterIndex: Int) -> String {
        "chapter-\(chapterIndex)-header"
    }
    
    private func resetContinuousReading(chapterIndex: Int, paragraphs: [String]) {
        appendTask?.cancel()
        continuousSessionID = UUID()
        autoChapterSwitchDisabledUntil = Date().addingTimeInterval(0.45)
        continuousChapters = [
            ContinuousChapterContent(
                chapterIndex: chapterIndex,
                title: chapters[chapterIndex].title,
                paragraphs: paragraphs
            )
        ]
        continuousChapterIndices = [chapterIndex]
        isAppendingNextChapter = false
        ensureContinuousWindow(centerChapterIndex: chapterIndex)
    }
    
    private func switchToVisibleChapter(_ chapterContent: ContinuousChapterContent) {
        guard currentChapterIndex != chapterContent.chapterIndex else { return }
        
        currentChapterIndex = chapterContent.chapterIndex
        currentContent = chapterContent.paragraphs.joined(separator: "\n")
        contentSentences = chapterContent.paragraphs
        lastTTSSentenceIndex = nil
        autoChapterSwitchDisabledUntil = Date().addingTimeInterval(0.25)
        
        ensureContinuousWindow(centerChapterIndex: chapterContent.chapterIndex)
        saveProgress()
    }
    
    private func scheduleVisibleChapterEvaluation(switchLineY: CGFloat) {
        chapterSwitchDebounceTask?.cancel()
        chapterSwitchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            guard !ttsManager.isPlaying else { return }
            guard Date() >= autoChapterSwitchDisabledUntil else { return }
            let elapsed = Date().timeIntervalSince(lastUserScrollInteractionAt)
            guard elapsed > 0.12 && elapsed < 1.2 else { return }
            updateVisibleChapterByHeaderPosition(
                chapterHeaderMinYs: latestChapterHeaderMinYs,
                switchLineY: switchLineY
            )
        }
    }
    
    private func updateVisibleChapterByHeaderPosition(chapterHeaderMinYs: [Int: CGFloat], switchLineY: CGFloat) {
        guard !chapterHeaderMinYs.isEmpty else { return }
        guard Date() >= autoChapterSwitchDisabledUntil else { return }
        guard let currentHeaderY = chapterHeaderMinYs[currentChapterIndex] else { return }
        
        let passedHeaders = chapterHeaderMinYs
            .filter { $0.value <= switchLineY }
            .sorted { $0.value < $1.value }
        
        guard let targetChapterIndex = passedHeaders.last?.key else { return }
        
        guard targetChapterIndex != currentChapterIndex else { return }
        guard abs(targetChapterIndex - currentChapterIndex) <= 1 else { return }
        
        let switchHysteresis: CGFloat = 22
        if targetChapterIndex > currentChapterIndex {
            guard let targetHeaderY = chapterHeaderMinYs[targetChapterIndex],
                  targetHeaderY <= switchLineY - switchHysteresis else { return }
        } else {
            guard currentHeaderY >= switchLineY + switchHysteresis else { return }
        }
        
        guard let chapterContent = continuousChapters.first(where: { $0.chapterIndex == targetChapterIndex }) else {
            return
        }
        
        switchToVisibleChapter(chapterContent)
    }
    
    private func ensureContinuousWindow(centerChapterIndex: Int) {
        guard centerChapterIndex >= 0, centerChapterIndex < chapters.count else { return }
        
        let loadID = UUID()
        continuousSessionID = loadID
        
        let targetIndices = Set(
            [centerChapterIndex, centerChapterIndex + 1]
                .filter { $0 >= 0 && $0 < chapters.count }
        )
        
        let sessionID = loadID
        let existingMap = Dictionary(uniqueKeysWithValues: continuousChapters.map { ($0.chapterIndex, $0) })
        let missingIndices = targetIndices.sorted().filter { existingMap[$0] == nil }
        
        if missingIndices.isEmpty {
            let limited = targetIndices.sorted().compactMap { existingMap[$0] }
            continuousChapters = limited
            continuousChapterIndices = Set(limited.map(\.chapterIndex))
            preloadAdjacentChapters(around: centerChapterIndex)
            return
        }
        
        isAppendingNextChapter = true
        appendTask?.cancel()
        
        appendTask = Task {
            var mergedMap = existingMap
            
            do {
                for index in missingIndices {
                    try Task.checkCancellation()
                    
                    let content = try await apiService.fetchChapterContent(
                        bookUrl: book.bookUrl ?? "",
                        bookSourceUrl: book.origin,
                        index: index,
                        bookName: book.name
                    )
                    
                    let cleanedContent = removeHTMLAndSVG(content)
                    let paragraphs = splitIntoParagraphs(cleanedContent)
                    
                    mergedMap[index] = ContinuousChapterContent(
                        chapterIndex: index,
                        title: chapters[index].title,
                        paragraphs: paragraphs
                    )
                }
                
                await MainActor.run {
                    guard sessionID == continuousSessionID else { return }
                    
                    let limited = targetIndices.sorted().compactMap { mergedMap[$0] }
                    continuousChapters = limited
                    continuousChapterIndices = Set(limited.map(\.chapterIndex))
                    isAppendingNextChapter = false
                    preloadAdjacentChapters(around: centerChapterIndex)
                }
            } catch {
                await MainActor.run {
                    guard sessionID == continuousSessionID else { return }
                    
                    let limited = targetIndices.sorted().compactMap { mergedMap[$0] }
                    continuousChapters = limited
                    continuousChapterIndices = Set(limited.map(\.chapterIndex))
                    isAppendingNextChapter = false
                }
            }
        }
    }
    
    // MARK: - 加载章节列表
    private func loadChapters() async {
        isLoading = true
        do {
            chapters = try await apiService.fetchChapterList(
                bookUrl: book.bookUrl ?? "",
                bookSourceUrl: book.origin
            )
            currentChapterIndex = resolveInitialChapterIndexByTitle(
                preferredIndex: currentChapterIndex,
                preferredTitle: book.durChapterTitle,
                chapters: chapters
            )
            
            // 加载当前章节内容
            loadChapterContent()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
    
    // MARK: - 加载章节内容
    private func loadChapterContent() {
        guard currentChapterIndex < chapters.count else { return }
        
        if pendingScrollToParagraph == nil && pendingScrollToChapterTopIndex == nil {
            pendingScrollToChapterTopIndex = currentChapterIndex
        }
        
        autoChapterSwitchDisabledUntil = Date().addingTimeInterval(0.55)
        isLoading = true
        Task {
            do {
                let content = try await apiService.fetchChapterContent(
                    bookUrl: book.bookUrl ?? "",
                    bookSourceUrl: book.origin,
                    index: currentChapterIndex,
                    bookName: book.name
                )
                
                await MainActor.run {
                    // 检查内容是否为空
                    if content.isEmpty {
                        currentContent = "章节内容为空\n\n可能的原因：\n1. 书源暂时无法访问\n2. 该章节需要VIP权限\n3. 网络连接问题\n\n请稍后重试或更换书源"
                        errorMessage = "章节内容为空"
                        contentSentences = []
                        continuousSessionID = UUID()
                        continuousChapters = []
                        continuousChapterIndices = []
                    } else {
                        // 移除所有HTML和SVG标签
                        let cleanedContent = removeHTMLAndSVG(content)
                        currentContent = cleanedContent
                        
                        // 分割句子以便TTS高亮
                        let paragraphs = splitIntoParagraphs(cleanedContent)
                        contentSentences = paragraphs
                        resetContinuousReading(chapterIndex: currentChapterIndex, paragraphs: paragraphs)
                        
                        if let progress = preferences.getTTSProgress(bookUrl: book.bookUrl ?? ""),
                           progress.chapterIndex == currentChapterIndex,
                           progress.sentenceIndex < paragraphs.count {
                            lastTTSSentenceIndex = progress.sentenceIndex
                        } else {
                            lastTTSSentenceIndex = nil
                        }
                        
                        if scrollToPendingParagraphIfNeeded(paragraphs: paragraphs) {
                            pendingScrollToChapterTopIndex = nil
                        } else if pendingScrollToChapterTopIndex == currentChapterIndex {
                            scrollToChapterTop(chapterIndex: currentChapterIndex)
                            pendingScrollToChapterTopIndex = nil
                        }
                    }
                    isLoading = false
                    
                    // 如果TTS正在播放同一本书和同一章节，则保持TTS模式，否则停止
                    if ttsManager.isPlaying {
                        let currentBookUrl = book.bookUrl ?? ""
                        if ttsManager.bookUrl != currentBookUrl || ttsManager.currentChapterIndex != currentChapterIndex {
                            shouldRestorePositionAfterTTSStop = false
                            ttsManager.stop()
                        }
                    }
                    
                    // 预加载相邻章节内容到缓存
                    preloadAdjacentChapters(around: currentChapterIndex)
                }
            } catch {
                await MainActor.run {
                    let errorDescription = error.localizedDescription
                    errorMessage = "获取章节失败: \(errorDescription)"
                    
                    // 显示友好的错误信息
                    if errorDescription.contains("json string can not be null or empty") {
                        currentContent = "章节获取失败\n\n该书源可能暂时无法获取正文内容。\n\n建议：\n1. 检查网络连接\n2. 稍后重试\n3. 更换其他书源\n4. 联系管理员检查书源配置"
                    } else {
                        currentContent = "章节加载失败\n\n错误信息: \(errorDescription)\n\n请稍后重试"
                    }
                    continuousSessionID = UUID()
                    continuousChapters = []
                    continuousChapterIndices = []
                    pendingScrollToParagraph = nil
                    isLoading = false
                }
            }
        }
    }
    
    private func scrollToChapterTop(chapterIndex: Int) {
        autoChapterSwitchDisabledUntil = Date().addingTimeInterval(0.7)
        let targetID = chapterHeaderID(chapterIndex: chapterIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollProxy?.scrollTo(targetID, anchor: .top)
            }
        }
    }
    
    private func scrollToParagraph(chapterIndex: Int, paragraphIndex: Int, anchor: UnitPoint = .center) {
        autoChapterSwitchDisabledUntil = Date().addingTimeInterval(0.7)
        let targetID = paragraphID(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollProxy?.scrollTo(targetID, anchor: anchor)
            }
        }
    }
    
    @discardableResult
    private func scrollToPendingParagraphIfNeeded(paragraphs: [String]) -> Bool {
        guard let pending = pendingScrollToParagraph, pending.chapterIndex == currentChapterIndex else {
            return false
        }
        
        guard !paragraphs.isEmpty else {
            pendingScrollToParagraph = nil
            return false
        }
        
        let safeIndex = min(max(pending.paragraphIndex, 0), paragraphs.count - 1)
        lastTTSSentenceIndex = safeIndex
        scrollToParagraph(chapterIndex: currentChapterIndex, paragraphIndex: safeIndex, anchor: .center)
        pendingScrollToParagraph = nil
        return true
    }
    
    private func restorePositionAfterTTSStop() {
        guard let bookUrl = book.bookUrl else { return }
        
        chapterSwitchDebounceTask?.cancel()
        autoChapterSwitchDisabledUntil = Date().addingTimeInterval(1.0)
        
        let savedProgress = preferences.getTTSProgress(bookUrl: bookUrl)
        let targetChapterIndex = savedProgress?.chapterIndex ?? ttsManager.currentChapterIndex
        guard targetChapterIndex >= 0, targetChapterIndex < chapters.count else { return }
        
        let targetSentenceIndex: Int
        if let saved = savedProgress, saved.chapterIndex == targetChapterIndex {
            targetSentenceIndex = max(saved.sentenceIndex, 0)
        } else {
            targetSentenceIndex = max(ttsManager.currentSentenceIndex - 1, 0)
        }
        
        pendingScrollToChapterTopIndex = nil
        pendingScrollToParagraph = (targetChapterIndex, targetSentenceIndex)
        
        if targetChapterIndex == currentChapterIndex {
            _ = scrollToPendingParagraphIfNeeded(paragraphs: contentSentences)
        } else {
            currentChapterIndex = targetChapterIndex
            loadChapterContent()
        }
    }
    
    // MARK: - 上一章
    private func previousChapter() {
        guard currentChapterIndex > 0 else { return }
        currentChapterIndex -= 1
        pendingScrollToChapterTopIndex = currentChapterIndex
        pendingScrollToParagraph = nil
        if ttsManager.isPlaying {
            shouldRestorePositionAfterTTSStop = false
        }
        loadChapterContent()
        saveProgress()
    }
    
    // MARK: - 下一章
    private func nextChapter() {
        guard currentChapterIndex < chapters.count - 1 else { return }
        currentChapterIndex += 1
        pendingScrollToChapterTopIndex = currentChapterIndex
        pendingScrollToParagraph = nil
        if ttsManager.isPlaying {
            shouldRestorePositionAfterTTSStop = false
        }
        loadChapterContent()
        saveProgress()
    }
    
    // MARK: - 切换听书
    private func toggleTTS() {
        if ttsManager.isPlaying {
            if ttsManager.isPaused {
                ttsManager.resume()
            } else {
                ttsManager.pause()
            }
        } else {
            startTTS()
        }
    }
    
    // MARK: - 开始听书
    private func startTTS() {
        // TTS开始时显示UI，让用户看到控制面板
        showUIControls = true
        
        ttsManager.startReading(
            text: currentContent,
            chapters: chapters,
            currentIndex: currentChapterIndex,
            bookUrl: book.bookUrl ?? "",
            bookSourceUrl: book.origin,
            bookTitle: book.name ?? "未知书名",
            coverUrl: book.displayCoverUrl
        ) { newIndex in
            currentChapterIndex = newIndex
            loadChapterContent()
            saveProgress()
        }
    }
    
    // MARK: - 预加载后续章节（下一章）
    private func preloadAdjacentChapters(around chapterIndex: Int) {
        let indices = [chapterIndex + 1].filter { $0 >= 0 && $0 < chapters.count }
        guard !indices.isEmpty else { return }
        
        preloadTask?.cancel()
        preloadTask = Task {
            await apiService.preloadChapterContents(
                bookUrl: book.bookUrl ?? "",
                bookSourceUrl: book.origin,
                indices: indices,
                bookName: book.name
            )
        }
    }
    
    // MARK: - 保存进度
    private func saveProgress() {
        guard let bookUrl = book.bookUrl else { return }
        
        Task {
            do {
                let title = currentChapterIndex < chapters.count ? chapters[currentChapterIndex].title : nil
                try await apiService.saveBookProgress(
                    bookUrl: bookUrl,
                    index: currentChapterIndex,
                    pos: 0,
                    title: title
                )
            } catch {
                print("保存进度失败: \(error)")
            }
        }
    }
    
    private func resolveInitialChapterIndexByTitle(preferredIndex: Int, preferredTitle: String?, chapters: [BookChapter]) -> Int {
        guard !chapters.isEmpty else { return 0 }
        let clampedIndex = min(max(preferredIndex, 0), chapters.count - 1)
        
        guard let title = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return clampedIndex
        }
        
        func normalize(_ value: String) -> String {
            value.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let normalizedTitle = normalize(title)
        
        if normalize(chapters[clampedIndex].title) == normalizedTitle {
            return clampedIndex
        }
        
        if clampedIndex + 1 < chapters.count, normalize(chapters[clampedIndex + 1].title) == normalizedTitle {
            return clampedIndex + 1
        }
        
        if clampedIndex > 0, normalize(chapters[clampedIndex - 1].title) == normalizedTitle {
            return clampedIndex - 1
        }
        
        if let exact = chapters.firstIndex(where: { normalize($0.title) == normalizedTitle }) {
            return exact
        }
        
        if let fuzzy = chapters.firstIndex(where: {
            let t = normalize($0.title)
            return t.contains(normalizedTitle) || normalizedTitle.contains(t)
        }) {
            return fuzzy
        }
        
        return clampedIndex
    }
}

// MARK: - 章节列表视图
struct ChapterListView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let onSelectChapter: (Int) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var isReversed = false
    
    var displayedChapters: [(offset: Int, element: BookChapter)] {
        let enumerated = Array(chapters.enumerated())
        return isReversed ? Array(enumerated.reversed()) : enumerated
    }
    
    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
            List {
                    ForEach(displayedChapters, id: \.element.id) { item in
                    Button(action: {
                                onSelectChapter(item.offset)
                        dismiss()
                    }) {
                        HStack {
                                Text(item.element.title)
                                    .foregroundColor(item.offset == currentIndex ? .blue : .primary)
                                    .fontWeight(item.offset == currentIndex ? .semibold : .regular)
                            Spacer()
                                if item.offset == currentIndex {
                                    Image(systemName: "book.fill")
                                    .foregroundColor(.blue)
                                        .font(.caption)
                                }
                            }
                        }
                        .id(item.offset) // 为每个章节设置唯一ID
                        .listRowBackground(
                            item.offset == currentIndex ? Color.blue.opacity(0.1) : Color.clear
                        )
                    }
                }
                .navigationTitle("目录（共\(chapters.count)章）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            withAnimation {
                                isReversed.toggle()
                            }
                            // 切换顺序后重新聚焦
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    proxy.scrollTo(currentIndex, anchor: .center)
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: isReversed ? "arrow.up" : "arrow.down")
                                Text(isReversed ? "倒序" : "正序")
                            }
                            .font(.caption)
                        }
                    }
                    
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                        }
                    }
                }
                .onAppear {
                    // 延迟滚动以确保列表已完全渲染
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            proxy.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 富文本显示视图（使用SwiftUI原生Text）
struct RichTextView: View {
    let sentences: [String]  // 句子列表（与TTS使用相同的分句）
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let highlightIndex: Int?  // 要高亮的句子索引
    let scrollProxy: ScrollViewProxy?  // 用于滚动
    
    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.8) {
            ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                Text("　　" + sentence.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        // 如果是上次TTS播放的段落，添加高亮
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == highlightIndex ? Color.orange.opacity(0.2) : Color.clear)
                            .animation(.easeInOut(duration: 0.3), value: highlightIndex)
                    )
                    .id(index)  // 用于滚动定位
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 如果有高亮段落，自动滚动到该位置
            if let highlightIndex = highlightIndex, let scrollProxy = scrollProxy {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo(highlightIndex, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - TTS控制栏
struct TTSControlBar: View {
    @ObservedObject var ttsManager: TTSManager
    let currentChapterIndex: Int
    let chaptersCount: Int
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onShowChapterList: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // 第一行：段落导航
            HStack(spacing: 20) {
                Button(action: { ttsManager.previousSentence() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.backward.circle.fill").font(.title)
                        Text("上一段").font(.caption)
                    }
                    .foregroundColor(ttsManager.currentSentenceIndex <= 0 ? .gray : .blue)
                }
                .disabled(ttsManager.currentSentenceIndex <= 0)
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text("段落进度").font(.caption).foregroundColor(.secondary)
                    Text("\(ttsManager.currentSentenceIndex + 1) / \(ttsManager.totalSentences)")
                        .font(.title2).fontWeight(.semibold)
                }
                
                Spacer()
                
                Button(action: { ttsManager.nextSentence() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.forward.circle.fill").font(.title)
                        Text("下一段").font(.caption)
                    }
                    .foregroundColor(ttsManager.currentSentenceIndex >= ttsManager.totalSentences - 1 ? .gray : .blue)
                }
                .disabled(ttsManager.currentSentenceIndex >= ttsManager.totalSentences - 1)
            }
            .padding(.horizontal, 20).padding(.top, 12)
            
            Divider().padding(.horizontal, 20)
            
            // 第二行：章节导航和控制
            HStack(spacing: 25) {
                Button(action: onPreviousChapter) {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.title3)
                        Text("上一章").font(.caption2)
                    }
                }
                .disabled(currentChapterIndex <= 0)
                
                Button(action: onShowChapterList) {
                    VStack(spacing: 2) {
                        Image(systemName: "list.bullet").font(.title3)
                        Text("目录").font(.caption2)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    if ttsManager.isPaused {
                        ttsManager.resume()
                    } else {
                        ttsManager.pause()
                    }
                }) {
                    VStack(spacing: 2) {
                        Image(systemName: ttsManager.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 36)).foregroundColor(.blue)
                        Text(ttsManager.isPaused ? "播放" : "暂停").font(.caption2)
                    }
                }
                
                Spacer()
                
                Button(action: { ttsManager.stop() }) {
                    VStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundColor(.red)
                        Text("退出").font(.caption2).foregroundColor(.red)
                    }
                }
                
                Button(action: onNextChapter) {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.right").font(.title3)
                        Text("下一章").font(.caption2)
                    }
                }
                .disabled(currentChapterIndex >= chaptersCount - 1)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .background(Color(UIColor.systemBackground))
        .shadow(color: Color.black.opacity(0.1), radius: 5, y: -2)
    }
}

// MARK: - 普通控制栏
struct NormalControlBar: View {
    let currentChapterIndex: Int
    let chaptersCount: Int
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onShowChapterList: () -> Void
    let onToggleTTS: () -> Void
    
    var body: some View {
        HStack(spacing: 30) {
            Button(action: onPreviousChapter) {
                VStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.title2)
                    Text("上一章").font(.caption2)
                }
            }
            .disabled(currentChapterIndex <= 0)
            
            Button(action: onShowChapterList) {
                VStack(spacing: 4) {
                    Image(systemName: "list.bullet").font(.title2)
                    Text("目录").font(.caption2)
                }
            }
            
            Spacer()
            
            Button(action: onToggleTTS) {
                VStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.circle.fill")
                        .font(.system(size: 32)).foregroundColor(.blue)
                    Text("听书").font(.caption2).foregroundColor(.blue)
                }
            }
            
            Spacer()
            
            Button(action: { /* TODO: 字体设置 */ }) {
                VStack(spacing: 4) {
                    Image(systemName: "textformat.size").font(.title2)
                    Text("字体").font(.caption2)
                }
            }
            
            Button(action: onNextChapter) {
                VStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.title2)
                    Text("下一章").font(.caption2)
                }
            }
            .disabled(currentChapterIndex >= chaptersCount - 1)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color(UIColor.systemBackground))
        .shadow(color: Color.black.opacity(0.1), radius: 5, y: -2)
    }
}
