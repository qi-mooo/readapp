import SwiftUI

struct BookListView: View {
    @EnvironmentObject var apiService: APIService
    @StateObject private var preferences = UserPreferences.shared
    @State private var isRefreshing = false
    @State private var searchText = ""
    @State private var isReversed = false
    @State private var showingActionSheet = false  // 显示操作菜单
    
    // 过滤和排序后的书籍列表
    var filteredAndSortedBooks: [Book] {
        let filtered: [Book]
        if searchText.isEmpty {
            filtered = apiService.books
        } else {
            filtered = apiService.books.filter { book in
                (book.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                (book.author?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        
        // 根据设置决定排序方式
        let sorted: [Book]
        if preferences.bookshelfSortByRecent {
            // 按最后阅读时间排序（使用后端提供的durChapterTime）
            sorted = filtered.sorted { book1, book2 in
                let time1 = book1.durChapterTime ?? 0
                let time2 = book2.durChapterTime ?? 0
                
                // 如果都没有阅读记录，保持原顺序
                if time1 == 0 && time2 == 0 {
                    return false
                }
                // 如果只有一个有阅读记录，有记录的排前面
                if time1 == 0 {
                    return false
                }
                if time2 == 0 {
                    return true
                }
                // 都有阅读记录时，按时间降序（最近阅读的在前）
                return time1 > time2
            }
        } else {
            // 按后端顺序（加入书架时间）
            sorted = filtered
        }
        
        // 支持倒序
        return isReversed ? sorted.reversed() : sorted
    }
    
    var body: some View {
        List {
            ForEach(filteredAndSortedBooks) { book in
                NavigationLink(destination: ReadingView(book: book)) {
                    BookRow(book: book)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        showingActionSheet = true
                    } label: {
                        Label("清除所有远程缓存", systemImage: "trash")
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isReversed)
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "搜索书名或作者")
        .refreshable {
            await loadBooks()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Button(action: {
                    withAnimation {
                        isReversed.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isReversed ? "arrow.up" : "arrow.down")
                        Text(isReversed ? "倒序" : "正序")
                    }
                    .font(.caption)
                }
            }
            
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gearshape")
                }
            }
        }
        .task {
            if apiService.books.isEmpty {
                await loadBooks()
            }
        }
        .overlay {
            if isRefreshing {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("加载中...")
                        .foregroundColor(.secondary)
                }
            } else if filteredAndSortedBooks.isEmpty && !apiService.books.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("未找到匹配的书籍")
                        .foregroundColor(.secondary)
                }
            }
        }
        .alert("错误", isPresented: .constant(apiService.errorMessage != nil)) {
            Button("确定") {
                apiService.errorMessage = nil
            }
        } message: {
            if let error = apiService.errorMessage {
                Text(error)
            }
        }
        .alert("清除所有远程缓存", isPresented: $showingActionSheet) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                clearAllRemoteCache()
            }
        } message: {
            Text("确定要清除所有书籍的远程缓存吗？\n\n这将清除服务器上缓存的所有章节内容。")
        }
    }
    
    private func loadBooks() async {
        isRefreshing = true
        do {
            try await apiService.fetchBookshelf()
        } catch {
            apiService.errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }
    
    private func clearAllRemoteCache() {
        Task {
            do {
                try await apiService.clearAllRemoteCache()
                // 清除成功后刷新书架
                await loadBooks()
            } catch {
                apiService.errorMessage = "清除缓存失败: \(error.localizedDescription)"
            }
        }
    }
}

struct BookRow: View {
    let book: Book
    
    var body: some View {
        HStack(spacing: 12) {
            // 封面图
            AsyncImage(url: URL(string: book.displayCoverUrl ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "book.fill")
                            .foregroundColor(.gray)
                    )
            }
            .frame(width: 60, height: 80)
            .cornerRadius(4)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name ?? "未知书名")
                    .font(.headline)
                    .lineLimit(1)
                
                Text(book.author ?? "未知作者")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                if let latestChapter = book.latestChapterTitle {
                    Text("最新: \(latestChapter)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                HStack {
                    if let durChapter = book.durChapterTitle {
                        Text("读至: \(durChapter)")
                            .font(.caption2)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    if let total = book.totalChapterNum {
                        Text("\(total)章")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

