import Foundation
import Testing

@testable import Toolsmith

@Suite("SSEParser")
struct SSEParserTests {
    @Test("Single data line + blank emits one event with default name")
    func singleData() {
        var parser = SSEParser()
        let events = parser.feed(text: "data: hello\n\n")
        #expect(events == [SSEEvent(event: "message", data: "hello")])
    }

    @Test("Multiple data lines join with newline")
    func multipleData() {
        var parser = SSEParser()
        let events = parser.feed(text: "data: line1\ndata: line2\ndata: line3\n\n")
        #expect(events == [SSEEvent(event: "message", data: "line1\nline2\nline3")])
    }

    @Test("Explicit event name is carried")
    func explicitEvent() {
        var parser = SSEParser()
        let events = parser.feed(text: "event: endpoint\ndata: /messages/abc\n\n")
        #expect(events == [SSEEvent(event: "endpoint", data: "/messages/abc")])
    }

    @Test("Comment lines are ignored")
    func commentsIgnored() {
        var parser = SSEParser()
        let events = parser.feed(text: ": this is a comment\ndata: hi\n\n")
        #expect(events == [SSEEvent(event: "message", data: "hi")])
    }

    @Test("id is sticky across subsequent events until replaced")
    func stickyId() {
        var parser = SSEParser()
        let events = parser.feed(text: """
            id: 1
            data: a

            data: b

            id: 2
            data: c


            """)
        #expect(events == [
            SSEEvent(event: "message", data: "a", id: "1"),
            SSEEvent(event: "message", data: "b", id: "1"),
            SSEEvent(event: "message", data: "c", id: "2"),
        ])
    }

    @Test("retry parses as integer")
    func retry() {
        var parser = SSEParser()
        let events = parser.feed(text: "retry: 5000\ndata: x\n\n")
        #expect(events == [SSEEvent(event: "message", data: "x", retry: 5000)])
    }

    @Test("Field without colon treats whole line as name")
    func fieldWithoutColon() {
        var parser = SSEParser()
        let events = parser.feed(text: "data\ndata: x\n\n")
        // First "data" has no colon → name="data", value="" → adds "" then "x"
        #expect(events == [SSEEvent(event: "message", data: "\nx")])
    }

    @Test("Leading space after colon is stripped")
    func leadingSpaceStripped() {
        var parser = SSEParser()
        let one = parser.feed(text: "data: with space\n\n")
        let two = parser.feed(text: "data:no space\n\n")
        #expect(one == [SSEEvent(event: "message", data: "with space")])
        #expect(two == [SSEEvent(event: "message", data: "no space")])
    }

    @Test("Empty record dispatches no event")
    func emptyRecord() {
        var parser = SSEParser()
        let events = parser.feed(text: "\n\n\n")
        #expect(events.isEmpty)
    }

    @Test("Event resets after dispatch but id sticks")
    func eventResetsAfterDispatch() {
        var parser = SSEParser()
        let events = parser.feed(text: """
            event: foo
            id: 1
            data: first

            data: second


            """)
        #expect(events == [
            SSEEvent(event: "foo", data: "first", id: "1"),
            SSEEvent(event: "message", data: "second", id: "1"),
        ])
    }

    @Test("Unknown fields are ignored")
    func unknownFieldsIgnored() {
        var parser = SSEParser()
        let events = parser.feed(text: "weird: x\ndata: y\n\n")
        #expect(events == [SSEEvent(event: "message", data: "y")])
    }

    @Test("Incremental feed across multiple calls")
    func incrementalFeed() {
        var parser = SSEParser()
        #expect(parser.feed(line: "event: ping") == nil)
        #expect(parser.feed(line: "data: pong") == nil)
        let event = parser.feed(line: "")
        #expect(event == SSEEvent(event: "ping", data: "pong"))
    }
}
