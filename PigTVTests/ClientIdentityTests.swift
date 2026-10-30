import XCTest
@testable import PigTV

// #19 (Apple 84): every API request says which app build, OS and device it comes from (`X-PigTV-Client`), so the
// server's Status and Settings → Devices can tell the Apple TV from the iPad and see the build. Before 84 nothing did.

private final class HeaderProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [String: String?] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen[request.url?.path ?? ""] = request.value(forHTTPHeaderField: "X-PigTV-Client")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":"ABC234","expiresInSec":600}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ClientIdentityTests: XCTestCase {
    func testHeaderFormat() {
        XCTAssertEqual(ClientIdentity.header(build: "84", osName: "tvOS",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0), model: "AppleTV14,1"),
            "PigTV/84 (tvOS 26.1; AppleTV14,1)")
        XCTAssertEqual(ClientIdentity.header(build: "84", osName: "iPadOS",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 2), model: "iPad13,4"),
            "PigTV/84 (iPadOS 26.0.2; iPad13,4)")
    }

    func testCurrentNamesThisBuildAndADevice() throws {
        let build = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertTrue(ClientIdentity.current.hasPrefix("PigTV/\(build) ("), ClientIdentity.current)
        let model = ClientIdentity.modelIdentifier()
        XCTAssertTrue(model.contains(","), "a model identifier such as AppleTV14,1, not the simulator's CPU: \(model)")
        XCTAssertTrue(ClientIdentity.current.hasSuffix("; \(model))"), ClientIdentity.current)
    }

    func testEveryAPIRequestCarriesIt() async throws {
        HeaderProtocol.seen = [:]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderProtocol.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        _ = try await client.response("devices/pair/start", method: "POST", body: ["name": "PigTV tvOS"])
        _ = try await client.response("library/guide")
        XCTAssertEqual(HeaderProtocol.seen["/api/devices/pair/start"], ClientIdentity.current)
        XCTAssertEqual(HeaderProtocol.seen["/api/library/guide"], ClientIdentity.current)
    }
}
