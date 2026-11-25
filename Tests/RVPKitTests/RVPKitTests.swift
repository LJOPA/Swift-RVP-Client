import XCTest
@testable import RVPKit

final class RVPKitTests: XCTestCase {
    let account = RVPAccount(signInName: "luke@enterprise.bahamut.zone")

    func testAccountDefaults() {
        XCTAssertEqual(account.server, "im.enterprise.bahamut.zone")
        XCTAssertEqual(account.principal.absoluteString,
                       "http://im.enterprise.bahamut.zone/instmsg/aliases/luke")
        XCTAssertEqual(account.principal(forSignInName: "kate")?.absoluteString,
                       "http://im.enterprise.bahamut.zone/instmsg/aliases/kate")
        XCTAssertEqual(account.signInName(for: URL(string: "http://im.enterprise.bahamut.zone/instmsg/aliases/kate")!),
                       "kate@enterprise.bahamut.zone")
        XCTAssertEqual(account.signInName(for: URL(string:
            "http://imhome1.domain2.com/instmsg/local/im.domain2.com/instmsg/aliases/kevinf")!),
            "kevinf@domain2.com")
    }

    func testMimeRoundTrip() {
        let p = IMPayload(kind: .text("hello\nworld"), sessionID: "abc")
        let s = p.serialize()
        XCTAssertTrue(s.contains("X-MMS-IM-Format: FN=MS%20Shell%20Dlg"))
        XCTAssertTrue(s.contains("Session-Id: {abc}\r\n\r\nhello\r\nworld"))
        let back = IMPayload.parse(s)
        XCTAssertEqual(back?.sessionID, "abc")
        XCTAssertEqual(back?.kind, .text("hello\nworld"))
    }

    func testTypingParse() {
        let raw = "MIME-Version: 1.0\r\nContent-Type: text/x-msmsgscontrol; charset=UTF-8\r\nTypingUser: kate@x\r\nSession-Id: {1-2}\r\n\r\n"
        XCTAssertEqual(IMPayload.parse(raw)?.kind, .typing(user: "kate@x"))
    }

    func testIncomingMessage() throws {
        let xml = """
        <?xml version="1.0"?>
        <r:notification xmlns:d="DAV:" xmlns:r="http://schemas.microsoft.com/rvp/">
        <r:message>
        <r:notification-from><r:contact><d:href>http://im.enterprise.bahamut.zone/instmsg/aliases/kate</d:href><r:description>Kate</r:description></r:contact></r:notification-from>
        <r:notification-to><r:contact><d:href>http://im.enterprise.bahamut.zone/instmsg/aliases/luke</d:href></r:contact></r:notification-to>
        <r:msgbody><r:mime-data><![CDATA[MIME-Version: 1.0\r
        Content-Type: text/plain; charset=UTF-8\r
        Session-Id: {s1}\r
        \r
        hi there]]></r:mime-data></r:msgbody>
        </r:message>
        </r:notification>
        """
        let items = try RVPParse.notifications(Data(xml.utf8))
        guard case .message(let from, _, let payload)? = items.first else { return XCTFail("no message") }
        XCTAssertEqual(from.description, "Kate")
        XCTAssertEqual(payload.sessionID, "s1")
        XCTAssertEqual(payload.kind, .text("hi there"))
    }

    func testIncomingPresence() throws {
        let xml = """
        <?xml version="1.0"?>
        <Z:notification xmlns:D="DAV:" xmlns:Z="http://schemas.microsoft.com/rvp/">
          <Z:propnotification>
            <Z:notification-from><Z:contact><D:href>http://im.example.com/instmsg/aliases/kate</D:href></Z:contact></Z:notification-from>
            <D:propertyupdate><D:set><D:prop><Z:state><Z:busy/></Z:state></D:prop></D:set></D:propertyupdate>
          </Z:propnotification>
        </Z:notification>
        """
        let items = try RVPParse.notifications(Data(xml.utf8))
        guard case .presence(_, let state)? = items.first else { return XCTFail("no presence") }
        XCTAssertEqual(state, .busy)
    }

    func testMultistatusLeasedState() {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:" xmlns:Z="http://schemas.microsoft.com/rvp/">
          <D:response><D:href>http://im.example.com/instmsg/aliases/stevem</D:href>
            <D:propstat><D:prop>
              <Z:state><Z:leased-value><Z:value><Z:on-phone/></Z:value><Z:default-value><Z:offline/></Z:default-value><D:timeout>1200</D:timeout></Z:leased-value></Z:state>
              <Z:view-id>3577</Z:view-id>
              <D:displayname>Steve Morgan</D:displayname>
            </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let r = RVPParse.multistatus(Data(xml.utf8))
        XCTAssertEqual(r.state, .onPhone)
        XCTAssertEqual(r.viewID, "3577")
        XCTAssertEqual(r.displayName, "Steve Morgan")
    }

    func testPresenceBodyIsWellFormed() throws {
        let body = RVPBody.presence(.away, lease: 1200, viewID: "7")
        let root = try RVPXMLParser.parse(body)
        XCTAssertEqual(root.name, "propertyupdate")
        XCTAssertNotNil(root.first("away"))
        XCTAssertEqual(root.first("view-id")?.trimmedText, "7")
    }

    func testNotificationBodyIsWellFormed() throws {
        let body = RVPBody.notification(
            from: RVPContactRef(principal: account.principal, description: "Luke <&>"),
            to: [RVPContactRef(principal: URL(string: "http://im.x/instmsg/aliases/kate")!)],
            payload: IMPayload(kind: .text("a ]]> b"), sessionID: "s"))
        let items = try RVPParse.notifications(body)
        guard case .message(let from, _, let p)? = items.first else { return XCTFail() }
        XCTAssertEqual(from.description, "Luke <&>")
        XCTAssertEqual(p.kind, .text("a ]]> b"))
    }

    func testCallbackRequestParsing() {
        let raw = "NOTIFY / HTTP/1.1\r\nContent-Length: 5\r\nHost: x\r\n\r\nhelloNEXT"
        guard case let (req?, consumed, _)? = RVPCallbackServer.parseRequest(Data(raw.utf8)) else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(req.method, "NOTIFY")
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), "hello")
        XCTAssertEqual(consumed, raw.utf8.count - 4)
    }
}
