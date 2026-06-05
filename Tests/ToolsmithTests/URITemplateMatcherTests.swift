import Foundation
import Testing

@testable import Toolsmith

@Suite("URITemplateMatcher")
struct URITemplateMatcherTests {
    @Test("Single trailing placeholder captures the suffix")
    func singleTrailingPlaceholder() throws {
        let matcher = try URITemplateMatcher.compile("mail://attachment/{id}")
        #expect(matcher.match("mail://attachment/abc123") == ["id": "abc123"])
        #expect(matcher.match("mail://attachment/") == nil)  // empty capture rejected
        #expect(matcher.match("mail://message/abc") == nil)
    }

    @Test("Placeholder followed by literal is bounded correctly")
    func placeholderBoundedByLiteral() throws {
        let matcher = try URITemplateMatcher.compile("a/{x}/b")
        #expect(matcher.match("a/hello/b") == ["x": "hello"])
        #expect(matcher.match("a/hello/b/extra") == nil)
        #expect(matcher.match("a//b") == nil)
    }

    @Test("Multiple placeholders capture independently")
    func multiplePlaceholders() throws {
        let matcher = try URITemplateMatcher.compile("k8s://{ns}/pods/{name}")
        #expect(matcher.match("k8s://default/pods/web-1") == ["ns": "default", "name": "web-1"])
        #expect(matcher.match("k8s://default/pods/") == nil)
    }

    @Test("Non-matching URI returns nil")
    func nonMatching() throws {
        let matcher = try URITemplateMatcher.compile("file://{path}")
        #expect(matcher.match("http://example.com") == nil)
    }

    @Test("Captured values are percent-decoded")
    func percentDecoding() throws {
        let matcher = try URITemplateMatcher.compile("mail://attachment/{id}")
        #expect(matcher.match("mail://attachment/abc%20123") == ["id": "abc 123"])
    }

    @Test("Empty placeholder {} fails to compile")
    func emptyPlaceholderError() {
        #expect(throws: URITemplateMatcher.CompileError.emptyPlaceholder) {
            _ = try URITemplateMatcher.compile("a/{}/b")
        }
    }

    @Test("Unterminated placeholder fails to compile")
    func unterminatedError() {
        #expect(throws: URITemplateMatcher.CompileError.unterminatedPlaceholder) {
            _ = try URITemplateMatcher.compile("a/{id")
        }
        #expect(throws: URITemplateMatcher.CompileError.unterminatedPlaceholder) {
            _ = try URITemplateMatcher.compile("a/id}")
        }
    }

    @Test("Nested brace fails to compile")
    func nestedBraceError() {
        #expect(throws: URITemplateMatcher.CompileError.nestedBrace) {
            _ = try URITemplateMatcher.compile("a/{x{y}}/b")
        }
    }

    @Test("Duplicate placeholder names fail to compile")
    func duplicateError() {
        #expect(throws: URITemplateMatcher.CompileError.duplicatePlaceholder("id")) {
            _ = try URITemplateMatcher.compile("a/{id}/b/{id}")
        }
    }

    @Test("Invalid placeholder name fails to compile")
    func invalidNameError() {
        #expect(throws: URITemplateMatcher.CompileError.invalidPlaceholderName("my-id")) {
            _ = try URITemplateMatcher.compile("a/{my-id}/b")
        }
        #expect(throws: URITemplateMatcher.CompileError.invalidPlaceholderName("1abc")) {
            _ = try URITemplateMatcher.compile("a/{1abc}/b")
        }
    }

    @Test("Reserved placeholder name `uri` is rejected")
    func reservedNameError() {
        #expect(throws: URITemplateMatcher.CompileError.reservedPlaceholderName("uri")) {
            _ = try URITemplateMatcher.compile("scheme://{uri}")
        }
    }

    @Test("Template without placeholders matches by literal equality")
    func literalOnly() throws {
        let matcher = try URITemplateMatcher.compile("file:///etc/hosts")
        #expect(matcher.match("file:///etc/hosts") == [:])
        #expect(matcher.match("file:///etc/passwd") == nil)
    }
}
