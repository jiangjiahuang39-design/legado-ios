import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookshelfReadViewModel: ObservableObject {
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var resolvedBook: Book?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private(set) var preparedReaderModel: ReaderViewModel?
    private var loadTask: Task<Void, Never>?

    private let localService: LocalBookService
    private let updateCoordinator: BookUpdateCoordinator

    init(
        localService: LocalBookService = .init(),
        updateCoordinator: BookUpdateCoordinator = .init(repository: AppBookChapterRepository.live())
    ) {
        self.localService = localService
        self.updateCoordinator = updateCoordinator
    }

    func load(book: Book, source: BookSource?, commitUpdate: (@MainActor (BookUpdateReport) async -> Bool)? = nil) async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard chapters.isEmpty else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(book: book, source: source, commitUpdate: commitUpdate)
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad(book: Book, source: BookSource?, commitUpdate: (@MainActor (BookUpdateReport) async -> Bool)?) async {
        guard chapters.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        if book.origin == "local" {
            do {
                let report = try await Task.detached { [localService] in
                    try localService.loadChapters(book: book)
                }.value
                chapters = report.chapters
                resolvedBook = book
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let stored = await updateCoordinator.storedChapters(bookURL: book.bookUrl)
        if !stored.isEmpty, matchesReadingProgress(book, chapters: stored) {
            chapters = stored
            resolvedBook = book
            return
        }
        guard let source else {
            errorMessage = "目录与阅读进度不一致，且当前书籍的书源不存在。请先恢复或更换书源。"
            return
        }
        let report = await updateCoordinator.refresh(book: book, source: source, persistDirectory: commitUpdate == nil)
        if report.refreshed, matchesReadingProgress(report.book, chapters: report.chapters) {
            if let commitUpdate, !(await commitUpdate(report)) {
                errorMessage = "更新后的书籍保存失败，已保留原书籍和阅读位置。"
                return
            }
            chapters = report.chapters
            resolvedBook = report.book
        } else {
            errorMessage = report.diagnostics.first?.message ?? "目录刷新后仍与阅读进度不一致，请稍后重试。"
        }
    }

    /// Creates the reader model once the chapter list and resolved book are ready.
    /// The returned instance can be passed directly to ReaderView for reuse.
    func makeReaderModel(source: BookSource?) -> ReaderViewModel? {
        guard !chapters.isEmpty, let resolvedBook else { return nil }
        if let preparedReaderModel {
            return preparedReaderModel
        }

        let index = resolvedBook.durChapterIndex
        let model: ReaderViewModel
        if let source {
            model = ReaderViewModel(
                book: resolvedBook,
                chapters: chapters,
                initialIndex: index,
                source: source
            )
        } else {
            model = ReaderViewModel(
                book: resolvedBook,
                chapters: chapters,
                initialIndex: index
            )
        }
        preparedReaderModel = model
        return model
    }

    private func matchesReadingProgress(_ book: Book, chapters: [BookChapter]) -> Bool {
        guard book.totalChapterNum == 0 || book.totalChapterNum == chapters.count else { return false }
        guard let title = book.durChapterTitle, !title.isEmpty else { return true }
        return chapters.indices.contains(book.durChapterIndex)
            && chapters[book.durChapterIndex].title == title
    }
}
