# RVP Messenger

Native SwiftUI client for Microsoft Exchange 2000 Instant Messaging (RVP), for macOS 13+ and iOS 16+.

- `Sources/RVPKit`: protocol library (Swift package). HTTP with NTLM via URLSession, callback listener via Network.framework, XML/MIME encoding.
- `App`: SwiftUI app shared by macOS and iOS. Sign-in, contact list with presence, one-to-one chat, typing indicators, status picker, protocol log.
- `PROTOCOL.md`: wire format notes, with every guess marked.

**Status:** v0.1, written without access to a Swift toolchain or the server. Expect a round of compile fixes on first build, then protocol fixes against the real server.

## Build

Requires Xcode 15 or later.

```sh
brew install xcodegen
cd rvp-client
xcodegen generate
open RVPMessenger.xcodeproj
```

Select the RVPMessenger scheme, then a Mac or iOS destination. Set your signing team under Signing & Capabilities.

Library tests (parsing and encoding only, no server needed):

```sh
swift test
```

## First run

1. Sign-in name: `alias@enterprise.bahamut.zone`. The server defaults to `im.enterprise.bahamut.zone`.
2. If NTLM needs the Windows domain, put `DOMAIN\alias` under Advanced → Windows user.
3. The device must be on the same network as the Exchange server, because the server connects back to the device to deliver messages. On macOS, allow incoming connections if the firewall asks. On iOS, allow Local Network access.
4. If something fails, open the menu → Protocol Log and send its contents back.

## Known limits

- iOS receives messages only while the app is open (the server must reach a live listener).
- No SRV lookup, ACL editing, group chat or file transfer yet.
- Contacts are stored on the device. Exchange 2000 does not keep a server-side contact list.
