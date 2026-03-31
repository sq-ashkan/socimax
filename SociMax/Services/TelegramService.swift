import Foundation

struct TelegramResponse: Decodable {
    let ok: Bool
    let result: TelegramMessage?
}

struct TelegramMessage: Decodable {
    let messageId: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

final class TelegramService {
    static let shared = TelegramService()
    private let baseURL = "https://api.telegram.org/bot"

    private init() {}

    func sendPhoto(
        botToken: String,
        channelId: String,
        photoURL: String,
        caption: String
    ) async throws -> Int? {
        let url = "\(baseURL)\(botToken)/sendPhoto"
        let response: TelegramResponse = try await NetworkClient.shared.postJSON(
            url: url,
            body: [
                "chat_id": channelId,
                "photo": photoURL,
                "caption": caption,
                "parse_mode": "HTML"
            ]
        )
        guard response.ok else { return nil }
        return response.result?.messageId
    }

    func sendMessage(
        botToken: String,
        channelId: String,
        text: String
    ) async throws -> Int? {
        let url = "\(baseURL)\(botToken)/sendMessage"
        let response: TelegramResponse = try await NetworkClient.shared.postJSON(
            url: url,
            body: [
                "chat_id": channelId,
                "text": text,
                "parse_mode": "HTML"
            ]
        )
        guard response.ok else { return nil }
        return response.result?.messageId
    }

    func sendVideo(
        botToken: String,
        channelId: String,
        videoFile: URL,
        caption: String,
        thumbnail: URL? = nil
    ) async throws -> Int? {
        let url = URL(string: "\(baseURL)\(botToken)/sendVideo")!

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // 5 min for large uploads

        var body = Data()

        // chat_id
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(channelId)\r\n".data(using: .utf8)!)

        // caption
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        // parse_mode
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"parse_mode\"\r\n\r\n".data(using: .utf8)!)
        body.append("HTML\r\n".data(using: .utf8)!)

        // supports_streaming
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"supports_streaming\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)

        // thumbnail (JPEG image)
        if let thumbnail, let thumbData = try? Data(contentsOf: thumbnail) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"thumbnail\"; filename=\"thumb.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(thumbData)
            body.append("\r\n".data(using: .utf8)!)
        }

        // video file
        let videoData = try Data(contentsOf: videoFile)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(videoFile.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(videoData)
        body.append("\r\n".data(using: .utf8)!)

        // close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TelegramResponse.self, from: data)
        guard response.ok else { return nil }
        return response.result?.messageId
    }

    func testBot(token: String) async -> Bool {
        guard !token.isEmpty else { return false }
        let url = "\(baseURL)\(token)/getMe"
        guard let urlObj = URL(string: url) else { return false }
        do {
            let (data, _) = try await URLSession.shared.data(from: urlObj)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json["ok"] as? Bool ?? false
            }
            return false
        } catch {
            return false
        }
    }

    func editMessageText(
        botToken: String,
        channelId: String,
        messageId: Int,
        text: String
    ) async -> Bool {
        let url = "\(baseURL)\(botToken)/editMessageText"
        do {
            let _: TelegramResponse = try await NetworkClient.shared.postJSON(
                url: url,
                body: [
                    "chat_id": channelId,
                    "message_id": messageId,
                    "text": text,
                    "parse_mode": "HTML"
                ]
            )
            return true
        } catch {
            FileLogger.shared.log("[Telegram] editMessageText failed: \(error.localizedDescription)")
            return false
        }
    }

    func editMessageCaption(
        botToken: String,
        channelId: String,
        messageId: Int,
        caption: String
    ) async -> Bool {
        let url = "\(baseURL)\(botToken)/editMessageCaption"
        do {
            let _: TelegramResponse = try await NetworkClient.shared.postJSON(
                url: url,
                body: [
                    "chat_id": channelId,
                    "message_id": messageId,
                    "caption": caption,
                    "parse_mode": "HTML"
                ]
            )
            return true
        } catch {
            FileLogger.shared.log("[Telegram] editMessageCaption failed: \(error.localizedDescription)")
            return false
        }
    }

    func getMessageViews(botToken: String, channelId: String, messageId: Int) async -> Int? {
        return nil
    }
}
