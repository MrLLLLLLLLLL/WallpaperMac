import Foundation

/// Fetches anonymous Workshop item metadata from Steam's public details
/// endpoint. No API key, no login — only published file ids.
public actor WorkshopMetadataClient {
    public static let endpoint = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

    private let session: URLSession
    private let maxAttempts: Int

    public init(session: URLSession = .shared, maxAttempts: Int = 3) {
        self.session = session
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Single-item lookup. Unavailable items throw `.unavailable`.
    public func fetch(itemID: String) async throws -> WorkshopMetadata {
        let rows = try await request(itemIDs: [itemID])
        guard let first = rows.first else {
            throw WorkshopMetadataError.unavailable
        }
        guard first.isAvailable else {
            throw WorkshopMetadataError.unavailable
        }
        return first
    }

    /// Batched details lookup for browse tiles. Ids Steam refuses (removed,
    /// wrong app) are omitted rather than failing the whole page. Transport
    /// failures still throw after retries.
    public func fetchBatch(itemIDs: [String]) async throws -> [WorkshopMetadata] {
        let numeric = itemIDs.filter {
            !$0.isEmpty && $0.count <= 20 && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }
        guard !numeric.isEmpty else { return [] }

        var results: [WorkshopMetadata] = []
        var index = 0
        while index < numeric.count {
            let chunk = Array(numeric[index..<min(index + 50, numeric.count)])
            index += chunk.count
            let rows = try await request(itemIDs: chunk)
            results.append(contentsOf: rows.filter(\.isAvailable))
        }
        return results
    }

    private func request(itemIDs: [String]) async throws -> [WorkshopMetadata] {
        var lastError: WorkshopMetadataError = .network("未知错误")
        for attempt in 1...maxAttempts {
            do {
                return try await requestOnce(itemIDs: itemIDs)
            } catch let error as WorkshopMetadataError {
                lastError = error
                if case .unavailable = error { throw error }
                if case .emptyResponse = error { throw error }
                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1)) * 0.75
                    try? await Task.sleep(for: .milliseconds(Int64(delay * 1000)))
                }
            } catch {
                lastError = .network(error.localizedDescription)
                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1)) * 0.75
                    try? await Task.sleep(for: .milliseconds(Int64(delay * 1000)))
                }
            }
        }
        throw lastError
    }

    private func requestOnce(itemIDs: [String]) async throws -> [WorkshopMetadata] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["itemcount=\(itemIDs.count)"]
        for (index, id) in itemIDs.enumerated() {
            fields.append("publishedfileids[\(index)]=\(id)")
        }
        request.httpBody = Data(fields.joined(separator: "&").utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WorkshopMetadataError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WorkshopMetadataError.httpStatus(http.statusCode)
        }
        let rows = try WorkshopMetadataParser.parseAll(data: data)
        guard !rows.isEmpty else {
            throw WorkshopMetadataError.emptyResponse
        }
        return rows
    }
}
