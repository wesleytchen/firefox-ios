// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Storage
import Shared
import SiteImageView
import WebKit

private var debugTabCount = 0

func mostRecentTab(inTabs tabs: [Tab]) -> Tab? {
    var recent = tabs.first
    tabs.forEach { tab in
        if let time = tab.lastExecutedTime, time > (recent?.lastExecutedTime ?? 0) {
            recent = tab
        }
    }
    return recent
}

protocol TabContentScript {
    static func name() -> String
    func scriptMessageHandlerNames() -> [String]?
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceiveScriptMessage message: WKScriptMessage
    )
    func prepareForDeinit()
}

extension TabContentScript {
    // By default most script don't need a `prepareForDeinit`
    func prepareForDeinit() {}
}

protocol LegacyTabDelegate: AnyObject {
    func tab(_ tab: Tab, didAddSnackbar bar: SnackBar)
    func tab(_ tab: Tab, didRemoveSnackbar bar: SnackBar)
    func tab(_ tab: Tab, didSelectFindInPageForSelection selection: String)
    func tab(_ tab: Tab, didSelectSearchWithFirefoxForSelection selection: String)
    func tab(_ tab: Tab, didCreateWebView webView: WKWebView)
    func tab(_ tab: Tab, willDeleteWebView webView: WKWebView)
}

@objc
protocol URLChangeDelegate {
    func tab(_ tab: Tab, urlDidChangeTo url: URL)
}

struct TabState {
    var isPrivate = false
    var url: URL?
    var title: String?
}

enum TabUrlType: String {
    case regular
    case search
    case followOnSearch
    case organicSearch
    case googleTopSite
    case googleTopSiteFollowOn
}

class Tab: NSObject, ThemeApplicable {
    static let privateModeKey = "PrivateModeKey"
    private var _isPrivate = false
    private(set) var isPrivate: Bool {
        get {
            return _isPrivate
        }
        set {
            if _isPrivate != newValue {
                _isPrivate = newValue
            }
        }
    }

    var urlType: TabUrlType = .regular
    var tabState: TabState {
        return TabState(isPrivate: _isPrivate, url: url, title: displayTitle)
    }

    var timerPerWebsite: [String: StopWatchTimer] = [:]

    // Tab Groups
    var metadataManager: LegacyTabMetadataManager?

    // PageMetadata is derived from the page content itself, and as such lags behind the
    // rest of the tab.
    var pageMetadata: PageMetadata? {
        didSet {
            faviconURL = pageMetadata?.faviconURL
        }
    }

    var readabilityResult: ReadabilityResult?

    var consecutiveCrashes: UInt = 0

    // Setting default page as topsites
    var newTabPageType: NewTabPage = .topSites
    var tabUUID: String = UUID().uuidString
    private var screenshotUUIDString: String?

    var screenshotUUID: UUID? {
        get {
            guard let uuidString = screenshotUUIDString else { return nil }
            return UUID(uuidString: uuidString)
        } set(value) {
            screenshotUUIDString = value?.uuidString ?? ""
        }
    }

    var adsTelemetryUrlList: [String] = [String]() {
        didSet {
            startingSearchUrlWithAds = url
        }
    }
    var adsTelemetryRedirectUrlList: [URL] = [URL]()
    var startingSearchUrlWithAds: URL?
    var adsProviderName: String = ""
    var hasHomeScreenshot = false
    private var logger: Logger

    // To check if current URL is the starting page i.e. either blank page or internal page like topsites
    var isURLStartingPage: Bool {
        guard url != nil else { return true }
        if url!.absoluteString.hasPrefix("internal://") {
            return true
        }
        return false
    }

    var canonicalURL: URL? {
        if let string = pageMetadata?.siteURL,
           let siteURL = URL(string: string, invalidCharacters: false) {
            // If the canonical URL from the page metadata doesn't contain the
            // "#" fragment, check if the tab's URL has a fragment and if so,
            // append it to the canonical URL.
            if siteURL.fragment == nil,
               let fragment = self.url?.fragment,
               let siteURLWithFragment = URL(string: "\(string)#\(fragment)", invalidCharacters: false) {
                return siteURLWithFragment
            }

            return siteURL
        }
        return self.url
    }

    var loading: Bool {
        return webView?.isLoading ?? false
    }

    var estimatedProgress: Double {
        return webView?.estimatedProgress ?? 0
    }

    var backList: [WKBackForwardListItem]? {
        return webView?.backForwardList.backList
    }

    var forwardList: [WKBackForwardListItem]? {
        return webView?.backForwardList.forwardList
    }

    var historyList: [URL] {
        func listToUrl(_ item: WKBackForwardListItem) -> URL { return item.url }

        var historyUrls = self.backList?.map(listToUrl) ?? [URL]()
        if let url = url {
            historyUrls.append(url)
        }
        return historyUrls
    }

    var title: String? {
        if let title = webView?.title, !title.isEmpty {
            return webView?.title
        }

        return nil
    }

    /// This property returns, ideally, the web page's title. Otherwise, based on the page being internal
    /// or not, it will resort to other displayable titles.
    var displayTitle: String {
        if let lastTitle = lastTitle, !lastTitle.isEmpty {
            return lastTitle
        }

        // First, check if the webView can give us a title.
        if let title = webView?.title, !title.isEmpty {
            return title
        }

        // If the webView doesn't give a title. check the URL to see if it's our Home URL, with no sessionData
        // on this tab. When picking a display title. Tabs with sessionData are pending a restore so show their
        // old title. To prevent flickering of the display title. If a tab is restoring make sure to use
        // its lastTitle.
        if let url = self.url, InternalURL(url)?.isAboutHomeURL ?? false {
            return .AppMenu.AppMenuOpenHomePageTitleString
        }

        // Here's another check to see if we're at the Home URL, using sessionData.
        // lets double check the sessionData in case this is a non-restored new tab
        if let firstURL = sessionData?.urls.first, sessionData?.urls.count == 1,
           InternalURL(firstURL)?.isAboutHomeURL ?? false {
            return .AppMenu.AppMenuOpenHomePageTitleString
        }

        // Then, if it's not Home, and it's also not a complete and valid URL, display what was "entered" as the title.
        if let url = self.url, !InternalURL.isValid(url: url), let shownUrl = url.displayURL?.absoluteString {
            return shownUrl
        }

        // Finally, somehow lastTitle is persisted (and webView's title isn't).
        guard let lastTitle = lastTitle, !lastTitle.isEmpty else {
            // And if `lastTitle` fails, we'll take the URL itself (somewhat treated) as the last resort.
            return self.url?.displayURL?.baseDomain ??  ""
        }

        return lastTitle
    }

    /// Use the display title unless it's an empty string, then use the base domain from the url
    func getTabTrayTitle() -> String {
        let baseDomain = sessionData?.urls.last?.baseDomain ?? url?.baseDomain
        var backUpName: String = "" // In case display title is empty

        if let baseDomain = baseDomain {
            backUpName = baseDomain.contains("local") ? .AppMenu.AppMenuOpenHomePageTitleString : baseDomain
        } else if let url = url, let about = InternalURL(url)?.aboutComponent {
            backUpName = about
        }

        return displayTitle.isEmpty ? backUpName : displayTitle
    }

    var canGoBack: Bool {
        return webView?.canGoBack ?? false
    }

    var canGoForward: Bool {
        return webView?.canGoForward ?? false
    }

    var userActivity: NSUserActivity?
    var webView: TabWebView?
    weak var tabDelegate: LegacyTabDelegate?
    weak var urlDidChangeDelegate: URLChangeDelegate?
    var bars = [SnackBar]()
    var lastExecutedTime: Timestamp?
    var firstCreatedTime: Timestamp?
    var sessionData: LegacySessionData?
    private let faviconHelper: SiteImageHandler
    var faviconURL: String? {
        didSet {
            faviconHelper.cacheFaviconURL(
                siteURL: url,
                faviconURL: URL(string: faviconURL ?? "", invalidCharacters: false)
            )
        }
    }
    fileprivate var lastRequest: URLRequest?
    var pendingScreenshot = false
    var url: URL? {
        didSet {
            if let _url = url, let internalUrl = InternalURL(_url), internalUrl.isAuthorized {
                url = URL(string: internalUrl.stripAuthorization, invalidCharacters: false)
            }
        }
    }
    var lastKnownUrl: URL? {
        // Tab url can be nil when user cold starts the app
        // thus we check session data for last known url
        guard self.url != nil else {
            return self.sessionData?.urls.last
        }
        return self.url
    }

    var isFxHomeTab: Bool {
        // Check if there is a url or last known url
        let url = url ?? lastKnownUrl
        guard let url = url else { return false }

        // Make sure the url is of type home page
        if url.absoluteString.hasPrefix("internal://"),
           let internalUrl = InternalURL(url),
           internalUrl.isAboutHomeURL {
            return true
        }
        ensureMainThread {
            self.setZoomLevelforDomain()
        }
        return false
    }

    var isCustomHomeTab: Bool {
        if let customHomeUrl = HomeButtonHomePageAccessors.getHomePage(profile.prefs),
           let customHomeBaseDomain = customHomeUrl.baseDomain,
           let url = url,
           let baseDomain = url.baseDomain,
           baseDomain.hasPrefix(customHomeBaseDomain) {
            return true
        }
        return false
    }

    var mimeType: String?
    var isEditing = false
    // When viewing a non-HTML content type in the webview (like a PDF document), this URL will
    // point to a tempfile containing the content so it can be shared to external applications.
    var temporaryDocument: TemporaryDocument?

    /// Returns true if this tab's URL is known, and it's longer than we want to store.
    var urlIsTooLong: Bool {
        guard let url = self.url else {
            return false
        }
        return url.absoluteString.lengthOfBytes(using: .utf8) > AppConstants.databaseURLLengthMax
    }

    // Use computed property so @available can be used to guard `noImageMode`.
    var noImageMode: Bool {
        didSet {
            guard noImageMode != oldValue else { return }

            contentBlocker?.noImageMode(enabled: noImageMode)

            UserScriptManager.shared.injectUserScriptsIntoWebView(
                webView,
                nightMode: nightMode,
                noImageMode: noImageMode
            )
        }
    }

    var nightMode: Bool {
        didSet {
            guard nightMode != oldValue else { return }

            webView?.evaluateJavascriptInDefaultContentWorld("window.__firefox__.NightMode.setEnabled(\(nightMode))")
            // For WKWebView background color to take effect, isOpaque must be false,
            // which is counter-intuitive. Default is true. The color is previously
            // set to black in the WKWebView init.
            webView?.isOpaque = !nightMode

            UserScriptManager.shared.injectUserScriptsIntoWebView(
                webView,
                nightMode: nightMode,
                noImageMode: noImageMode
            )
        }
    }

    var contentBlocker: FirefoxTabContentBlocker?

    /// The last title shown by this tab. Used by the tab tray to show titles for zombie tabs.
    var lastTitle: String?

    /// Whether or not the desktop site was requested with the last request, reload or navigation.
    var changedUserAgent = false {
        didSet {
            if changedUserAgent != oldValue {
                TabEvent.post(.didToggleDesktopMode, for: self)
            }
        }
    }

    var readerModeAvailableOrActive: Bool {
        if mimeType == MIMEType.HTML,
           let readerMode = self.getContentScript(name: "ReaderMode") as? ReaderMode {
            return readerMode.state != .unavailable
        }
        return false
    }

    fileprivate(set) var pageZoom: CGFloat = 1.0 {
        didSet {
            webView?.setValue(pageZoom, forKey: "viewScale")
        }
    }

    fileprivate(set) var screenshot: UIImage?

    // If this tab has been opened from another, its parent will point to the tab from which it was opened
    weak var parent: Tab?

    fileprivate var contentScriptManager = TabContentScriptManager()

    fileprivate let configuration: WKWebViewConfiguration

    /// Any time a tab tries to make requests to display a Javascript Alert and we are not the active
    /// tab instance, queue it for later until we become foregrounded.
    fileprivate var alertQueue = [JSAlertInfo]()

    var profile: Profile

    init(profile: Profile,
         configuration: WKWebViewConfiguration,
         isPrivate: Bool = false,
         faviconHelper: SiteImageHandler = DefaultSiteImageHandler.factory(),
         logger: Logger = DefaultLogger.shared) {
        self.configuration = configuration
        self.nightMode = false
        self.noImageMode = false
        self.profile = profile
        self.metadataManager = LegacyTabMetadataManager(metadataObserver: profile.places)
        self.faviconHelper = faviconHelper
        self.logger = logger
        super.init()
        self.isPrivate = isPrivate
        debugTabCount += 1

        TelemetryWrapper.recordEvent(
            category: .action,
            method: .add,
            object: .tab,
            value: isPrivate ? .privateTab : .normalTab
        )
    }

    class func toRemoteTab(_ tab: Tab, inactive: Bool) -> RemoteTab? {
        if tab.isPrivate {
            return nil
        }

        let icon = (tab.faviconURL ?? tab.pageMetadata?.faviconURL).flatMap { URL(string: $0) }
        if let displayURL = tab.url?.displayURL, RemoteTab.shouldIncludeURL(displayURL) {
            let history = Array(tab.historyList.filter(RemoteTab.shouldIncludeURL).reversed())
            return RemoteTab(
                clientGUID: nil,
                URL: displayURL,
                title: tab.title ?? tab.displayTitle,
                history: history,
                lastUsed: tab.lastExecutedTime ?? 0,
                icon: icon,
                inactive: inactive
            )
        } else if let sessionData = tab.sessionData, !sessionData.urls.isEmpty {
            let history = Array(sessionData.urls.filter(RemoteTab.shouldIncludeURL).reversed())
            if let displayURL = history.first {
                return RemoteTab(
                    clientGUID: nil,
                    URL: displayURL,
                    title: tab.title ?? tab.displayTitle,
                    history: history,
                    lastUsed: sessionData.lastUsedTime,
                    icon: icon,
                    inactive: inactive
                )
            }
        }

        return nil
    }

    weak var navigationDelegate: WKNavigationDelegate? {
        didSet {
            if let webView = webView {
                webView.navigationDelegate = navigationDelegate
            }
        }
    }

    func createWebview(with restoreSessionData: Data? = nil) {
        if webView == nil {
            configuration.userContentController = WKUserContentController()
            configuration.allowsInlineMediaPlayback = true
            let webView = TabWebView(frame: .zero, configuration: configuration)
            webView.configure(delegate: self, navigationDelegate: navigationDelegate)

            webView.accessibilityLabel = .WebViewAccessibilityLabel
            webView.allowsBackForwardNavigationGestures = true
            webView.allowsLinkPreview = true

            // Allow Safari Web Inspector (requires toggle in Settings > Safari > Advanced).
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }

            // Night mode enables this by toggling WKWebView.isOpaque, otherwise this has no effect.
            webView.backgroundColor = .black

            // Turning off masking allows the web content to flow outside of the scrollView's frame
            // which allows the content appear beneath the toolbars in the BrowserViewController
            webView.scrollView.layer.masksToBounds = false

            restore(webView, interactionState: restoreSessionData)

            self.webView = webView

            // FXIOS-5549
            // There is a crash in didCreateWebView for when webview becomes nil.
            // We are adding a check before that method gets called as the webview
            // should not be nil at this point considering we created it above.
            guard self.webView != nil else {
                logger.log("No webview found for didCreateWebView.",
                           level: .fatal,
                           category: .tabs)
                return
            }

            configureEdgeSwipeGestureRecognizers()
            self.webView?.addObserver(
                self,
                forKeyPath: KVOConstants.URL.rawValue,
                options: .new,
                context: nil
            )
            self.webView?.addObserver(
                self,
                forKeyPath: KVOConstants.title.rawValue,
                options: .new,
                context: nil
            )
            self.webView?.addObserver(
                self,
                forKeyPath: KVOConstants.hasOnlySecureContent.rawValue,
                options: .new,
                context: nil
            )
            UserScriptManager.shared.injectUserScriptsIntoWebView(
                webView,
                nightMode: nightMode,
                noImageMode: noImageMode
            )

            tabDelegate?.tab(self, didCreateWebView: webView)
        }
    }

    func restore(_ webView: WKWebView, interactionState: Data? = nil) {
        if let url = url {
            webView.load(PrivilegedRequest(url: url) as URLRequest)
        }

        if let interactionState = interactionState {
            webView.interactionState = interactionState
        }
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: KVOConstants.URL.rawValue)
        webView?.removeObserver(self, forKeyPath: KVOConstants.title.rawValue)
        webView?.navigationDelegate = nil

        debugTabCount -= 1

#if DEBUG
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        func checkTabCount(failures: Int) {
            // Need delay for pool to drain.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if appDelegate.tabManager.remoteTabs.count == debugTabCount {
                    return
                }

                // If this assert has false positives, remove it and just log an error.
                assert(failures < 3, "Tab init/deinit imbalance, possible memory leak.")
                checkTabCount(failures: failures + 1)
            }
        }
        checkTabCount(failures: 0)
#endif
    }

    /// When a user clears ALL history, `sessionData` and `historyList` need to be purged, and close the webView.
    func clearAndResetTabHistory() {
        guard let currentlyOpenUrl = lastKnownUrl ?? historyList.last else { return }

        url = currentlyOpenUrl
        sessionData = LegacySessionData(
            currentPage: 0,
            urls: [currentlyOpenUrl],
            lastUsedTime: Date.now()
        )

        close()
    }

    func close() {
        contentScriptManager.uninstall(tab: self)
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()

        webView?.removeObserver(self, forKeyPath: KVOConstants.URL.rawValue)
        webView?.removeObserver(self, forKeyPath: KVOConstants.title.rawValue)

        if let webView = webView {
            tabDelegate?.tab(self, willDeleteWebView: webView)
        }

        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    func goBack() {
        _ = webView?.goBack()
    }

    func goForward() {
        _ = webView?.goForward()
    }

    func goToBackForwardListItem(_ item: WKBackForwardListItem) {
        _ = webView?.go(to: item)
    }

    @discardableResult
    func loadRequest(_ request: URLRequest) -> WKNavigation? {
        if let webView = webView {
            // Convert about:reader?url=http://example.com URLs to local ReaderMode URLs
            if let url = request.url,
               let syncedReaderModeURL = url.decodeReaderModeURL,
               let localReaderModeURL = syncedReaderModeURL.encodeReaderModeURL(
                WebServer.sharedInstance.baseReaderModeURL()
               ) {
                let readerModeRequest = PrivilegedRequest(url: localReaderModeURL) as URLRequest
                lastRequest = readerModeRequest
                return webView.load(readerModeRequest)
            }
            lastRequest = request
            if let url = request.url, url.isFileURL, request.isPrivileged {
                return webView.loadFileURL(url, allowingReadAccessTo: url)
            }
            return webView.load(request)
        }
        return nil
    }

    func stop() {
        webView?.stopLoading()
    }

    func reload(bypassCache: Bool = false) {
        // If the current page is an error page, and the reload button is tapped, load the original URL
        if let url = webView?.url, let internalUrl = InternalURL(url), let page = internalUrl.originalURLFromErrorPage {
            webView?.replaceLocation(with: page)
            return
        }

        if bypassCache, let url = webView?.url {
            let reloadRequest = URLRequest(url: url,
                                           cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                           timeoutInterval: 10.0)

            if webView?.load(reloadRequest) != nil {
                logger.log("Reloaded the tab from originating source, ignoring local cache.",
                           level: .debug,
                           category: .tabs)
                return
            }
        }

        if webView?.reloadFromOrigin() != nil {
            logger.log("Reloaded zombified tab from origin",
                       level: .debug,
                       category: .tabs)
            return
        }

        if let webView = self.webView {
            logger.log("restoring webView from scratch",
                       level: .debug,
                       category: .tabs)
            restore(webView)
        }
    }

    @objc
    func reloadPage() {
        reload()
    }

    @objc
    func zoomIn() {
        switch pageZoom {
        case 0.75:
            pageZoom = 0.9
        case 0.9:
            pageZoom = 1.0
        case 1.0:
            pageZoom = 1.10
        case 1.10:
            pageZoom = 1.25
        case 2.0:
            return
        default:
            pageZoom += 0.25
        }
    }

    @objc
    func zoomOut() {
        switch pageZoom {
        case 0.5:
            return
        case 0.9:
            pageZoom = 0.75
        case 1.0:
            pageZoom = 0.9
        case 1.10:
            pageZoom = 1.0
        case 1.25:
            pageZoom = 1.10
        default:
            pageZoom -= 0.25
        }
    }

    func resetZoom() {
        pageZoom = 1.0
    }

    func setZoomLevelforDomain() {
        if let host = url?.host,
           let domainZoomLevel = ZoomLevelStore.shared.findZoomLevel(forDomain: host) {
            pageZoom = domainZoomLevel.zoomLevel
        } else {
            resetZoom()
        }
    }

    func addContentScript(_ helper: TabContentScript, name: String) {
        contentScriptManager.addContentScript(helper, name: name, forTab: self)
    }

    func addContentScriptToPage(_ helper: TabContentScript, name: String) {
        contentScriptManager.addContentScriptToPage(helper, name: name, forTab: self)
    }

    func getContentScript(name: String) -> TabContentScript? {
        return contentScriptManager.getContentScript(name)
    }

    func hideContent(_ animated: Bool = false) {
        webView?.isUserInteractionEnabled = false
        if animated {
            UIView.animate(withDuration: 0.25, animations: { () -> Void in
                self.webView?.alpha = 0.0
            })
        } else {
            webView?.alpha = 0.0
        }
    }

    func showContent(_ animated: Bool = false) {
        webView?.isUserInteractionEnabled = true
        if animated {
            UIView.animate(withDuration: 0.25, animations: { () -> Void in
                self.webView?.alpha = 1.0
            })
        } else {
            webView?.alpha = 1.0
        }
    }

    func addSnackbar(_ bar: SnackBar) {
        if bars.count > 2 { return } // maximum 3 snackbars allowed on a tab
        bars.append(bar)
        tabDelegate?.tab(self, didAddSnackbar: bar)
    }

    func removeSnackbar(_ bar: SnackBar) {
        if let index = bars.firstIndex(of: bar) {
            bars.remove(at: index)
            tabDelegate?.tab(self, didRemoveSnackbar: bar)
        }
    }

    func removeAllSnackbars() {
        // Enumerate backwards here because we'll remove items from the list as we go.
        bars.reversed().forEach { removeSnackbar($0) }
    }

    func expireSnackbars() {
        // Enumerate backwards here because we may remove items from the list as we go.
        bars.reversed().filter({ !$0.shouldPersist(self) }).forEach({ removeSnackbar($0) })
    }

    func expireSnackbars(withClass snackbarClass: String) {
        bars.reversed().filter({ $0.snackbarClassIdentifier == snackbarClass }).forEach({ removeSnackbar($0) })
    }

    func setScreenshot(_ screenshot: UIImage?) {
        self.screenshot = screenshot
    }

    func toggleChangeUserAgent() {
        changedUserAgent = !changedUserAgent

        if changedUserAgent, let url = url {
            let url = ChangeUserAgent().removeMobilePrefixFrom(url: url)
            let request = URLRequest(url: url)
            webView?.load(request)
        } else {
            reload()
        }

        TabEvent.post(.didToggleDesktopMode, for: self)
    }

    func queueJavascriptAlertPrompt(_ alert: JSAlertInfo) {
        alertQueue.append(alert)
    }

    func dequeueJavascriptAlertPrompt() -> JSAlertInfo? {
        guard !alertQueue.isEmpty else { return nil }
        return alertQueue.removeFirst()
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let webView = object as? WKWebView,
              webView == self.webView,
              let path = keyPath else {
            return assertionFailure("Unhandled KVO key: \(keyPath ?? "nil")")
        }

        if let url = self.webView?.url, path == KVOConstants.URL.rawValue {
            self.urlDidChangeDelegate?.tab(self, urlDidChangeTo: url)
        }

        if let title = self.webView?.title, !title.isEmpty,
           path == KVOConstants.title.rawValue {
            metadataManager?.updateObservationTitle(title)
            _ = Tab.toRemoteTab(self, inactive: false)
        }
    }

    func isDescendentOf(_ ancestor: Tab) -> Bool {
        return sequence(first: parent) { $0?.parent }.contains { $0 == ancestor }
    }

    func observeURLChanges(delegate: URLChangeDelegate) {
        self.urlDidChangeDelegate = delegate
    }

    func removeURLChangeObserver(delegate: URLChangeDelegate) {
        if let existing = self.urlDidChangeDelegate, existing === delegate {
            self.urlDidChangeDelegate = nil
        }
    }

    func getProviderForUrl() -> SearchEngine {
        guard let url = self.webView?.url else {
            return .none
        }

        for provider in SearchEngine.allCases where url.absoluteString.contains(provider.rawValue) {
            return provider
        }

        return .none
    }

    // MARK: - ThemeApplicable

    func applyTheme(theme: Theme) {
        UITextField.appearance().keyboardAppearance = theme.type.keyboardAppearence(isPrivate: isPrivate)
    }
}

extension Tab: UIGestureRecognizerDelegate {
    // This prevents the recognition of one gesture recognizer from blocking another
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    func configureEdgeSwipeGestureRecognizers() {
        guard let webView = webView else { return }

        let edgeSwipeGesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleEdgeSwipeTabNavigation(_:))
        )
        edgeSwipeGesture.edges = .left
        edgeSwipeGesture.delegate = self
        webView.addGestureRecognizer(edgeSwipeGesture)
    }

    @objc
    func handleEdgeSwipeTabNavigation(_ sender: UIScreenEdgePanGestureRecognizer) {
        guard let webView = webView else { return }

        if sender.state == .ended, sender.velocity(in: webView).x > 150 {
            TelemetryWrapper.recordEvent(
                category: .action,
                method: .swipe,
                object: .navigateTabHistoryBackSwipe
            )
        }
    }
}

extension Tab: TabWebViewDelegate {
    func tabWebView(_ tabWebView: TabWebView, didSelectFindInPageForSelection selection: String) {
        tabDelegate?.tab(self, didSelectFindInPageForSelection: selection)
    }
    func tabWebViewSearchWithFirefox(
        _ tabWebViewSearchWithFirefox: TabWebView,
        didSelectSearchWithFirefoxForSelection selection: String
    ) {
        tabDelegate?.tab(self, didSelectSearchWithFirefoxForSelection: selection)
    }
}

extension Tab: ContentBlockerTab {
    func currentURL() -> URL? {
        return url
    }

    func currentWebView() -> WKWebView? {
        return webView
    }

    func imageContentBlockingEnabled() -> Bool {
        return noImageMode
    }
}

private class TabContentScriptManager: NSObject, WKScriptMessageHandler {
    private var helpers = [String: TabContentScript]()

    // Without calling this, the TabContentScriptManager will leak.
    func uninstall(tab: Tab) {
        helpers.forEach { helper in
            helper.value.scriptMessageHandlerNames()?.forEach { name in
                tab.webView?.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
            helper.value.prepareForDeinit()
        }
    }

    @objc
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        for helper in helpers.values {
            if let scriptMessageHandlerNames = helper.scriptMessageHandlerNames(),
               scriptMessageHandlerNames.contains(message.name) {
                helper.userContentController(userContentController, didReceiveScriptMessage: message)
                return
            }
        }
    }

    func addContentScript(_ helper: TabContentScript, name: String, forTab tab: Tab) {
        // If a helper script already exists on a tab, skip adding this duplicate.
        guard helpers[name] == nil else { return }

        helpers[name] = helper

        // If this helper handles script messages, then get the handlers names and register them. The Browser
        // receives all messages and then dispatches them to the right TabHelper.
        helper.scriptMessageHandlerNames()?.forEach { scriptMessageHandlerName in
            tab.webView?.configuration.userContentController.addInDefaultContentWorld(
                scriptMessageHandler: self,
                name: scriptMessageHandlerName
            )
        }
    }

    func addContentScriptToPage(_ helper: TabContentScript, name: String, forTab tab: Tab) {
        // If a helper script already exists on the page, skip adding this duplicate.
        guard helpers[name] == nil else { return }

        helpers[name] = helper

        // If this helper handles script messages, then get the handlers names and register them. The Browser
        // receives all messages and then dispatches them to the right TabHelper.
        helper.scriptMessageHandlerNames()?.forEach { scriptMessageHandlerName in
            tab.webView?.configuration.userContentController.addInPageContentWorld(
                scriptMessageHandler: self,
                name: scriptMessageHandlerName
            )
        }
    }

    func getContentScript(_ name: String) -> TabContentScript? {
        return helpers[name]
    }
}

protocol TabWebViewDelegate: AnyObject {
    func tabWebView(_ tabWebView: TabWebView, didSelectFindInPageForSelection selection: String)
    func tabWebViewSearchWithFirefox(
        _ tabWebViewSearchWithFirefox: TabWebView,
        didSelectSearchWithFirefoxForSelection selection: String
    )
}

class TabWebView: WKWebView, MenuHelperWebViewInterface, ThemeApplicable {
    var accessoryView = AccessoryViewProvider()
    private var logger: Logger = DefaultLogger.shared
    private weak var delegate: TabWebViewDelegate?

    override var inputAccessoryView: UIView? {
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            accessoryView.widthAnchor.constraint(equalToConstant: UIScreen.main.bounds.width),
            accessoryView.heightAnchor.constraint(equalToConstant: 50)
        ])

        return accessoryView
    }

    func configure(delegate: TabWebViewDelegate,
                   navigationDelegate: WKNavigationDelegate?) {
        self.delegate = delegate
        self.navigationDelegate = navigationDelegate

        accessoryView.previousClosure = { [weak self] in
            guard let self else { return }
            FormAutofillHelper.focusPreviousInputField(tabWebView: self,
                                                       logger: self.logger)
        }

        accessoryView.nextClosure = { [weak self] in
            guard let self else { return }
            FormAutofillHelper.focusNextInputField(tabWebView: self,
                                                   logger: self.logger)
        }

        accessoryView.doneClosure = { [weak self] in
            guard let self else { return }
            FormAutofillHelper.blurActiveElement(tabWebView: self, logger: self.logger)
            self.endEditing(true)
        }
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func menuHelperFindInPage() {
        evaluateJavascriptInDefaultContentWorld("getSelection().toString()") { result, _ in
            let selection = result as? String ?? ""
            self.delegate?.tabWebView(self, didSelectFindInPageForSelection: selection)
        }
    }

    func menuHelperSearchWith() {
        evaluateJavascriptInDefaultContentWorld("getSelection().toString()") { result, _ in
            let selection = result as? String ?? ""
            self.delegate?.tabWebViewSearchWithFirefox(self, didSelectSearchWithFirefoxForSelection: selection)
        }
    }

    override internal func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // The find-in-page selection menu only appears if the webview is the first responder.
        // Do not becomeFirstResponder on a mouse event.
        if let event = event, event.allTouches?.contains(where: { $0.type != .indirectPointer }) ?? false {
            becomeFirstResponder()
        }
        return super.hitTest(point, with: event)
    }

    /// Override evaluateJavascript - should not be called directly on TabWebViews any longer
    /// We should only be calling evaluateJavascriptInDefaultContentWorld in the future
    @available(*,
                unavailable,
                message: "Do not call evaluateJavaScript directly on TabWebViews, should only be called on super class")
    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }

    // MARK: - ThemeApplicable

    /// Updates the `background-color` of the webview to match
    /// the theme if the webview is showing "about:blank" (nil).
    func applyTheme(theme: Theme) {
        if url == nil {
            let backgroundColor = theme.colors.layer1.hexString
            evaluateJavascriptInDefaultContentWorld("document.documentElement.style.backgroundColor = '\(backgroundColor)';")
        }
    }
}
