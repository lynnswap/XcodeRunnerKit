import Foundation
import Testing
@testable import XcodeRunnerHost

@MainActor
struct GitHubAppSetupTests {
    @Test(arguments: [nil, "", "sample-org"] as [String?])
    func manifestRegistrationReturnsAppSettingsAndReusesCallbackPort(organization: String?) async throws {
        let setup = GitHubAppSetup(transport: { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://api.github.com/app-manifests/manifest-code/conversions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let data = Data(#"{"client_id":"client-id","slug":"my-host","client_secret":"client-secret","pem":"unused","webhook_secret":"unused"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        let name = "Host \"One\" <test> & 'two'"
        let registration = try await setup.begin(name: name, organization: organization)
        defer { registration.cancel() }
        let (page, response) = try await URLSession.shared.data(from: registration.startURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let html = String(decoding: page, as: UTF8.self)
        let action = try attribute("action", in: html)
        let destination = try #require(URLComponents(string: action))
        #expect(destination.host == "github.com")
        #expect(destination.path == (organization == "sample-org"
            ? "/organizations/sample-org/settings/apps/new" : "/settings/apps/new"))
        let state = try #require(destination.queryItems?.first(where: { $0.name == "state" })?.value)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(try attribute("value", in: html).utf8)) as? [String: Any])
        #expect(manifest["name"] as? String == name)
        #expect(manifest["public"] as? Bool == false)
        #expect(manifest["redirect_url"] as? String == registration.callbackURL.absoluteString)
        #expect(manifest["callback_urls"] as? [String] == [registration.callbackURL.absoluteString])
        #expect(manifest["default_permissions"] as? [String: String] == ["administration": "write", "metadata": "read"])
        #expect((manifest["hook_attributes"] as? [String: Any])?["active"] as? Bool == false)
        #expect(!html.contains(name))

        let completion = Task { try await registration.complete() }
        let callback = registration.callbackURL.appending(queryItems: [
            URLQueryItem(name: "code", value: "manifest-code"), URLQueryItem(name: "state", value: state),
        ])
        let (_, returned) = try await URLSession.shared.data(from: callback)
        #expect((returned as? HTTPURLResponse)?.statusCode == 200)
        let app = try await completion.value
        #expect(app.clientID == "client-id")
        #expect(app.slug == "my-host")
        #expect(app.clientSecret == "client-secret")
        #expect(app.callbackURL == registration.callbackURL)

        let next = try await GitHubBrowserCallback.start(callbackURL: app.callbackURL)
        #expect(next.callbackURL == app.callbackURL)
        next.cancel()
    }

    @Test func callbackRejectsAStateFromAnotherRequest() async throws {
        let callback = try await GitHubBrowserCallback.start()
        defer { callback.cancel() }
        let completion = Task { try await callback.waitForCode() }
        let url = callback.callbackURL.appending(queryItems: [
            URLQueryItem(name: "code", value: "untrusted-code"), URLQueryItem(name: "state", value: "other-request"),
        ])
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        await #expect(throws: GitHubBrowserCallbackError.self) { try await completion.value }
    }

    @Test func cancellingAWaitReleasesTheCallbackPort() async throws {
        let callback = try await GitHubBrowserCallback.start()
        let completion = Task { try await callback.waitForCode() }
        completion.cancel()
        await #expect(throws: CancellationError.self) { try await completion.value }
        let next = try await GitHubBrowserCallback.start(callbackURL: callback.callbackURL)
        #expect(next.callbackURL == callback.callbackURL)
        next.cancel()
    }

    @Test func failedManifestConversionPreservesTheGitHubError() async throws {
        let setup = GitHubAppSetup(transport: { request in
            (Data(#"{"message":"Registration expired"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        let registration = try await setup.begin()
        defer { registration.cancel() }
        let (page, _) = try await URLSession.shared.data(from: registration.startURL)
        let action = try attribute("action", in: String(decoding: page, as: UTF8.self))
        let state = try #require(URLComponents(string: action)?.queryItems?.first(where: { $0.name == "state" })?.value)
        let completion = Task { try await registration.complete() }
        _ = try await URLSession.shared.data(from: registration.callbackURL.appending(queryItems: [
            URLQueryItem(name: "code", value: "expired-code"), URLQueryItem(name: "state", value: state),
        ]))
        do {
            _ = try await completion.value
            Issue.record("Manifest conversion unexpectedly succeeded")
        } catch let error as GitHubError {
            guard case let .response(status, message) = error else { throw error }
            #expect(status == 404)
            #expect(message == "Registration expired")
        }
    }

    private func attribute(_ name: String, in html: String) throws -> String {
        let prefix = "\(name)=\""
        let start = try #require(html.range(of: prefix)?.upperBound)
        let end = try #require(html[start...].firstIndex(of: "\""))
        return String(html[start..<end])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
