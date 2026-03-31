import Foundation
import SwiftSoup

struct ParsedArticle {
    let title: String
    let content: String
    let url: String
    let imageURL: String?
}

final class HTMLParser {

    // MARK: - Main Entry Point (Multi-Strategy Pipeline)

    /// Maximum HTML size to parse — reduced to 100KB to limit SwiftSoup DOM object explosion
    private static let maxHTMLSize = 100_000 // 100KB — enough for article extraction

    /// Strip <script> and <style> blocks from HTML BEFORE SwiftSoup parsing to reduce DOM size
    private static func stripScriptAndStyle(_ html: String) -> String {
        var result = html
        // Remove <script>...</script> blocks
        while let scriptStart = result.range(of: "<script", options: .caseInsensitive),
              let scriptEnd = result.range(of: "</script>", options: .caseInsensitive, range: scriptStart.lowerBound..<result.endIndex) {
            result.removeSubrange(scriptStart.lowerBound..<scriptEnd.upperBound)
        }
        // Remove <style>...</style> blocks
        while let styleStart = result.range(of: "<style", options: .caseInsensitive),
              let styleEnd = result.range(of: "</style>", options: .caseInsensitive, range: styleStart.lowerBound..<result.endIndex) {
            result.removeSubrange(styleStart.lowerBound..<styleEnd.upperBound)
        }
        return result
    }

    /// Synchronous article extraction — call inside autoreleasepool to free SwiftSoup DOM immediately
    static func extractArticlesSync(from html: String, sourceURL: String) -> [ParsedArticle] {
        do {
            // 1. Strip script/style BEFORE parsing — eliminates ~60% of DOM nodes
            let stripped = stripScriptAndStyle(html)
            // 2. Truncate to 100KB
            let trimmedHTML = stripped.count > maxHTMLSize ? String(stripped.prefix(maxHTMLSize)) : stripped
            let doc = try SwiftSoup.parse(trimmedHTML)

            var result: [ParsedArticle] = []

            // Strategy 1: Semantic HTML selectors
            let semantic = try extractFromSemanticHTML(doc: doc, sourceURL: sourceURL)
            if semantic.count >= 2 { result = semantic }

            // Strategy 2: JSON-LD structured data
            if result.isEmpty {
                let jsonLD = try extractFromJSONLD(doc: doc, sourceURL: sourceURL)
                if jsonLD.count >= 2 { result = jsonLD }
            }

            // Strategy 3: RSS/Atom auto-discovery — SKIPPED in sync version (done separately)

            // Strategy 4: Link-based heuristic (for modern Tailwind/Next.js sites)
            if result.isEmpty {
                let links = try extractFromLinkPatterns(doc: doc, sourceURL: sourceURL)
                if links.count >= 2 { result = links }
            }

            // Strategy 5: Fallback — whole page as one article
            if result.isEmpty {
                let title = try doc.title()
                let content = try extractMainContent(from: doc)
                let image = try extractOGImage(from: doc)
                if !content.isEmpty {
                    result = [ParsedArticle(title: title, content: content, url: sourceURL, imageURL: image)]
                }
            }

            // CRITICAL: Destroy the DOM tree to break reference cycles and free SwiftSoup objects
            doc.empty()

            return result
        } catch {
            return []
        }
    }

    /// Async version with RSS discovery — only used when sync version finds < 2 articles
    static func extractArticles(from html: String, sourceURL: String) async -> [ParsedArticle] {
        // First try sync extraction inside autoreleasepool
        let syncResult = autoreleasepool {
            extractArticlesSync(from: html, sourceURL: sourceURL)
        }
        if syncResult.count >= 2 { return syncResult }

        // Fallback: try RSS discovery (requires async)
        do {
            let stripped = stripScriptAndStyle(html)
            let trimmedHTML = stripped.count > maxHTMLSize ? String(stripped.prefix(maxHTMLSize)) : stripped
            let doc = try SwiftSoup.parse(trimmedHTML)
            let rss = try await extractFromRSSDiscovery(doc: doc, sourceURL: sourceURL)
            doc.empty()
            if rss.count >= 2 { return rss }
        } catch {}

        return syncResult
    }

    // MARK: - Strategy 1: Semantic HTML

    private static func extractFromSemanticHTML(doc: Document, sourceURL: String) throws -> [ParsedArticle] {
        let articleElements = try doc.select("article, .article, .post, .entry, .story, .card, .blog-post")
        guard !articleElements.isEmpty() else { return [] }

        return try articleElements.array().compactMap { element in
            let title = try extractTitle(from: element, doc: doc)
            let content = try extractContent(from: element)
            let link = try extractLink(from: element, baseURL: sourceURL)
            let image = try extractImage(from: element, baseURL: sourceURL)
            guard !title.isEmpty, !content.isEmpty else { return nil }
            return ParsedArticle(title: title, content: content, url: link ?? sourceURL, imageURL: image)
        }
    }

    // MARK: - Strategy 2: JSON-LD Structured Data

    private static func extractFromJSONLD(doc: Document, sourceURL: String) throws -> [ParsedArticle] {
        let scripts = try doc.select("script[type=application/ld+json]")
        var articles: [ParsedArticle] = []

        for script in scripts.array() {
            let json = try script.html()
            guard let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) else { continue }

            let items: [[String: Any]]
            if let obj = raw as? [String: Any] {
                if let graph = obj["@graph"] as? [[String: Any]] {
                    items = graph
                } else {
                    items = [obj]
                }
            } else if let arr = raw as? [[String: Any]] {
                items = arr
            } else {
                continue
            }

            let articleTypes: Set<String> = ["BlogPosting", "NewsArticle", "Article", "WebPage", "TechArticle", "ScholarlyArticle"]
            for item in items {
                let type = item["@type"] as? String ?? ""
                guard articleTypes.contains(type) else { continue }

                let title = item["headline"] as? String ?? item["name"] as? String ?? ""
                let content = item["description"] as? String ?? item["articleBody"] as? String ?? ""
                let url = item["url"] as? String ?? sourceURL
                let image = extractImageFromJSONLD(item)

                guard !title.isEmpty else { continue }
                articles.append(ParsedArticle(
                    title: title,
                    content: content.isEmpty ? title : content,
                    url: resolveURL(url, base: sourceURL) ?? url,
                    imageURL: image
                ))
            }
        }
        return articles
    }

    private static func extractImageFromJSONLD(_ item: [String: Any]) -> String? {
        if let str = item["image"] as? String { return str }
        if let obj = item["image"] as? [String: Any] { return obj["url"] as? String }
        if let arr = item["image"] as? [Any], let first = arr.first {
            if let str = first as? String { return str }
            if let obj = first as? [String: Any] { return obj["url"] as? String }
        }
        if let thumb = item["thumbnailUrl"] as? String { return thumb }
        return nil
    }

    // MARK: - Strategy 3: RSS/Atom Auto-Discovery

    private static func extractFromRSSDiscovery(doc: Document, sourceURL: String) async throws -> [ParsedArticle] {
        let feedLinks = try doc.select("link[rel=alternate][type=application/rss+xml], link[rel=alternate][type=application/atom+xml]")
        guard let feedLink = feedLinks.first() else { return [] }

        let feedHref = try feedLink.attr("href")
        guard let feedURL = resolveURL(feedHref, base: sourceURL) else { return [] }

        do {
            let feedXML = try await NetworkClient.shared.fetch(url: feedURL)
            return parseRSSFeed(feedXML, sourceURL: sourceURL)
        } catch {
            return []
        }
    }

    private static func parseRSSFeed(_ xml: String, sourceURL: String) -> [ParsedArticle] {
        var articles: [ParsedArticle] = []

        // Try RSS 2.0 <item> elements
        let items = xml.components(separatedBy: "<item>").dropFirst()
        for item in items {
            let title = extractXMLTag("title", from: item) ?? ""
            let link = extractXMLTag("link", from: item) ?? sourceURL
            let description = extractXMLTag("description", from: item) ?? ""
            let image = extractRSSImage(from: item)

            guard !title.isEmpty else { continue }
            articles.append(ParsedArticle(
                title: stripHTMLTags(title),
                content: description.isEmpty ? title : stripHTMLTags(description),
                url: cleanURL(link.trimmingCharacters(in: .whitespacesAndNewlines)),
                imageURL: image
            ))
        }

        // If no RSS items, try Atom <entry> elements
        if articles.isEmpty {
            let entries = xml.components(separatedBy: "<entry>").dropFirst()
            for entry in entries {
                let title = extractXMLTag("title", from: entry) ?? ""
                let link = extractAtomLink(from: entry) ?? sourceURL
                let content = extractXMLTag("summary", from: entry) ?? extractXMLTag("content", from: entry) ?? ""

                guard !title.isEmpty else { continue }
                articles.append(ParsedArticle(
                    title: stripHTMLTags(title),
                    content: content.isEmpty ? title : stripHTMLTags(content),
                    url: cleanURL(link),
                    imageURL: nil
                ))
            }
        }
        return articles
    }

    private static func extractRSSImage(from item: String) -> String? {
        // <media:content url="..."/>
        if let range = item.range(of: #"<media:content[^>]*url="([^"]+)"#, options: .regularExpression) {
            let match = String(item[range])
            if let urlRange = match.range(of: #"url="([^"]+)"#, options: .regularExpression) {
                let urlPart = String(match[urlRange])
                return String(urlPart.dropFirst(5).dropLast(1)) // remove url=" and "
            }
        }
        // <enclosure url="..." type="image/..."/>
        if let range = item.range(of: #"<enclosure[^>]*url="([^"]+)"[^>]*type="image"#, options: .regularExpression) {
            let match = String(item[range])
            if let urlRange = match.range(of: #"url="([^"]+)"#, options: .regularExpression) {
                let urlPart = String(match[urlRange])
                return String(urlPart.dropFirst(5).dropLast(1))
            }
        }
        // <image><url>...</url></image>
        if let url = extractXMLTag("url", from: item), url.hasPrefix("http") {
            return url
        }
        return nil
    }

    private static func extractAtomLink(from entry: String) -> String? {
        // <link href="..." rel="alternate"/>
        if let range = entry.range(of: #"<link[^>]*href="([^"]+)"[^>]*/>"#, options: .regularExpression) {
            let match = String(entry[range])
            if let urlRange = match.range(of: #"href="([^"]+)"#, options: .regularExpression) {
                let urlPart = String(match[urlRange])
                return String(urlPart.dropFirst(6).dropLast(1))
            }
        }
        return nil
    }

    // MARK: - Strategy 4: Link-Based Heuristic

    private static func extractFromLinkPatterns(doc: Document, sourceURL: String) throws -> [ParsedArticle] {
        guard let baseURL = URL(string: sourceURL), let host = baseURL.host else { return [] }

        let allLinks = try doc.select("a[href]").array()
        let skipPaths: Set<String> = ["/", "/about", "/contact", "/privacy", "/terms", "/login", "/signup",
                                       "/register", "/blog", "/news", "/faq", "/help", "/search",
                                       "/download", "/signin", "/signup", "/pricing", "/price", "/features",
                                       "/settings", "/dashboard", "/profile", "/cart", "/checkout"]
        let tagPrefixes = ["posts", "tags", "categories", "category", "tag", "topics", "topic", "labels", "label"]

        struct LinkInfo {
            let element: Element
            let href: String
        }

        var internalLinks: [LinkInfo] = []
        var seenPaths: Set<String> = []

        for link in allLinks {
            let href = try link.attr("href")
            guard !href.isEmpty, href != "#", !href.hasPrefix("javascript:"), !href.hasPrefix("mailto:") else { continue }

            let resolved: String
            if href.hasPrefix("http") {
                guard let url = URL(string: href),
                      let linkHost = url.host,
                      (linkHost == host || linkHost == "www.\(host)" || host == "www.\(linkHost)") else { continue }
                resolved = href
            } else if href.hasPrefix("/") {
                resolved = "\(baseURL.scheme ?? "https")://\(host)\(href)"
            } else {
                continue
            }

            guard let url = URL(string: resolved) else { continue }
            let path = url.path

            guard !skipPaths.contains(path) else { continue }
            let segments = path.split(separator: "/").filter { !$0.isEmpty }
            guard let lastSegment = segments.last, lastSegment.count >= 5 else { continue }
            // Skip tag/category pages like /posts/psychology, /tags/news
            if segments.count == 2, let first = segments.first, tagPrefixes.contains(String(first).lowercased()) { continue }
            // Skip static assets
            let ext = (String(lastSegment) as NSString).pathExtension.lowercased()
            if ["css", "js", "png", "jpg", "svg", "ico", "woff", "woff2", "ttf", "pdf"].contains(ext) { continue }

            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)

            internalLinks.append(LinkInfo(element: link, href: resolved))
        }

        guard internalLinks.count >= 2 else { return [] }

        var articles: [ParsedArticle] = []

        for linkInfo in internalLinks {
            // Walk up ancestors to find the "card" container
            // Stop when we find an element that has a heading (h1-h4) — that's the card
            var card: Element = linkInfo.element
            for _ in 0..<5 {
                guard let parent = card.parent() else { break }
                let tag = parent.tagName()
                if ["body", "html", "main", "section", "nav", "header", "footer", "ul", "ol"].contains(tag) { break }
                card = parent
                // If this element has a heading AND an image, it's likely the card
                let hasHeading = try !card.select("h1, h2, h3, h4").isEmpty()
                let hasImage = try !card.select("img").isEmpty()
                if hasHeading && hasImage { break }
            }

            let title = try extractCardTitle(link: linkInfo.element, card: card)
            guard !title.isEmpty, title.count >= 5 else { continue }

            let image = try extractCardImage(card: card, baseURL: sourceURL)
            let content = try extractCardContent(card: card, title: title)

            articles.append(ParsedArticle(
                title: title,
                content: content.isEmpty ? title : content,
                url: linkInfo.href,
                imageURL: image
            ))
        }

        // Deduplicate by title (multiple links can point to same card)
        var seen: Set<String> = []
        var unique: [ParsedArticle] = []
        for article in articles {
            let key = article.title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(article)
        }

        return unique.count >= 2 ? unique : []
    }

    private static func extractCardTitle(link: Element, card: Element) throws -> String {
        for tag in ["h1", "h2", "h3", "h4"] {
            if let heading = try card.select(tag).first() {
                let text = try heading.text()
                if !text.isEmpty && text.count >= 5 { return text }
            }
        }
        let linkText = try link.text()
        if !linkText.isEmpty && linkText.count >= 5 { return linkText }
        let titleAttr = try link.attr("title")
        if !titleAttr.isEmpty { return titleAttr }
        return ""
    }

    private static func extractCardImage(card: Element, baseURL: String) throws -> String? {
        // Try standard img
        for attr in ["data-src", "data-original", "src"] {
            if let img = try card.select("img[\(attr)]").first() {
                let val = try img.attr(attr)
                if !val.isEmpty, let resolved = resolveURL(val, base: baseURL), isValidImageURL(resolved) {
                    return resolved
                }
            }
        }
        // Try srcSet on img
        if let img = try card.select("img[srcset]").first() {
            let srcset = try img.attr("srcset")
            if let best = parseSrcSet(srcset), let resolved = resolveURL(best, base: baseURL) {
                return resolved
            }
        }
        // Try picture > source
        if let source = try card.select("picture source[srcset]").first() {
            let srcset = try source.attr("srcset")
            if let best = parseSrcSet(srcset), let resolved = resolveURL(best, base: baseURL) {
                return resolved
            }
        }
        // Try noscript > img (Next.js pattern)
        if let noscript = try card.select("noscript").first() {
            let noscriptHTML = try noscript.html()
            let noscriptDoc = try SwiftSoup.parseBodyFragment(noscriptHTML)
            if let img = try noscriptDoc.select("img[src]").first() {
                let src = try img.attr("src")
                if let resolved = resolveURL(src, base: baseURL), isValidImageURL(resolved) {
                    return resolved
                }
            }
        }
        // Try background-image in style
        if let styled = try card.select("[style*=background]").first() {
            let style = try styled.attr("style")
            if let url = extractURLFromStyle(style), let resolved = resolveURL(url, base: baseURL) {
                return resolved
            }
        }
        return nil
    }

    private static func extractCardContent(card: Element, title: String) throws -> String {
        let paragraphs = try card.select("p")
        let texts = try paragraphs.array().map { try $0.text() }.filter { !$0.isEmpty && $0 != title && $0.count > 10 }
        if !texts.isEmpty { return texts.joined(separator: " ") }
        let fullText = try card.text()
        let cleaned = fullText.replacingOccurrences(of: title, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 10 ? cleaned : title
    }

    // MARK: - Image Extraction

    private static func extractImage(from element: Element, baseURL: String) throws -> String? {
        let selectors = [
            "img[src].featured-image", "img[src].post-thumbnail",
            "img[src].article-image", "img[data-src]", "img[src]"
        ]
        for selector in selectors {
            if let img = try element.select(selector).first() {
                let src = try img.attr("data-src").isEmpty ? img.attr("src") : img.attr("data-src")
                if let resolved = resolveURL(src, base: baseURL), isValidImageURL(resolved) {
                    return resolved
                }
            }
        }
        // Try srcSet
        if let img = try element.select("img[srcset]").first() {
            let srcset = try img.attr("srcset")
            if let best = parseSrcSet(srcset), let resolved = resolveURL(best, base: baseURL), isValidImageURL(resolved) {
                return resolved
            }
        }
        if let source = try element.select("picture source[srcset]").first() {
            let srcset = try source.attr("srcset")
            if let best = parseSrcSet(srcset), let resolved = resolveURL(best, base: baseURL), isValidImageURL(resolved) {
                return resolved
            }
        }
        return nil
    }

    static func extractOGImage(from doc: Document) throws -> String? {
        if let og = try doc.select("meta[property=og:image]").first() {
            let url = try og.attr("content")
            if !url.isEmpty { return url }
        }
        if let tw = try doc.select("meta[name=twitter:image]").first() {
            let url = try tw.attr("content")
            if !url.isEmpty { return url }
        }
        return nil
    }

    static func fetchOGImage(from articleURL: String) async -> String? {
        do {
            let html = try await NetworkClient.shared.fetch(url: articleURL)
            // Only need <head> for OG tags — strip everything else
            let stripped = stripScriptAndStyle(html)
            let trimmed = stripped.count > 50_000 ? String(stripped.prefix(50_000)) : stripped
            let doc = try SwiftSoup.parse(trimmed)
            let image = try extractOGImage(from: doc)
            doc.empty()
            return image
        } catch {
            return nil
        }
    }

    // MARK: - URL Helpers

    private static func resolveURL(_ src: String, base: String) -> String? {
        if src.hasPrefix("http") { return cleanURL(src) }
        if src.hasPrefix("//") { return cleanURL("https:" + src) }
        guard let baseURL = URL(string: base), let resolved = URL(string: src, relativeTo: baseURL) else { return nil }
        return cleanURL(resolved.absoluteString)
    }

    /// Fix malformed URLs with trailing dot in hostname (e.g. "example.de./path" → "example.de/path")
    private static func cleanURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        // Remove trailing dot from hostname (DNS root dot that breaks Telegram links)
        if let host = components.host, host.hasSuffix(".") {
            components.host = String(host.dropLast())
        }
        return components.string ?? url
    }

    private static func isValidImageURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        // Exclude tracking pixels and icons
        if lower.contains("1x1") || lower.contains("pixel") || lower.contains("tracking") { return false }
        if lower.contains("logo") || lower.contains("icon") || lower.contains("avatar") { return false }
        if lower.contains("favicon") || lower.contains("cookie") || lower.contains("banner") { return false }

        let imageExts = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"]
        if imageExts.contains(where: { lower.contains($0) }) { return true }
        // Next.js image optimization
        if lower.contains("/_next/image") { return true }
        // Common image paths
        if lower.contains("/image") || lower.contains("/uploads") || lower.contains("/media/") { return true }
        // CDN providers
        if lower.contains("cloudinary.com") || lower.contains("imgix.net") { return true }
        // WordPress
        if lower.contains("wp-content/uploads") { return true }

        return false
    }

    static func parseSrcSet(_ srcset: String) -> String? {
        let candidates = srcset.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { entry -> (url: String, width: Int)? in
                let parts = entry.components(separatedBy: " ").filter { !$0.isEmpty }
                guard let url = parts.first, !url.isEmpty else { return nil }
                let width = parts.last.flatMap { Int($0.replacingOccurrences(of: "w", with: "")) } ?? 0
                return (url, width)
            }
        return candidates.max(by: { $0.width < $1.width })?.url ?? candidates.first?.url
    }

    private static func extractURLFromStyle(_ style: String) -> String? {
        guard let start = style.range(of: "url(") else { return nil }
        let after = style[start.upperBound...]
        let cleaned = after.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        guard let end = cleaned.firstIndex(of: ")") else { return nil }
        let url = String(cleaned[cleaned.startIndex..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        return url.isEmpty ? nil : url
    }

    /// Strip CDN resize parameters to get full-size image
    static func fullSizeImageURL(_ url: String) -> String {
        // Don't strip params from Next.js image proxy — it needs url + w params
        if url.contains("/_next/image") { return url }
        guard var components = URLComponents(string: url) else { return url }
        let resizeParams: Set<String> = ["w", "h", "q", "fit", "crop", "dpr", "resize", "width", "height", "quality", "size"]
        if let items = components.queryItems {
            let filtered = items.filter { !resizeParams.contains($0.name.lowercased()) }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.string ?? url
    }

    // MARK: - Text Extraction

    private static func extractTitle(from element: Element, doc: Document) throws -> String {
        for tag in ["h1", "h2", "h3", ".title", ".headline"] {
            if let el = try element.select(tag).first() {
                let text = try el.text()
                if !text.isEmpty { return text }
            }
        }
        if let link = try element.select("a").first() {
            let text = try link.text()
            if !text.isEmpty { return text }
        }
        return try element.text().components(separatedBy: ".").first ?? ""
    }

    private static func extractContent(from element: Element) throws -> String {
        let paragraphs = try element.select("p")
        if !paragraphs.isEmpty() {
            return try paragraphs.array().map { try $0.text() }.joined(separator: " ")
        }
        return try element.text()
    }

    private static func extractLink(from element: Element, baseURL: String) throws -> String? {
        guard let link = try element.select("a[href]").first() else { return nil }
        let href = try link.attr("href")
        if href.hasPrefix("http") { return href }
        guard let base = URL(string: baseURL), let resolved = URL(string: href, relativeTo: base) else { return nil }
        return resolved.absoluteString
    }

    private static func extractMainContent(from doc: Document) throws -> String {
        try doc.select("script, style, nav, footer, header, aside").remove()
        for selector in ["main", "#content", ".content", "#main", ".main", "article"] {
            if let main = try doc.select(selector).first() {
                let text = try main.text()
                if text.count > 100 { return text }
            }
        }
        return try doc.body()?.text() ?? ""
    }

    static func stripHTMLTags(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return html }
        let text = (try? doc.text()) ?? html
        doc.empty()
        return text
    }

    // MARK: - YouTube RSS Parsing

    static func parseYouTubeRSS(_ xml: String, channelId: String) -> [ParsedArticle] {
        var articles: [ParsedArticle] = []
        let entries = xml.components(separatedBy: "<entry>").dropFirst()

        for entry in entries {
            guard let title = extractXMLTag("title", from: entry),
                  let videoId = extractXMLTag("yt:videoId", from: entry) else { continue }

            let content = extractXMLTag("media:description", from: entry) ?? title
            let thumbnail = "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg"
            let url = "https://www.youtube.com/watch?v=\(videoId)"

            articles.append(ParsedArticle(
                title: title,
                content: content,
                url: url,
                imageURL: thumbnail
            ))
        }
        return articles
    }

    static func extractXMLTag(_ tag: String, from text: String) -> String? {
        let patterns = ["<\(tag)>", "<\(tag) "]
        for pattern in patterns {
            guard let startRange = text.range(of: pattern) else { continue }
            let afterTag: String.Index
            if pattern.hasSuffix(" ") {
                guard let closeAngle = text.range(of: ">", range: startRange.upperBound..<text.endIndex) else { continue }
                afterTag = closeAngle.upperBound
            } else {
                afterTag = startRange.upperBound
            }
            guard let endRange = text.range(of: "</\(tag)>", range: afterTag..<text.endIndex) else { continue }
            let value = String(text[afterTag..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
