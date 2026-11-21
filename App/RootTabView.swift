import SwiftUI
import UniformTypeIdentifiers

private struct BookshelfCoverFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private final class BookshelfCoverTransition: ObservableObject {
    @Published var book: Book?
    @Published var sourceFrame: CGRect?
    @Published var progress = 0.0
    @Published var revealProgress = 0.0

    func prepare(book: Book, sourceFrame: CGRect) {
        self.book = book
        self.sourceFrame = sourceFrame
        progress = 0
        revealProgress = 0
    }

    func reset() {
        book = nil
        sourceFrame = nil
        progress = 0
        revealProgress = 0
    }
}

private struct BookshelfCoverTransitionOverlay: View {
    @ObservedObject var transition: BookshelfCoverTransition
    private func eased(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        // Smooth acceleration and deceleration for the four independently
        // interpolated edges of the expanding book surface.
        return t * t * (3 - 2 * t)
    }

    private func interpolate(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }

    var body: some View {
        GeometryReader { geometry in
            if let book = transition.book, let sourceFrame = transition.sourceFrame {
                let globalFrame = geometry.frame(in: .global)
                let startRect = sourceFrame.offsetBy(dx: -globalFrame.minX, dy: -globalFrame.minY)
                let endRect = CGRect(origin: .zero, size: geometry.size)
                let rawProgress = CGFloat(transition.progress)
                let boundsProgress = eased(rawProgress)

                // Each edge travels to its own screen boundary. This is not a
                // center-scale animation, so books starting at either side of
                // the shelf still finish flush with all four screen edges.
                let expandedMinX = interpolate(startRect.minX, endRect.minX, boundsProgress)
                let expandedMinY = interpolate(startRect.minY, endRect.minY, boundsProgress)
                let expandedMaxX = interpolate(startRect.maxX, endRect.maxX, boundsProgress)
                let expandedMaxY = interpolate(startRect.maxY, endRect.maxY, boundsProgress)
                let expandedRect = CGRect(
                    x: expandedMinX,
                    y: expandedMinY,
                    width: max(1, expandedMaxX - expandedMinX),
                    height: max(1, expandedMaxY - expandedMinY)
                )

                let coverRotationProgress = eased(max(0, (rawProgress - 0.04) / 0.96))
                let coverAngle = -118 * coverRotationProgress
                let coverFade = 1 - min(1, max(0, (rawProgress - 0.88) / 0.12))

                // The reader is now laid out inside this same expanding page
                // rectangle below. Keep this overlay limited to the physical
                // cover, so the bookshelf remains visible outside the book.
                ZStack {
                    // Diagnostic back face: an opaque inner-cover surface.
                    // It is shown only after the physical cover passes 90°,
                    // preventing the bookshelf/reader from showing through it.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(red: 0.88, green: 0.84, blue: 0.75))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        }
                        .rotation3DEffect(
                            .degrees(180),
                            axis: (x: 0, y: 1, z: 0)
                        )
                        .opacity(coverAngle < -90 ? 1 : 0)

                    BookCoverArtwork(
                        title: book.name,
                        author: book.author,
                        remoteURL: book.coverUrl,
                        width: max(1, expandedRect.width),
                        height: max(1, expandedRect.height)
                    )
                    .opacity(coverAngle < -90 ? 0 : 1)
                }
                .frame(width: max(1, expandedRect.width), height: max(1, expandedRect.height))
                .rotation3DEffect(
                    .degrees(coverAngle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .leading,
                    perspective: 0.62
                )
                .shadow(
                    color: .black.opacity(0.22 * coverFade),
                    radius: 18 * coverFade,
                    x: 0,
                    y: 10 * coverFade
                )
                .opacity(coverFade)
                .frame(width: max(1, expandedRect.width), height: max(1, expandedRect.height), alignment: .leading)
                .position(x: expandedRect.midX, y: expandedRect.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(100)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct RootTabView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @StateObject private var bookshelfCoverTransition = BookshelfCoverTransition()
    private enum Tab: Hashable { case bookshelf, explore, statistics, my }
    @State private var selection: Tab
    @State private var showsDemoReader = false
    @State private var didOpenDemoReader = false
    @State private var sourceImportIsPresented = false
    @State private var displayedSourceNotice: SourceLibraryModel.Notice?
    @AppStorage("themeMode") private var themeMode = "0"

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let requested = arguments.firstIndex(of: "-uiDemoTab")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let initial: Tab = switch requested {
        case "explore": .explore
        case "statistics": .statistics
        case "settings": .my
        default:
            switch UserDefaults.standard.string(forKey: "defaultHomePage") {
            case "explore": .explore
            case "statistics": .statistics
            case "settings": .my
            default: .bookshelf
            }
        }
        _selection = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selection) {
            ReadingNavigationStack {
                Group {
                    if ProcessInfo.processInfo.arguments.contains("-uiDemoSourceSwitch") {
                        SourceSwitchView(
                            book: DemoContent.books[0],
                            sources: DemoContent.sources,
                            demoCandidates: DemoContent.sourceSwitchCandidates
                        ) { _, _ in true }
                    } else if ProcessInfo.processInfo.arguments.contains("-uiDemoBookDetail") {
                        BookDetailView(
                            demoBook: DemoContent.books[0],
                            source: DemoContent.sources[0],
                            chapters: DemoContent.readerChapters
                        )
                    } else if requestedDemoPage == "search" {
                        SearchView(initialKeyword: automationSearchKeyword)
                    } else if requestedDemoPage == "sources" {
                        SourceManagementView()
                    } else if requestedDemoPage == "rss" {
                        RSSHomeView()
                    } else if requestedDemoPage == "rss-photo" {
                        RSSPhotoView(value: "data:image/png;base64,", source: RssSource(sourceUrl: "https://appearance.invalid", sourceName: "图片外观检查"))
                    } else {
                        BookshelfView(coverTransition: bookshelfCoverTransition)
                    }
                }
                .readingNavigationDestination(isPresented: $showsDemoReader) {
                    ReaderView(
                        demoBook: DemoContent.books[0],
                        chapters: DemoContent.readerChapters,
                        initialIndex: 0,
                        content: DemoContent.readerText
                    )
                }
                .task {
                    guard !didOpenDemoReader else { return }
                    didOpenDemoReader = true
                    showsDemoReader = ProcessInfo.processInfo.arguments.contains("-uiDemoReader")
                }
            }
                .tabItem { Label("书架", systemImage: selection == .bookshelf ? "book.fill" : "book").environment(\.symbolVariants, .none) }
                .tag(Tab.bookshelf)

            ReadingNavigationStack { ExploreView() }
                .tabItem { Label("发现", systemImage: "safari").environment(\.symbolVariants, .none) }
                .tag(Tab.explore)

            ReadingNavigationStack { ReadingStatisticsView() }
                .tabItem { Label("统计", systemImage: selection == .statistics ? "chart.bar.fill" : "chart.bar").environment(\.symbolVariants, .none) }
                .tag(Tab.statistics)

            ReadingNavigationStack {
                if ProcessInfo.processInfo.arguments.contains("-uiDemoRules") {
                    ReplaceRuleManagementView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoHistory") {
                    ReadingHistoryView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoFiles") {
                    FileManagementView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoOtherSettings") {
                    OtherSettingsView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoAbout") {
                    AboutView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoLogs") {
                    DiagnosticLogView()
                } else {
                    SettingsView()
                }
            }
                .tabItem { Label("我的", systemImage: "person").environment(\.symbolVariants, .none) }
                .tag(Tab.my)
        }
        .readingTabBarBackground()
        .preferredColorScheme(themeMode == "2" ? .dark : (themeMode == "1" || themeMode == "3" ? .light : nil))
        .transaction { transaction in
            if themeMode == "3" { transaction.animation = nil }
        }
        .sheet(item: $sourceLibrary.pendingImport, onDismiss: {
            sourceImportIsPresented = false
            displayedSourceNotice = sourceLibrary.notice
        }) { pending in
            SourceImportReviewView(pending: pending)
                .environmentObject(sourceLibrary)
                .onAppear { sourceImportIsPresented = true }
        }
        .onChange(of: sourceLibrary.notice?.id) { _ in
            if !sourceImportIsPresented { displayedSourceNotice = sourceLibrary.notice }
        }
        .alert(item: $displayedSourceNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.detail),
                dismissButton: .default(Text("好")) { sourceLibrary.notice = nil }
            )
        }
        .tint(ReadingTheme.accent)
        .toggleStyle(SwitchToggleStyle(tint: ReadingTheme.toggleTint))
        // Keep the transition above the entire TabView, including its tab bar.
        // An overlay attached to an individual tab's NavigationStack is still
        // underneath the system-managed tab bar.
        .overlay {
            BookshelfCoverTransitionOverlay(transition: bookshelfCoverTransition)
                .zIndex(1_000)
        }
    }

    private var requestedDemoPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiDemoTab"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private var automationSearchKeyword: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiAutomationSearch"),
              arguments.indices.contains(index + 1) else { return "" }
        return arguments[index + 1]
    }
}

private struct BookshelfView: View {
    @ObservedObject var coverTransition: BookshelfCoverTransition
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @State private var showsLocalImporter = false
    @State private var pendingLocalFiles: [LocalBookImportFile] = []
    @State private var selectedGroupID = BookGroup.idAll
    @State private var showsGroupManager = false
    @State private var showsBookOrder = false
    @State private var openingBook: Book?
    @State private var openingSource: BookSource?
    @State private var openingPreparation: BookshelfReadViewModel?
    @State private var openingCoverID: String?
    @State private var openingCoverFrame: CGRect?
    @State private var coverFrames: [String: CGRect] = [:]
    @State private var isAnimatingCover = false
    @State private var isOpeningDestination = false
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid3"
    @AppStorage("bookshelfSort") private var bookshelfSort = 0

    private var selectedGroup: BookGroup {
        library.visibleGroups.first(where: { $0.id == selectedGroupID })
            ?? library.visibleGroups.first
            ?? BookGroup(groupId: BookGroup.idAll, groupName: "全部")
    }

    private var displayedBooks: [Book] { library.books(in: selectedGroup, defaultSort: bookshelfSort) }

    private func expandedReaderRect(in geometry: GeometryProxy) -> CGRect {
        let containerFrame = geometry.frame(in: .global)
        let screenSize = UIScreen.main.bounds.size
        let endRect = CGRect(
            x: -containerFrame.minX,
            y: -containerFrame.minY,
            width: screenSize.width,
            height: screenSize.height
        )

        guard let sourceFrame = openingCoverFrame else { return endRect }
        let startRect = sourceFrame.offsetBy(dx: -containerFrame.minX, dy: -containerFrame.minY)
        let raw = CGFloat(coverTransition.progress)
        let progress = raw * raw * (3 - 2 * raw)
        let minX = startRect.minX + (endRect.minX - startRect.minX) * progress
        let minY = startRect.minY + (endRect.minY - startRect.minY) * progress
        let maxX = startRect.maxX + (endRect.maxX - startRect.maxX) * progress
        let maxY = startRect.maxY + (endRect.maxY - startRect.maxY) * progress
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private var recentBook: Book? {
        displayedBooks.filter(BookReadingPresentation.hasStarted)
            .sorted { $0.durChapterTime > $1.durChapterTime }
            .first
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                    ReadingPageHeader(title: "书架", subtitle: "阅读，让时间有了形状") {
                        NavigationLink { SearchView() } label: {
                            ReadingToolbarIcon(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("搜索")
                        bookshelfMenu
                    }
                    if !library.books.isEmpty && library.visibleGroups.count > 1 {
                        bookshelfGroups.padding(.bottom, 24)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        switch library.loadState {
                        case .notStarted, .loading:
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("正在准备书架…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, min(80, max(24, geometry.size.height * 0.075)))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("正在准备书架")

                        case .failed:
                            VStack(spacing: 14) {
                                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text("书架加载失败")
                                    .font(.headline)
                                Text("暂时无法读取书架数据，请检查后重试。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button {
                                    library.clearError()
                                    Task { await library.load() }
                                } label: {
                                    Text("重新加载")
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 22)
                                        .padding(.vertical, 10)
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("bookshelf.retryLoad")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, min(64, max(24, geometry.size.height * 0.06)))

                        case .loaded:
                            Group {
                                if displayedBooks.isEmpty {
                                    EmptyBookshelfHero { showsLocalImporter = true }
                                        .padding(.top, min(80, max(24, geometry.size.height * 0.075)))
                                } else {
                                    if let book = recentBook {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text("继续阅读")
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.secondary)
                                            Button {
                                                beginOpening(
                                                    book,
                                                    source: sources.sources.first { $0.bookSourceUrl == book.origin },
                                                    animationID: "\(book.bookUrl)::continue"
                                                )
                                            } label: {
                                                ContinueReadingCard(
                                                    book: book,
                                                    isAnimatingCover: isAnimatingCover && openingCoverID == "\(book.bookUrl)::continue"
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("继续阅读，\(book.name)，\(BookReadingPresentation.position(book))")
                                            .accessibilityIdentifier("bookshelf.continue")
                                        }
                                        .padding(.bottom, 30)
                                    }
                                    bookshelfSummary
                                    if bookshelfLayout.hasPrefix("grid") {
                                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
                                            ForEach(displayedBooks) { book in
                                                BookshelfBookLink(
                                                    book: book,
                                                    compact: false,
                                                    grid: true,
                                                    isAnimatingCover: isAnimatingCover && openingCoverID == book.bookUrl
                                                ) { beginOpening(book, source: sources.sources.first { $0.bookSourceUrl == book.origin }, animationID: book.bookUrl) }
                                            }
                                        }
                                    } else {
                                        ForEach(displayedBooks) { book in
                                            BookshelfBookLink(
                                                book: book,
                                                compact: bookshelfLayout == "compact",
                                                grid: false,
                                                isAnimatingCover: isAnimatingCover && openingCoverID == book.bookUrl
                                            ) { beginOpening(book, source: sources.sources.first { $0.bookSourceUrl == book.origin }, animationID: book.bookUrl) }
                                            if book.id != displayedBooks.last?.id {
                                                Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                                                    .padding(.leading, bookshelfLayout == "compact" ? 54 : 66)
                                            }
                                        }
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .animation(.easeOut(duration: 0.3), value: library.loadState)
                }
                    .frame(maxWidth: .infinity)
                }

                // Present the reader above the bookshelf content instead of
                // pushing it through the parent NavigationStack. The existing
                // cover-transition overlay remains above this reader layer.
                if isOpeningDestination, let book = openingBook {
                    let readerRect = expandedReaderRect(in: geometry)
                    BookshelfBookDestination(
                        book: book,
                        source: openingSource,
                        preparation: openingPreparation,
                        isOpeningTransition: openingCoverFrame != nil && coverTransition.revealProgress < 0.999,
                        openingProgress: coverTransition.revealProgress,
                        openingTopInset: max(0, -readerRect.minY),
                        onClose: closeReader
                    )
                    .frame(width: readerRect.width, height: readerRect.height)
                    // Diagnostic only: paint the actual animated page rectangle
                    // with a fully opaque, unmistakable color while it is opening.
                    // This isolates the destination surface from its child views.
                    .overlay {
                        if isOpeningTransition {
                            Rectangle().fill(Color(red: 0.0, green: 0.85, blue: 0.95))
                        }
                    }
                    .clipShape(Rectangle())
                    .position(x: readerRect.midX, y: readerRect.midY)
                    .allowsHitTesting(openingCoverFrame == nil || coverTransition.progress >= 0.999)
                    .zIndex(50)
                }
            }
            .coordinateSpace(name: "bookshelf")
            .onPreferenceChange(BookshelfCoverFramePreferenceKey.self) { frames in
                coverFrames = frames
            }
        }
        .background(ReadingTheme.canvas)
        .navigationBarHidden(true)
        .onChange(of: isOpeningDestination) { isActive in
            if !isActive {
                openingBook = nil
                openingSource = nil
                openingPreparation = nil
                openingCoverID = nil
                openingCoverFrame = nil
                isAnimatingCover = false
                coverTransition.reset()
            }
        }
        .refreshable {
            guard selectedGroup.enableRefresh else { return }
            await library.checkForUpdates(sources: sources.sources, group: selectedGroup)
        }
        .readingLocalBookFileImporter(isPresented: $showsLocalImporter) { files in
            pendingLocalFiles = files
        } onError: { error in
            library.reportError(error)
        }
        .sheet(isPresented: Binding(
            get: { !pendingLocalFiles.isEmpty },
            set: { if !$0 { pendingLocalFiles = [] } }
        )) {
            LocalBookImportReviewView(files: pendingLocalFiles) {
                pendingLocalFiles = []
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showsGroupManager) {
            BookGroupManagerView()
                .environmentObject(library)
        }
        .sheet(isPresented: $showsBookOrder) {
            BookOrderView(groupID: selectedGroup.id).environmentObject(library)
        }
        .alert("书架操作失败", isPresented: Binding(
            get: { library.errorMessage != nil && library.loadState != .failed },
            set: { if !$0 { library.clearError() } }
        )) {
            Button("好") { library.clearError() }
        } message: {
            Text(library.errorMessage ?? "未知错误")
        }
        .alert("书架更新", isPresented: Binding(
            get: { library.updateMessage != nil },
            set: { if !$0 { library.clearUpdateMessage() } }
        )) {
            Button("好") { library.clearUpdateMessage() }
        } message: {
            Text(library.updateMessage ?? "")
        }
    }

    private func closeReader() {
        isOpeningDestination = false
    }

    private func beginOpening(_ book: Book, source: BookSource?, animationID: String) {
        guard openingBook == nil, !isOpeningDestination else { return }

        openingBook = book
        openingSource = source
        openingCoverID = animationID
        openingCoverFrame = coverFrames[animationID]

        let preparation = BookshelfReadViewModel()
        openingPreparation = preparation

        let hasCoverTransition = openingCoverFrame != nil
        if let sourceFrame = openingCoverFrame {
            coverTransition.prepare(book: book, sourceFrame: sourceFrame)
        }

        // Present the destination immediately. Catalog parsing and chapter
        // loading run independently and are never allowed to delay the cover.
        isOpeningDestination = true

        Task { @MainActor in
            await preparation.load(book: book, source: source) { report in
                await library.commitPreparedUpdate(requestedBook: book, report: report)
            }

            let isLocalEPUB = book.origin == "local"
                && URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub"
            if !isLocalEPUB, let readerModel = preparation.makeReaderModel(source: source) {
                await readerModel.load(
                    rules: readerModel.usesReplaceRules ? replaceRules.rules : [],
                    prefetchNextChapter: false
                )
            }
        }

        guard hasCoverTransition else { return }
        Task { @MainActor in
            // Give SwiftUI one frame to mount the reader-sized background.
            // The actual reader content remains hidden until the 70% point.
            await Task.yield()
            guard isOpeningDestination, openingBook?.bookUrl == book.bookUrl else { return }
            isAnimatingCover = true
            withAnimation(.timingCurve(0.30, 0.30, 0.18, 1.0, duration: 1.15)) {
                coverTransition.progress = 1
            }
            // This independent linear clock represents elapsed animation time,
            // so the 70% content-reveal threshold is exactly 70% of 1.15 seconds
            // rather than 70% of the eased geometry progress.
            withAnimation(.linear(duration: 1.15)) {
                coverTransition.revealProgress = 1
            }
        }
    }

    private var bookshelfSummary: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedGroupID == BookGroup.idAll ? "全部书籍" : selectedGroup.groupName)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("\(displayedBooks.count)本")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 0) {
                Button { bookshelfLayout = "grid3" } label: {
                    Image(systemName: "square.grid.2x2.fill")
                        .foregroundStyle(bookshelfLayout.hasPrefix("grid") ? ReadingTheme.accent : .secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("网格布局")
                .accessibilityAddTraits(bookshelfLayout.hasPrefix("grid") ? .isSelected : [])
                Button { bookshelfLayout = "list" } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(bookshelfLayout.hasPrefix("grid") ? .secondary : ReadingTheme.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("列表布局")
                .accessibilityAddTraits(bookshelfLayout.hasPrefix("grid") ? [] : .isSelected)
            }
            .font(.system(size: 18, weight: .medium))
            .buttonStyle(.plain)
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var bookshelfMenu: some View {
        if library.isCheckingUpdates {
            ProgressView().controlSize(.small).frame(width: 44, height: 44)
        } else {
            Menu {
                Button("更新目录", systemImage: "arrow.clockwise") {
                    Task { await library.checkForUpdates(sources: sources.sources, group: selectedGroup) }
                }
                Button("本地书", systemImage: "plus") { showsLocalImporter = true }
                Button("书架分组", systemImage: "rectangle.3.group") { showsGroupManager = true }
                Menu("本分组设置", systemImage: "slider.horizontal.3") {
                    Picker("书籍排序", selection: Binding(
                        get: { selectedGroup.bookSort },
                        set: { sort in Task { await library.setGroupSort(selectedGroup, sort: sort) } }
                    )) {
                        Text("跟随默认排序").tag(-1)
                        ForEach(BookshelfSort.allCases) { sort in Text(sort.title).tag(sort.rawValue) }
                    }
                    Button("调整书籍顺序") { showsBookOrder = true }
                        .disabled(displayedBooks.count < 2)
                    Toggle("允许下拉更新", isOn: Binding(
                        get: { selectedGroup.enableRefresh },
                        set: { enabled in Task { await library.setGroupRefreshEnabled(selectedGroup, enabled: enabled) } }
                    ))
                    Toggle("仅更新已读至最新章的书", isOn: Binding(
                        get: { selectedGroup.onlyUpdateRead },
                        set: { enabled in Task { await library.setGroupOnlyUpdateRead(selectedGroup, enabled: enabled) } }
                    ))
                }
                Menu("书架布局", systemImage: "square.grid.2x2") {
                    layoutButton("列表", value: "list")
                    layoutButton("紧凑列表", value: "compact")
                    ForEach(2...6, id: \.self) { count in
                        layoutButton("\(count) 列宫格", value: "grid\(count)")
                    }
                }
                NavigationLink {
                    FileManagementView()
                } label: {
                    Label("文件管理", systemImage: "folder")
                }
            } label: {
                ReadingToolbarIcon(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
    }

    private var bookshelfGroups: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(library.visibleGroups) { group in
                    Button(group.groupName) { selectedGroupID = group.id }
                        .font(.subheadline.weight(selectedGroupID == group.id ? .semibold : .regular))
                        .foregroundStyle(selectedGroupID == group.id ? Color.primary : .secondary)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if selectedGroupID == group.id {
                                Rectangle().fill(ReadingTheme.accent).frame(height: 2)
                            }
                        }
                        .accessibilityAddTraits(selectedGroupID == group.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
        }
    }

    private var gridColumns: [GridItem] {
        let count = Int(bookshelfLayout.dropFirst(4)) ?? 3
        let maximum = dynamicTypeSize.isAccessibilitySize ? 2 : 6
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: max(2, min(count, maximum)))
    }

    @ViewBuilder
    private func layoutButton(_ title: String, value: String) -> some View {
        Button {
            bookshelfLayout = value
        } label: {
            if bookshelfLayout == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
}

private struct BookOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    let groupID: Int64

    private var group: BookGroup {
        var value = library.groups.first { $0.id == groupID } ?? .init(groupId: groupID, groupName: "书籍")
        value.bookSort = BookshelfSort.custom.rawValue
        return value
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    ForEach(library.books(in: group)) { book in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.name)
                            Text(book.author).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onMove { offsets, destination in
                        Task { await library.moveBooks(in: group, from: offsets, to: destination) }
                    }
                } footer: {
                    Text("拖动调整自定义顺序。书籍的自定义顺序在各分组间共用。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("调整书籍顺序")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await library.setGroupSort(group, sort: BookshelfSort.custom.rawValue) }
            .alert("保存失败", isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.clearError() } }
            )) {
                Button("好") { library.clearError() }
            } message: { Text(library.errorMessage ?? "") }
        }
    }
}

private struct BookshelfBookLink: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    let book: Book
    let compact: Bool
    let grid: Bool
    let isAnimatingCover: Bool
    let onOpen: () -> Void
    @State private var showsGroupSelector = false

    private var source: BookSource? { sources.sources.first { $0.bookSourceUrl == book.origin } }

    var body: some View {
        Button(action: onOpen) {
            if grid {
                BookshelfGridItem(
                    book: book,
                    isAnimatingCover: isAnimatingCover
                )
            } else {
                BookshelfRow(
                    book: book,
                    compact: compact,
                    isAnimatingCover: isAnimatingCover
                )
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            NavigationLink {
                if let source { BookDetailView(book: book, source: source) }
                else { LocalBookDetailView(book: book) }
            } label: {
                Label("书籍信息", systemImage: "info.circle")
            }
            Button("移至分组", systemImage: "rectangle.3.group") { showsGroupSelector = true }
            Button("移出书架", systemImage: "trash", role: .destructive) {
                Task { await library.remove(bookURL: book.bookUrl) }
            }
        }
        .sheet(isPresented: $showsGroupSelector) {
            BookGroupSelectView(book: book).environmentObject(library)
        }
        .accessibilityLabel("打开书籍，\(book.name)")
    }
}

private struct BookshelfGridItem: View {
    let book: Book
    let isAnimatingCover: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                BookCoverArtwork(
                    title: book.name,
                    author: book.author,
                    remoteURL: book.coverUrl,
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BookshelfCoverFramePreferenceKey.self,
                            value: [book.bookUrl: proxy.frame(in: .global)]
                        )
                    }
                }
                .opacity(isAnimatingCover ? 0 : 1)
            }
            .aspectRatio(0.70, contentMode: .fit)
            .frame(maxWidth: 180)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if book.lastCheckCount > 0 {
                    Circle()
                        .fill(ReadingTheme.coral)
                        .frame(width: 7, height: 7)
                        .overlay { Circle().stroke(ReadingTheme.canvas, lineWidth: 2) }
                        .offset(x: 3, y: -3)
                        .accessibilityLabel("更新 \(book.lastCheckCount) 章")
                }
            }
            Text(book.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .padding(.top, 10)
            Text(book.author.isEmpty ? "未知作者" : book.author)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .padding(.top, 3)
            ReadingProgressLine(value: BookReadingPresentation.progress(book))
                .padding(.top, 12)
            Text(BookReadingPresentation.progressLabel(book))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .padding(.top, 7)
        }
    }
}

private struct BookshelfBookDestination: View {
    let book: Book
    let source: BookSource?
    let preparation: BookshelfReadViewModel?
    let isOpeningTransition: Bool
    let openingProgress: Double
    let openingTopInset: CGFloat
    let onClose: () -> Void

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("-uiDemo"), book.origin != "local" {
                ReaderView(
                    demoBook: book,
                    chapters: DemoContent.readerChapters,
                    initialIndex: 0,
                    content: DemoContent.readerText,
                    onClose: onClose,
                    isOpeningTransition: isOpeningTransition,
                    openingProgress: openingProgress,
                    openingTopInset: openingTopInset
                )
            } else {
                BookshelfReadView(book: book, source: source, preparation: preparation,
                                  isOpeningTransition: isOpeningTransition,
                                  openingProgress: openingProgress,
                                  openingTopInset: openingTopInset, onClose: onClose)
            }
        }
        .readingTabBarHidden(!isOpeningTransition)
    }
}

private struct ContinueReadingCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let book: Book
    let isAnimatingCover: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(book.name)
                    .font(.title3.bold())
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, 7)
                Text(BookReadingPresentation.position(book))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 20)
                if book.totalChapterNum > 0 {
                    HStack(spacing: 10) {
                        ReadingProgressLine(value: BookReadingPresentation.progress(book))
                        Text("\(Int((BookReadingPresentation.progress(book) * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                }
                HStack(spacing: 12) {
                    Text("继续阅读")
                    Image(systemName: "arrow.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(ReadingTheme.onAccent)
                .padding(.horizontal, 18)
                .frame(minHeight: 40)
                .background(ReadingTheme.accentFill, in: Capsule())
                .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicTypeSize.isAccessibilitySize {
                BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverUrl, width: 94, height: 140)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: BookshelfCoverFramePreferenceKey.self,
                                value: ["\(book.bookUrl)::continue": proxy.frame(in: .global)]
                            )
                        }
                    }
                    .opacity(isAnimatingCover ? 0 : 1)
            }
        }
        .padding(20)
        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct BookGroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @State private var newName = ""
    @State private var showsCreate = false
    @State private var editingGroup: BookGroup?
    @State private var editingName = ""

    private var customGroups: [BookGroup] {
        library.groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack {
                        Text("全部")
                        Spacer()
                        Text("系统分组").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("自定义分组") {
                    ForEach(customGroups) { group in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { group.show },
                                set: { visible in Task { await library.setGroupVisible(group, visible: visible) } }
                            )) {
                                Text(group.groupName)
                            }
                            Button {
                                editingGroup = group
                                editingName = group.groupName
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task { await library.deleteGroup(group) }
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        Task { await library.moveGroups(from: offsets, to: destination) }
                    }
                }
            }
            .overlay {
                if customGroups.isEmpty {
                    ReadingUnavailableView("没有自定义分组", systemImage: "rectangle.3.group", description: Text("点右上角加号新建分组。"))
                }
            }
            .navigationTitle("书架分组")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button("新建", systemImage: "plus") { newName = ""; showsCreate = true }
                }
            }
            .alert("新建分组", isPresented: $showsCreate) {
                TextField("分组名称", text: $newName)
                Button("取消", role: .cancel) {}
                Button("确定") { Task { await library.createGroup(name: newName) } }
            }
            .alert("编辑分组", isPresented: Binding(
                get: { editingGroup != nil },
                set: { if !$0 { editingGroup = nil } }
            )) {
                TextField("分组名称", text: $editingName)
                Button("取消", role: .cancel) { editingGroup = nil }
                Button("确定") {
                    guard let group = editingGroup else { return }
                    Task { await library.renameGroup(group, name: editingName) }
                    editingGroup = nil
                }
            }
        }
    }
}

private struct BookGroupSelectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    let book: Book
    @State private var selected: Set<Int64>

    init(book: Book) {
        self.book = book
        _selected = State(initialValue: [])
    }

    private var customGroups: [BookGroup] {
        library.groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
    }

    var body: some View {
        ReadingNavigationStack {
            List(customGroups) { group in
                Button {
                    if !selected.insert(group.id).inserted { selected.remove(group.id) }
                } label: {
                    HStack {
                        Text(group.groupName).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(group.id) { Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent) }
                    }
                }
            }
            .overlay {
                if customGroups.isEmpty {
                    ReadingUnavailableView("没有自定义分组", systemImage: "rectangle.3.group")
                }
            }
            .navigationTitle("移至分组")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        Task { await library.setBook(book, groupIDs: selected); dismiss() }
                    }
                }
            }
            .onAppear {
                selected = Set(customGroups.filter { (book.group & $0.groupId) != 0 }.map(\.groupId))
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct LocalBookImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    let files: [LocalBookImportFile]
    let onFinish: () -> Void
    @State private var selectedPaths: Set<String>
    @State private var isImporting = false

    private var urls: [URL] { files.map(\.url) }

    init(files: [LocalBookImportFile], onFinish: @escaping () -> Void) {
        self.files = files
        self.onFinish = onFinish
        _selectedPaths = State(initialValue: Set(files.map { $0.url.path }))
    }

    var body: some View {
        ReadingNavigationStack {
            List(urls, id: \.path) { url in
                Button {
                    if !selectedPaths.insert(url.path).inserted { selectedPaths.remove(url.path) }
                } label: {
                    HStack {
                        Image(systemName: selectedPaths.contains(url.path) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedPaths.contains(url.path) ? ReadingTheme.accent : .secondary)
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent).foregroundStyle(.primary)
                            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay { if isImporting { ProgressView("正在导入…") } }
            .navigationTitle("导入本地书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { finish() }.disabled(isImporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedPaths.count == urls.count ? "取消全选" : "全选") {
                        if selectedPaths.count == urls.count { selectedPaths.removeAll() }
                        else { selectedPaths = Set(urls.map(\.path)) }
                    }
                    .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        isImporting = true
                        let selected = files.filter { selectedPaths.contains($0.url.path) }
                        Task {
                            await library.importPickedLocalFiles(selected)
                            finish()
                        }
                    }
                    .disabled(selectedPaths.isEmpty || isImporting)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}

private struct EmptyBookshelfHero: View {
    @Environment(\.colorScheme) private var colorScheme
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image("BookshelfEmptyArtwork")
                .resizable()
                .scaledToFit()
                .frame(width: 168, height: 112)
                .opacity(colorScheme == .dark ? 0.78 : 1)
                .accessibilityHidden(true)
            Text("书架还是空的")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ReadingTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 22)
            Text("导入本地书，或添加书源后搜索书籍")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Button(action: onImport) {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .accessibilityHidden(true)
                    Text("导入本地书")
                        .font(.headline)
                }
                .foregroundStyle(ReadingTheme.onAccent)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .frame(minWidth: 170, minHeight: 44)
                .background(ReadingTheme.accentFill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bookshelf.importLocal")
            .padding(.top, 28)
            NavigationLink { SourceManagementView() } label: {
                Text("添加书源")
                    .font(.body)
                    .foregroundStyle(ReadingTheme.ink)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bookshelf.addSource")
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
    }
}

struct BookshelfReadView: View {
    let book: Book
    let source: BookSource?
    let isOpeningTransition: Bool
    let openingProgress: Double
    let openingTopInset: CGFloat
    private let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @AppStorage("readerTheme") private var readerTheme = "wechat"
    @AppStorage("themeMode") private var themeMode = "0"
    @StateObject private var model: BookshelfReadViewModel

    init(
        book: Book,
        source: BookSource?,
        preparation: BookshelfReadViewModel? = nil,
        isOpeningTransition: Bool = false,
        openingProgress: Double = 1,
        openingTopInset: CGFloat = 0,
        onClose: (() -> Void)? = nil
    ) {
        self.book = book
        self.source = source
        self.isOpeningTransition = isOpeningTransition
        self.openingProgress = openingProgress
        self.openingTopInset = openingTopInset
        self.onClose = onClose
        _model = StateObject(wrappedValue: preparation ?? BookshelfReadViewModel())
    }

    var body: some View {
        Group {
            if !model.chapters.isEmpty, model.resolvedBook != nil,
               let readerModel = model.makeReaderModel(source: source) {
                ReaderView(model: readerModel, onClose: onClose,
                           isOpeningTransition: isOpeningTransition, openingProgress: openingProgress,
                           openingTopInset: openingTopInset)
            } else if model.isLoading {
                openingStateView {
                    ProgressView("正在打开…")
                }
            } else if let errorMessage = model.errorMessage {
                openingStateView {
                    ReadingUnavailableView("无法打开书籍", systemImage: "book.closed", description: Text(errorMessage))
                }
            } else {
                openingStateView {
                    ProgressView("正在打开…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(openingPlaceholderBackground)
    }

    private var openingPlaceholderBackground: Color {
        if book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
            return Color(uiColor: .systemBackground)
        }
        let preset = themeMode == "3" ? ReaderStylePreset.eInk : ReaderStylePreset.resolve(readerTheme)
        return Color(uiColor: preset.background)
    }

    private var openingContentOpacity: Double {
        min(max((openingProgress - 0.70) / 0.30, 0), 1)
    }

    private func openingStateView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 16) {
            if onClose != nil {
                HStack {
                    Button(action: close) {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("返回书架")
                    Spacer()
                }
            }
            Spacer()
            content()
            Spacer()
        }
        .padding(.horizontal, 20)
        .opacity(isOpeningTransition ? openingContentOpacity : 1)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

private struct BookshelfRow: View {
    let book: Book
    var compact = false
    let isAnimatingCover: Bool
    @ScaledMetric(relativeTo: .body) private var coverWidth = 52

    private var readingPosition: String {
        if let title = book.durChapterTitle, !title.isEmpty { return title }
        if book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0 {
            return book.totalChapterNum > 0
                ? "第 \(book.durChapterIndex + 1) 章 / 共 \(book.totalChapterNum) 章"
                : "已读至第 \(book.durChapterIndex + 1) 章"
        }
        return "尚未阅读"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BookCoverArtwork(
                title: book.name,
                author: book.author,
                remoteURL: book.coverUrl,
                width: compact ? 40 : coverWidth,
                height: compact ? 56 : coverWidth * 1.42
            )
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BookshelfCoverFramePreferenceKey.self,
                        value: [book.bookUrl: proxy.frame(in: .global)]
                    )
                }
            }
            .opacity(isAnimatingCover ? 0 : 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(book.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if book.lastCheckCount > 0 {
                        Text("+\(book.lastCheckCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ReadingTheme.accent)
                            .fixedSize()
                            .accessibilityLabel("更新 \(book.lastCheckCount) 章")
                    }
                }
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !compact {
                    Text(readingPosition)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, compact ? 10 : 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(book.latestChapterTitle.map { "最新章节：\($0)" } ?? "")
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let fixedSource: BookSource?
    private let initialKeyword: String
    @State private var keyword: String
    @StateObject private var model = SearchViewModel()
    @State private var showsScope = false
    @State private var selectedGroups = Set<String>()
    @State private var selectedSourceID: String?
    @State private var didStartInitialSearch = false
    @State private var searchIsPresented = false
    @State private var visibleResultIDs = Set<String>()
    @AppStorage("precisionSearch") private var precisionSearch = false

    init(fixedSource: BookSource? = nil, initialKeyword: String = "") {
        self.fixedSource = fixedSource
        self.initialKeyword = initialKeyword
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                switch model.state {
                case .idle:
                    idleContent
                case .searching where model.books.isEmpty:
                    initialLoadingView
                case .unavailable:
                    unavailableView
                case .empty:
                    emptyResultsView
                case .searching, .finished:
                    resultsContent
                }
                if model.state != .searching, !model.diagnostics.isEmpty { diagnosticsCard }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(ReadingTheme.canvas)
        .navigationTitle("搜索")
        .readingSearchable(text: $keyword, isPresented: $searchIsPresented, prompt: "书名或作者")
        .readingScrollDismissesKeyboard()
        .onSubmit(of: [.text, .search]) { startSearch() }
        .onDisappear {
            if model.state == .searching || model.isLoadingMore { model.cancel() }
        }
        .onChange(of: keyword) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.cancel(reset: true)
            }
        }
        .onChange(of: model.state) { state in
            if state == .finished { loadMoreForVisibleLastResult() }
        }
        .onChange(of: model.isLoadingMore) { loading in
            if !loading { loadMoreForVisibleLastResult() }
        }
        .onChange(of: library.sources.count) { _ in
            guard !didStartInitialSearch,
                  !initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !library.sources.isEmpty else { return }
            didStartInitialSearch = true
            startSearch()
        }
        .task {
            await model.loadSearchKeywords()
            if initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchIsPresented = true
            } else if !library.sources.isEmpty, !didStartInitialSearch {
                didStartInitialSearch = true
                startSearch()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("精准搜索", isOn: $precisionSearch)
                    Button("分组或书源", systemImage: "scope") { showsScope = true }
                    NavigationLink {
                        SourceManagementView()
                    } label: {
                        Label("书源管理", systemImage: "network")
                    }
                    if model.state == .searching {
                        Button("停止搜索", systemImage: "stop.fill", role: .destructive) {
                            model.cancel()
                        }
                    } else if model.isPaused {
                        Button("继续搜索", systemImage: "play.fill") { model.resume() }
                    }
                } label: {
                    Label("搜索选项", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("搜索选项")
                .accessibilityIdentifier("search.options")
            }
        }
        .sheet(isPresented: $showsScope) {
            SearchScopeSheet(
                sources: library.sources.filter(\.enabled),
                groups: library.groups,
                selectedGroups: $selectedGroups,
                selectedSourceID: $selectedSourceID
            )
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        discoveryPrompt
        if !model.searchKeywords.isEmpty {
            searchHistoryView
        }
    }

    private var discoveryPrompt: some View {
        Button { searchIsPresented = true } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(ReadingTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("搜索书名或作者")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(searchableSourceCount) 个书源 · \(scopeDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 20)
        }
        .buttonStyle(.plain)
    }

    private var initialLoadingView: some View {
        VStack(spacing: 12) {
            ReadingCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("正在搜索“\(model.submittedKeyword)”").font(.headline)
                            Text(searchProgressText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("停止", role: .destructive) { model.cancel() }
                            .font(.subheadline.weight(.medium))
                    }
                    ProgressView(value: searchProgress)
                        .tint(ReadingTheme.accent)
                    Text("结果会在书源返回后立即显示，无需等待全部完成。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(0..<2, id: \.self) { _ in SearchLoadingRow() }
        }
    }

    private var resultsContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(model.submittedKeyword)”").font(.headline).lineLimit(1)
                        Text(model.isShowingCachedResults
                             ? (model.state == .searching ? "已显示缓存结果，正在更新书源" : "已显示缓存结果")
                             : "找到 \(model.books.count) 本，已自动合并重复来源")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isPaused {
                        Button("继续", systemImage: "play.fill") { model.resume() }
                            .readingSecondaryButtonStyle()
                            .controlSize(.small)
                    } else if model.state == .searching {
                        StatusPill(text: "\(model.completedSourceCount)/\(model.totalSourceCount)", systemImage: "magnifyingglass")
                    } else {
                        StatusPill(text: scopeDisplay, systemImage: "scope")
                    }
                }
                if model.state == .searching {
                    ProgressView(value: searchProgress).tint(ReadingTheme.accent)
                }
            }
            .padding(.vertical, 4)

            ForEach(model.books) { book in
                if let source = library.sources.first(where: { $0.bookSourceUrl == book.origin }) {
                    NavigationLink {
                        BookDetailView(searchBook: book, source: source)
                    } label: {
                        SearchBookRow(book: book)
                    }
                    .buttonStyle(.plain)
                    .onAppear { resultAppeared(book) }
                    .onDisappear { visibleResultIDs.remove(book.id) }
                } else {
                    SearchBookRow(book: book)
                        .onAppear { resultAppeared(book) }
                        .onDisappear { visibleResultIDs.remove(book.id) }
                }
            }
            if model.isLoadingMore {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在查找更多结果…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if !model.hasMore, model.state == .finished {
                Text("已经到底了")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    private var emptyResultsView: some View {
        SearchStateCard(
            title: model.isPaused ? "搜索已停止" : "没有找到“\(model.submittedKeyword)”",
            detail: emptyResultsDetail,
            systemImage: model.isPaused ? "pause.circle" : "book.closed"
        ) {
            if model.isPaused {
                Button("继续搜索", systemImage: "play.fill") { model.resume() }
                    .readingProminentButtonStyle()
            }
            Button("修改关键词", systemImage: "text.cursor") { searchIsPresented = true }
                .readingSecondaryButtonStyle()
        }
    }

    private var unavailableView: some View {
        SearchStateCard(
            title: "当前范围没有可搜索书源",
            detail: "请启用带搜索规则的书源，或调整当前搜索范围。",
            systemImage: "network.slash"
        ) {
            Button("调整范围", systemImage: "scope") { showsScope = true }
                .readingProminentButtonStyle()
            NavigationLink {
                SourceManagementView()
            } label: {
                Label("管理书源", systemImage: "network")
            }
            .readingSecondaryButtonStyle()
        }
    }

    private var searchProgress: Double {
        guard model.totalSourceCount > 0 else { return 0 }
        return Double(model.completedSourceCount) / Double(model.totalSourceCount)
    }

    private var emptyResultsDetail: String {
        if model.isPaused { return "你可以继续搜索剩余书源，或修改关键词重新搜索。" }
        if precisionSearch { return "试试更短的书名、作者名，或关闭精准搜索。" }
        return "试试更短的书名、作者名，或调整搜索范围。"
    }

    private var searchProgressText: String {
        model.completedSourceCount == 0
            ? "正在连接 \(model.totalSourceCount) 个书源"
            : "已完成 \(model.completedSourceCount) / \(model.totalSourceCount) 个书源"
    }

    private var searchableSourceCount: Int {
        scopedSources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }.count
    }

    private func resultAppeared(_ book: SearchBook) {
        visibleResultIDs.insert(book.id)
        loadMoreForVisibleLastResult()
    }

    private func loadMoreForVisibleLastResult() {
        // A streamed result can appear before its search finishes. Recheck
        // after each batch as well as appearance; the row may stay on screen.
        guard let lastID = model.books.last?.id, visibleResultIDs.contains(lastID) else { return }
        model.loadMore()
    }

    private var diagnosticsCard: some View {
        DisclosureGroup("部分书源未返回结果（\(model.diagnostics.count)）") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.diagnostics.prefix(20)) { diagnostic in
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.message).font(.subheadline)
                            Text(diagnostic.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var searchHistoryView: some View {
        ReadingCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("搜索历史").font(.headline)
                    Spacer()
                    Button("清空") { Task { await model.clearSearchKeywords() } }.font(.subheadline)
                }
                .padding(.bottom, 8)
                ForEach(model.searchKeywords) { item in
                    Divider().padding(.leading, 28)
                    HStack(spacing: 10) {
                        Button { keyword = item.word; startSearch() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(item.word).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { await model.deleteSearchKeyword(item.word) }
                        } label: {
                            Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.tertiary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除 \(item.word)")
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var scopedSources: [BookSource] {
        if var fixedSource { fixedSource.enabled = true; return [fixedSource] }
        let enabled = library.sources.filter(\.enabled)
        if let selectedSourceID { return enabled.filter { $0.id == selectedSourceID } }
        guard !selectedGroups.isEmpty else { return enabled }
        return enabled.filter { source in selectedGroups.contains(where: source.hasGroup) }
    }

    private var scopeDisplay: String {
        if let fixedSource { return fixedSource.bookSourceName }
        if let selectedSourceID, let source = library.sources.first(where: { $0.id == selectedSourceID }) { return source.bookSourceName }
        return selectedGroups.isEmpty ? "全部书源" : selectedGroups.sorted().joined(separator: ",")
    }

    private func startSearch() {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchIsPresented = false
        model.search(keyword: value, sources: scopedSources, precision: precisionSearch)
    }
}

private struct SearchLoadingRow: View {
    var body: some View {
        ReadingCard {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.12)).frame(width: 58, height: 82)
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.14)).frame(width: 150, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.1)).frame(width: 90, height: 11)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.08)).frame(maxWidth: .infinity).frame(height: 11)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SearchStateCard<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ReadingCard {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 64, height: 64)
                    .background(ReadingTheme.accentSoft.opacity(0.5), in: Circle())
                VStack(spacing: 5) {
                    Text(title).font(.headline).multilineTextAlignment(.center)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) { actions }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

private struct SearchBookRow: View {
    let book: SearchBook

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverArtwork(
                title: book.name,
                author: book.author,
                remoteURL: book.coverURL,
                width: 52,
                height: 74
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption).foregroundStyle(.secondary)
                if let latest = book.latestChapterTitle, !latest.isEmpty {
                    Text(latest)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(book.origins.count > 1 ? "\(book.origins.count) 个来源" : book.originName)
                        .lineLimit(1)
                    if let wordCount = book.wordCount, !wordCount.isEmpty {
                        Text("·")
                        Text(wordCount).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                .padding(.leading, 66)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("themeMode") private var themeMode = "0"
    @ScaledMetric(relativeTo: .body) private var rowHeight = 52

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    profileHeader(topInset: geometry.safeAreaInsets.top)
                    VStack(alignment: .leading, spacing: 24) {
                        appCard
                        readingSection
                        rulesSection
                        settingSection("文件与存储") {
                            settingLink("文件管理", icon: "folder", showsSeparator: false) {
                                FileManagementView()
                            }
                        }
                        supportSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 32)
                }
                .background(alignment: .top) {
                    Image("ProfileHeader")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.safeAreaInsets.top + 156)
                        .clipped()
                        .overlay {
                            if colorScheme == .dark {
                                Color.black.opacity(0.78)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [ProfileTheme.canvas.opacity(0), ProfileTheme.canvas],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: 44)
                        }
                        .accessibilityHidden(true)
                }
            }
            .background(ProfileTheme.canvas)
            .ignoresSafeArea(.container, edges: .top)
            .accessibilityIdentifier("profile.scroll")
        }
        .background(ProfileTheme.canvas)
        .navigationBarHidden(true)
    }

    private func profileHeader(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的")
                .font(.largeTitle.bold())
                .foregroundStyle(ProfileTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("按照你的方式阅读")
                .font(.subheadline)
                .foregroundStyle(ProfileTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, topInset + 42)
        .padding(.bottom, 34)
    }

    private var appCard: some View {
        NavigationLink {
            AboutView()
        } label: {
            HStack(spacing: 16) {
                Image("BrandIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppIdentity.name)
                        .font(.headline)
                        .foregroundStyle(ProfileTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("快速搜书，自由阅读")
                        .font(.footnote)
                        .foregroundStyle(ProfileTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProfileTheme.ink.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(ProfileTheme.detail.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [ProfileTheme.surface, ProfileTheme.appCardTint],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ProfileTheme.surface.opacity(0.9), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看关于与版本信息")
        .accessibilityIdentifier("profile.about")
    }

    private var readingSection: some View {
        settingSection("阅读") {
            settingLink("阅读设置", icon: "textformat.size") { ReadingPreferencesView() }
            Menu {
                Picker("外观", selection: $themeMode) {
                    Text("跟随系统").tag("0")
                    Text("浅色").tag("1")
                    Text("深色").tag("2")
                    Text("E-Ink 模式").tag("3")
                }
            } label: {
                settingRow("外观", icon: "circle.lefthalf.filled", value: appearanceTitle, showsValuePill: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("外观")
            .accessibilityValue(appearanceTitle)
            .accessibilityIdentifier("profile.appearance")
            settingLink("在线朗读", icon: "waveform") { HttpTTSManagementView() }
            settingLink("书签", icon: "bookmark") { AllBookmarksView() }
            settingLink("阅读记录", icon: "clock", showsSeparator: false) {
                ReadingHistoryView()
            }
        }
    }

    private var rulesSection: some View {
        settingSection("书源与规则") {
            settingLink("书源管理", icon: "globe") { SourceManagementView() }
            settingLink("规则订阅", icon: "link") { RuleSubscriptionView() }
            settingLink("替换净化", icon: "text.badge.checkmark") { ReplaceRuleManagementView() }
            settingLink("TXT 目录规则", icon: "list.bullet.rectangle", showsSeparator: false) {
                TxtTocRuleManagementView()
            }
        }
    }

    private var supportSection: some View {
        settingSection("项目与支持") {
            Link(destination: AppIdentity.authorURL) {
                settingRow("开发者 Aminark", icon: "person.crop.circle", isExternal: true)
            }
            .buttonStyle(.plain)
            Link(destination: AppIdentity.projectURL) {
                settingRow("GitHub 项目", icon: "chevron.left.forwardslash.chevron.right", isExternal: true)
            }
            .buttonStyle(.plain)
            settingLink("其他设置", icon: "gearshape") { OtherSettingsView() }
            settingLink("关于", icon: "info.circle", showsSeparator: false) { AboutView() }
        }
    }

    private var appearanceTitle: String {
        switch themeMode {
        case "1": "浅色"
        case "2": "深色"
        case "3": "E-Ink 模式"
        default: "跟随系统"
        }
    }

    private func settingSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(ProfileTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(ProfileTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.025), radius: 20, x: 0, y: 8)
        }
    }

    private func settingLink<Destination: View>(
        _ title: String,
        icon: String,
        showsSeparator: Bool = true,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            settingRow(title, icon: icon, showsSeparator: showsSeparator)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.\(icon)")
    }

    private func settingRow(
        _ title: String,
        icon: String,
        value: String? = nil,
        showsValuePill: Bool = false,
        isExternal: Bool = false,
        showsSeparator: Bool = true
    ) -> some View {
        HStack(spacing: 18) {
            ProfileSettingIcon(systemName: icon)
                .frame(width: 26, height: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(ProfileTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(ProfileTheme.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, showsValuePill ? 10 : 0)
                    .padding(.vertical, showsValuePill ? 4 : 0)
                    .overlay {
                        if showsValuePill {
                            Capsule().strokeBorder(ProfileTheme.separator, lineWidth: 0.5)
                        }
                    }
            }
            Image(systemName: isExternal ? "arrow.up.right" : "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(ProfileTheme.secondary.opacity(0.65))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(ProfileTheme.separator)
                    .frame(height: 0.5)
                    .padding(.leading, 62)
                    .padding(.trailing, 18)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private enum ProfileTheme {
    static let canvas = adaptive(0xF8F8F7, dark: 0x141416)
    static let surface = adaptive(0xFFFFFF, dark: 0x232326)
    static let appCardTint = adaptive(0xFBF3EC, dark: 0x302923)
    static let ink = adaptive(0x171817, dark: 0xF3F0EC)
    static let secondary = adaptive(0x898A8C, dark: 0xA5A2A0)
    static let detail = adaptive(0xBA916B, dark: 0xD1AB84)
    static let separator = adaptive(0xEAEAEA, dark: 0x373638)

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

private struct ProfileSettingIcon: View {
    let systemName: String

    var body: some View {
        Group {
            if systemName == "textformat.size" {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("A").font(.system(size: 24, weight: .light)).foregroundStyle(ProfileTheme.ink)
                    Text("A").font(.system(size: 13, weight: .medium)).foregroundStyle(ProfileTheme.detail)
                }
            } else if ["circle.lefthalf.filled", "waveform", "bookmark", "clock", "globe"].contains(systemName) {
                Canvas { context, size in
                    context.scaleBy(x: size.width / 24, y: size.height / 24)
                    draw(in: &context)
                }
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(ProfileTheme.ink, ProfileTheme.detail)
            }
        }
    }

    private func draw(in context: inout GraphicsContext) {
        let stroke = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
        let circle = Path(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
        switch systemName {
        case "circle.lefthalf.filled":
            var half = Path()
            half.addArc(center: CGPoint(x: 12, y: 12), radius: 9.5, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            half.closeSubpath()
            context.fill(half, with: .color(ProfileTheme.ink))
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
            var edge = Path()
            edge.addArc(center: CGPoint(x: 12, y: 12), radius: 10.2, startAngle: .degrees(105), endAngle: .degrees(255), clockwise: false)
            context.stroke(edge, with: .color(ProfileTheme.detail), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        case "waveform":
            for (index, height) in [4.0, 12.0, 21.0, 14.0, 5.0].enumerated() {
                let bar = CGRect(x: 2 + Double(index) * 4.4, y: (24 - height) / 2, width: 2.4, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.2), with: .color(index > 2 ? ProfileTheme.detail : ProfileTheme.ink))
            }
        case "bookmark":
            var bookmark = Path()
            bookmark.move(to: CGPoint(x: 5, y: 21))
            bookmark.addLine(to: CGPoint(x: 5, y: 4))
            bookmark.addQuadCurve(to: CGPoint(x: 7, y: 2), control: CGPoint(x: 5, y: 2))
            bookmark.addLine(to: CGPoint(x: 17, y: 2))
            bookmark.addQuadCurve(to: CGPoint(x: 19, y: 4), control: CGPoint(x: 19, y: 2))
            bookmark.addLine(to: CGPoint(x: 19, y: 21))
            bookmark.addLine(to: CGPoint(x: 12, y: 16))
            bookmark.closeSubpath()
            context.stroke(bookmark, with: .color(ProfileTheme.detail), style: stroke)
        case "clock":
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
            var hands = Path()
            hands.move(to: CGPoint(x: 12, y: 6))
            hands.addLine(to: CGPoint(x: 12, y: 12))
            hands.addLine(to: CGPoint(x: 16, y: 15))
            context.stroke(hands, with: .color(ProfileTheme.detail), style: stroke)
        case "globe":
            let meridian = Path(ellipseIn: CGRect(x: 7.5, y: 2.5, width: 9, height: 19))
            context.stroke(meridian, with: .color(ProfileTheme.detail), style: stroke)
            var parallels = Path()
            for y in [7.0, 17.0] {
                parallels.move(to: CGPoint(x: 4, y: y))
                parallels.addQuadCurve(to: CGPoint(x: 20, y: y), control: CGPoint(x: 12, y: 12))
            }
            context.stroke(parallels, with: .color(ProfileTheme.detail), style: stroke)
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
        default: break
        }
    }
}

private struct AllBookmarksView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @State private var editingBookmark: Bookmark?
    @State private var exportsJSON = false
    @State private var exportsMarkdown = false

    private var sections: [BookmarkSection] {
        var output: [BookmarkSection] = []
        for bookmark in activity.bookmarks {
            let id = bookmark.bookName + "\u{0}" + bookmark.bookAuthor
            if output.last?.id == id {
                output[output.count - 1].bookmarks.append(bookmark)
            } else {
                output.append(.init(id: id, bookName: bookmark.bookName, author: bookmark.bookAuthor, bookmarks: [bookmark]))
            }
        }
        return output
    }

    var body: some View {
        List {
            if activity.bookmarks.isEmpty {
                ReadingUnavailableView(
                    "暂无书签",
                    systemImage: "bookmark.slash",
                    description: Text("阅读时可从菜单或点击区域添加书签。")
                )
            } else {
                ForEach(sections) { section in
                    Section("\(section.bookName)(\(section.author))") {
                        ForEach(section.bookmarks) { bookmark in
                            bookmarkLink(bookmark)
                                .contextMenu {
                                    Button("编辑书签", systemImage: "square.and.pencil") { editingBookmark = bookmark }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("书签")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !activity.bookmarks.isEmpty {
                    Menu("导出", systemImage: "square.and.arrow.up") {
                        Button("导出 JSON") { exportsJSON = true }
                        Button("导出 Markdown") { exportsMarkdown = true }
                    }
                }
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditorView(bookmark: bookmark)
        }
        .fileExporter(
            isPresented: $exportsJSON,
            document: BookmarkExportDocument(data: jsonExportData),
            contentType: .json,
            defaultFilename: exportFilename(extension: "json")
        ) { _ in }
        .fileExporter(
            isPresented: $exportsMarkdown,
            document: BookmarkExportDocument(data: Data(markdownExport.utf8)),
            contentType: .plainText,
            defaultFilename: exportFilename(extension: "md")
        ) { _ in }
    }

    private func matchingBook(_ bookmark: Bookmark) -> Book? {
        library.books.first { $0.name == bookmark.bookName && $0.author == bookmark.bookAuthor }
    }

    @ViewBuilder private func bookmarkLink(_ bookmark: Bookmark) -> some View {
        if let book = matchingBook(bookmark) {
            NavigationLink {
                BookmarkReaderDestination(
                    book: book,
                    bookmark: bookmark,
                    source: sources.sources.first { $0.bookSourceUrl == book.origin }
                )
            } label: { bookmarkRow(bookmark) }
        } else {
            Button { editingBookmark = bookmark } label: { bookmarkRow(bookmark) }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bookmark.chapterName.isEmpty ? "第 \(bookmark.chapterIndex + 1) 章" : bookmark.chapterName)
                .font(.headline).foregroundStyle(ReadingTheme.coral)
            if !bookmark.bookText.isEmpty {
                Text(bookmark.bookText).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if !bookmark.content.isEmpty {
                Label(bookmark.content, systemImage: "note.text").font(.caption).lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }

    private var jsonExportData: Data {
        (try? JSONEncoder().encode(activity.bookmarks)) ?? Data("[]".utf8)
    }

    private var markdownExport: String {
        var output = ""
        var name = ""
        var author = ""
        for bookmark in activity.bookmarks {
            if bookmark.bookName != name && bookmark.bookAuthor != author {
                name = bookmark.bookName
                author = bookmark.bookAuthor
                output += "## \(bookmark.bookName) \(bookmark.bookAuthor)\n\n"
            }
            output += "#### \(bookmark.chapterName)\n\n"
            output += "###### 原文\n \(bookmark.bookText)\n\n"
            output += "###### 摘要\n \(bookmark.content)\n\n"
        }
        return output
    }

    private func exportFilename(extension value: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        return "bookmark-\(formatter.string(from: Date())).\(value)"
    }
}

private struct BookmarkSection: Identifiable {
    let id: String
    let bookName: String
    let author: String
    var bookmarks: [Bookmark]
}

private struct BookmarkExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

private struct BookmarkEditorView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @Environment(\.dismiss) private var dismiss
    let bookmark: Bookmark
    @State private var bookText: String
    @State private var content: String

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _bookText = State(initialValue: bookmark.bookText)
        _content = State(initialValue: bookmark.content)
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section("原文") { TextEditor(text: $bookText).frame(minHeight: 150) }
                Section("摘要") { TextEditor(text: $content).frame(minHeight: 120) }
                Section {
                    Button("删除书签", role: .destructive) {
                        Task { await activity.removeBookmark(bookmark); dismiss() }
                    }
                }
            }
            .navigationTitle(bookmark.chapterName.isEmpty ? "编辑书签" : bookmark.chapterName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = bookmark
                        updated.bookText = bookText
                        updated.content = content
                        Task { await activity.updateBookmark(updated); dismiss() }
                    }
                }
            }
        }
    }
}

private struct BookmarkReaderDestination: View {
    @EnvironmentObject private var library: BookLibraryModel
    let book: Book
    let bookmark: Bookmark
    let source: BookSource?
    @State private var chapters: [BookChapter] = []
    @State private var preparedBook: Book?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let preparedBook, !chapters.isEmpty {
                if book.origin == "local" {
                    ReaderView(book: preparedBook, chapters: chapters, initialIndex: preparedBook.durChapterIndex)
                } else if let source {
                    ReaderView(book: preparedBook, chapters: chapters, initialIndex: preparedBook.durChapterIndex, source: source)
                } else {
                    ReadingUnavailableView("书源不可用", systemImage: "network.slash", description: Text("请先恢复或启用这本书对应的书源。"))
                }
            } else if isLoading {
                ProgressView("正在恢复书签位置…")
            } else {
                ReadingUnavailableView(
                    "无法打开书签",
                    systemImage: "bookmark.slash",
                    description: Text(errorMessage ?? "当前目录中找不到书签对应章节。")
                )
            }
        }
        .navigationTitle(bookmark.chapterName.isEmpty ? book.name : bookmark.chapterName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard isLoading, chapters.isEmpty else { return }
        let loaded: [BookChapter]
        var resolvedBook = book
        if book.origin == "local" {
            let targetBook = book
            do {
                loaded = try await Task.detached {
                    try LocalBookService.live().loadChapters(book: targetBook).chapters
                }.value
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                return
            }
        } else {
            guard let source else {
                errorMessage = "书源已删除或未启用。"
                isLoading = false
                return
            }
            let coordinator = Self.chapterCoordinator()
            let cached = await coordinator.storedChapters(bookURL: book.bookUrl)
            if cached.isEmpty {
                let report = await coordinator.refresh(book: book, source: source, persistDirectory: false)
                if report.refreshed {
                    if library.contains(book), !(await library.commitPreparedUpdate(requestedBook: book, report: report)) {
                        errorMessage = "更新后的书籍保存失败，已保留原书籍和阅读位置。"
                        isLoading = false
                        return
                    }
                    resolvedBook = library.books.first(where: { $0.bookUrl == report.book.bookUrl }) ?? report.book
                }
                loaded = report.chapters
                if loaded.isEmpty { errorMessage = report.diagnostics.first?.message ?? "目录加载失败。" }
            } else {
                loaded = cached
            }
        }
        guard let target = targetIndex(in: loaded) else {
            isLoading = false
            return
        }
        var restored = resolvedBook
        if restored.readConfig == nil { restored.readConfig = BookReadConfig() }
        restored.readConfig?.epubLocation = bookmark.epubLocation
        restored.durChapterIndex = target
        restored.durChapterPos = max(bookmark.chapterPosition, 0)
        restored.durChapterTitle = loaded[target].title
        chapters = loaded
        preparedBook = restored
        isLoading = false
    }

    private func targetIndex(in chapters: [BookChapter]) -> Int? {
        bookmark.resolvedChapterIndex(in: chapters) ?? chapters.firstIndex(where: { !$0.isVolume })
    }

    private static func chapterCoordinator() -> BookUpdateCoordinator {
        BookUpdateCoordinator(repository: AppBookChapterRepository.live())
    }
}

private struct SearchScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sources: [BookSource]
    let groups: [String]
    @Binding var selectedGroups: Set<String>
    @Binding var selectedSourceID: String?
    @State private var mode = 0
    @State private var sourceFilter = ""
    @State private var filterIsPresented = false
    @State private var workingGroups: Set<String>
    @State private var workingSourceID: String?

    init(
        sources: [BookSource],
        groups: [String],
        selectedGroups: Binding<Set<String>>,
        selectedSourceID: Binding<String?>
    ) {
        self.sources = sources
        self.groups = groups
        _selectedGroups = selectedGroups
        _selectedSourceID = selectedSourceID
        _workingGroups = State(initialValue: selectedGroups.wrappedValue)
        _workingSourceID = State(initialValue: selectedSourceID.wrappedValue)
        _mode = State(initialValue: selectedSourceID.wrappedValue == nil ? 0 : 1)
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Picker("范围类型", selection: $mode) {
                    Text("分组").tag(0)
                    Text("书源").tag(1)
                }
                .pickerStyle(.segmented)

                Button("全部书源") {
                    selectedGroups.removeAll()
                    selectedSourceID = nil
                    dismiss()
                }

                if mode == 0 {
                    ForEach(groups, id: \.self) { group in
                        Button {
                            workingSourceID = nil
                            if !workingGroups.insert(group).inserted { workingGroups.remove(group) }
                        } label: {
                            HStack {
                                Text(group).foregroundStyle(.primary)
                                Spacer()
                                if workingGroups.contains(group) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } else {
                    ForEach(filteredSources) { source in
                        Button {
                            workingGroups.removeAll()
                            workingSourceID = source.id
                            filterIsPresented = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(source.bookSourceName).foregroundStyle(.primary)
                                    Text(source.bookSourceUrl).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if workingSourceID == source.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("分组或书源")
            .navigationBarTitleDisplayMode(.inline)
            .readingSearchable(text: $sourceFilter, isPresented: $filterIsPresented, prompt: "筛选书源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        selectedGroups = workingGroups
                        selectedSourceID = workingSourceID
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredSources: [BookSource] {
        guard !sourceFilter.isEmpty else { return sources }
        return sources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(sourceFilter)
                || $0.bookSourceUrl.localizedCaseInsensitiveContains(sourceFilter)
        }
    }
}

private struct ReadingPreferencesView: View {
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("letterSpacing") private var letterSpacing = 0.1
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 0.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = 0.0
    @AppStorage("underlineMode") private var underlineMode = 0
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("pageAnim") private var pageAnimation = 0
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false

    var body: some View {
        Form {
            Section("排版") {
                ReadingLabeledContent("字号", value: String(format: "%.0f", fontSize))
                Slider(value: $fontSize, in: 5...50, step: 1)
                ReadingLabeledContent("字间距", value: String(format: "%.2f", letterSpacing))
                Slider(value: $letterSpacing, in: -0.5...0.5, step: 0.01)
                ReadingLabeledContent("行间距", value: String(format: "%.0f", lineSpacing))
                Slider(value: $lineSpacing, in: 0...50, step: 1)
                ReadingLabeledContent("段距", value: String(format: "%.1f", paragraphSpacing))
                Slider(value: $paragraphSpacing, in: 0...50, step: 1)
                Picker("字重", selection: $fontWeight) {
                    Text("正常").tag(0)
                    Text("粗体").tag(1)
                    Text("细体").tag(2)
                }
                TextField("段落缩进字符", text: $paragraphIndent)
                Picker("下划线", selection: $underlineMode) {
                    Text("关闭").tag(0)
                    Text("实线").tag(1)
                    Text("虚线").tag(2)
                }
            }
            Section("正文边距") {
                paddingSlider("左边距", value: $paddingLeft)
                paddingSlider("右边距", value: $paddingRight)
                paddingSlider("上边距", value: $paddingTop)
                paddingSlider("下边距", value: $paddingBottom)
            }
            Section("章节标题") {
                Picker("标题模式", selection: $titleMode) {
                    Text("左对齐").tag(0)
                    Text("居中").tag(1)
                    Text("隐藏").tag(2)
                }
                ReadingLabeledContent("字号增量", value: String(format: "%+.0f", titleSize))
                Slider(value: $titleSize, in: -10...30, step: 1)
                ReadingLabeledContent("上间距", value: String(Int(titleTopSpacing)))
                Slider(value: $titleTopSpacing, in: 0...100, step: 1)
                ReadingLabeledContent("下间距", value: String(Int(titleBottomSpacing)))
                Slider(value: $titleBottomSpacing, in: 0...100, step: 1)
            }
            Section("翻页") {
                Picker("翻页模式", selection: $pageAnimation) {
                    Text("覆盖").tag(0)
                    Text("滑动").tag(1)
                    Text("仿真").tag(2)
                    Text("滚动").tag(3)
                    Text("无动画").tag(4)
                }
            }
            Section("屏幕") {
                Toggle("阅读时不自动锁屏", isOn: $keepScreenOn)
                Toggle("阅读时隐藏小横条", isOn: $hideHomeIndicator)
            }
            Section("阅读背景") {
                ForEach(ReaderStylePreset.legadoDefaults) { preset in
                    Button {
                        theme = preset.id
                    } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(uiColor: preset.background))
                                .frame(width: 38, height: 28)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.5))
                                }
                            Text(preset.name).foregroundStyle(.primary)
                            Spacer()
                            if ReaderStylePreset.resolve(theme).id == preset.id {
                                Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent)
                            }
                        }
                    }
                }
            }
            Section("预览") {
                Text("雨落在旧城的瓦檐上，故事从一束灯光开始。")
                    .tracking(letterSpacing * fontSize)
                    .font(.system(size: fontSize, design: .serif))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(Color(uiColor: ReaderStylePreset.resolve(theme).foreground))
                    .padding(.vertical, 12)
                    .listRowBackground(Color(uiColor: ReaderStylePreset.resolve(theme).background))
            }
        }
        .navigationTitle("阅读设置")
    }

    private func paddingSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack {
            ReadingLabeledContent(title, value: String(Int(value.wrappedValue)))
            Slider(value: value, in: 0...100, step: 1)
        }
    }
}
