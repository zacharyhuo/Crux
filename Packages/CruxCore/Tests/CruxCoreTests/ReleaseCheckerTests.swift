import Foundation
import Testing

@testable import CruxCore

struct ReleaseCheckerTests {
    @Test
    func returnsOnlyANewerPublishedGitHubRelease() async throws {
        let payload = Data("""
            {
              "tag_name": "v1.2.0",
              "html_url": "https://github.com/zacharyhuo/Crux/releases/tag/v1.2.0",
              "draft": false,
              "prerelease": false
            }
            """.utf8)
        let checker = GitHubReleaseChecker(httpClient: ReleaseHTTPClient(data: payload))

        let update = try await checker.newerRelease(than: "1.1.9")
        let current = try await checker.newerRelease(than: "1.2.0")

        #expect(update?.version == "1.2.0")
        #expect(update?.pageURL.absoluteString.hasSuffix("v1.2.0") == true)
        #expect(current == nil)
    }

    @Test
    func ignoresDraftsPrereleasesAndNonHTTPSReleasePages() async throws {
        for payload in [
            "{\"tag_name\":\"v2.0.0\",\"html_url\":\"https://example.com/v2\",\"draft\":true,\"prerelease\":false}",
            "{\"tag_name\":\"v2.0.0-beta\",\"html_url\":\"https://example.com/v2\",\"draft\":false,\"prerelease\":true}",
            "{\"tag_name\":\"v2.0.0\",\"html_url\":\"http://example.com/v2\",\"draft\":false,\"prerelease\":false}",
        ] {
            let checker = GitHubReleaseChecker(httpClient: ReleaseHTTPClient(data: Data(payload.utf8)))
            #expect(try await checker.newerRelease(than: "1.0.0") == nil)
        }
    }
}

private struct ReleaseHTTPClient: HTTPClient {
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}
