# RVP protocol notes (Exchange 2000 Instant Messaging)

Sources, in order of trust:

1. **librvp 0.9.7** (Pidgin/Gaim plugin by Waider et al., GPL). Used against real Exchange 2000 servers, so its wire format is the best evidence available. Only studied, no code copied.
2. **draft-osborne-rvp-00** (June 2000, expired Internet-Draft from Microsoft). Describes Exchange 2000 IM. Several XML examples in it are malformed.
3. Guesses, marked **GUESS** below and in code comments.

## Confirmed against Luke's server (2026-11-25, rvp-probe run 2)

Server: Microsoft-IIS/5.0 on Exchange 2000.

- `RVP-Notifications-Version: 0.2` is what the server sends back.
- The IM virtual server is bound to the host header `im.enterprise.bahamut.zone`. Requests to the bare IP reach the default site and get `501 Not Implemented`, so clients must resolve and use the hostname.
- The domain's Windows 2000 DNS answers FORMERR to EDNS queries, so modern resolvers fail unless EDNS is off or the name is pinned.
- Self SUBSCRIBE (pragma/notify + Call-Back) → 200 with `Subscription-Id` and `Subscription-Lifetime: 14000`.
- PROPPATCH leased presence → 207 echoing the state, plus `<r:view-id>`.
- PROPFIND `d:displayname` → 207.
- SUBSCRIPTIONS → 200 with `<r:subscriptions/>`.
- PROPPATCH offline (short form with view-id) → 207. UNSUBSCRIBE self → 200.
- NTLM through URLSession signs in with `ENTERPRISE\user`. The trace showed no explicit 401 round trip, so URLSession handled the handshake internally.
- Responses carry `Connection: close`.

Not yet tested: contact SUBSCRIBE, outgoing and incoming NOTIFY, and callback delivery across subnets.

## Model

RVP is HTTP/1.1 plus WebDAV-style methods with XML bodies. Every user is a node:

```
http://im.<domain>/instmsg/aliases/<alias>
```

Delivery is **push by callback**. The client runs its own HTTP listener and tells the server where it is in a `Call-Back` header. The server then opens TCP connections *to the client* and sends `NOTIFY` requests. The client must therefore be reachable from the Exchange server (LAN or VPN). iOS can only listen while the app is in the foreground.

Namespaces: `DAV:` (prefix d), `http://schemas.microsoft.com/rvp/` (r), `http://schemas.microsoft.com/rvp/acl/` (a). Prefixes vary between implementations; parse by local name.

Common headers on every request:

| Header | Value |
|---|---|
| `RVP-Notifications-Version` | `0.2` (librvp). Draft examples say `1.0`. **GUESS** that 0.2 is what Exchange expects; the setting is per account in `RVPAccount.notificationsVersion`. |
| `RVP-From-Principal` | our principal URL |
| `Content-Type` | `text/xml` when there is a body |

## Sign-in sequence

1. **SUBSCRIBE self** (the delivery channel)
   ```
   SUBSCRIBE /instmsg/aliases/luke HTTP/1.1
   Notification-Type: pragma/notify
   Subscription-Lifetime: 14000
   Call-Back: http://192.168.1.50:51234
   ```
   → `200 Successful`, `Subscription-Id: <n>`, `Subscription-Lifetime: <s>`.
   Renew before expiry by re-sending with `Subscription-Id` and `Subscription-Lifetime` and no `Notification-Type`.
2. **PROPPATCH self** (presence lease)
   ```xml
   <d:propertyupdate ...><d:set><d:prop>
     <r:state><r:leased-value>
       <r:value><r:online/></r:value>
       <r:default-value><r:offline/></r:default-value>
       <d:timeout>1200</d:timeout>
     </r:leased-value><r:view-id>N</r:view-id></r:state>
   </d:prop></d:set></d:propertyupdate>
   ```
   → `207`, includes `r:view-id`. Send that view-id on later PROPPATCHes. Going offline uses the short form `<r:state><r:offline/><r:view-id>N</r:view-id></r:state>` (librvp: "required for talking to a real RVP server"). Lease is 20 min; refresh about 2 min early.
3. **PROPFIND self**, `Depth: 0`, `<d:prop><d:displayname/></d:prop>` → `207` with display name.
4. **SUBSCRIPTIONS self** → list of `<r:subscription>` with `<a:principal><a:rvp-principal>`: the people watching us. Shown as "People who added you".
5. **SUBSCRIBE each contact**
   ```
   SUBSCRIBE /instmsg/aliases/kate HTTP/1.1
   Notification-Type: update/propchange
   Subscription-Lifetime: 14000
   Call-Back: http://im.example.com/instmsg/aliases/luke
   ```
   → `207` with the contact's current `r:state` and `d:displayname`. Later changes arrive as NOTIFYs routed through the self subscription.

## Contact list storage

**GUESS (fairly confident):** Exchange 2000 does not store a buddy list. A contact list is the set of live SUBSCRIBEs, which expire. librvp keeps the list locally (Pidgin's buddy list); this client keeps it in UserDefaults. A list stored by Windows Messenger lives on that PC and is not imported.

## Presence states

Element names (from librvp's table): `online`, `busy`, `idle`, `back-soon`, `away`, `on-phone`, `at-lunch`, `offline`. "Appear offline" is published as `offline` (librvp does the same).

## Messages: NOTIFY

Sent to the recipient's principal URL on the server:

```
NOTIFY /instmsg/aliases/kate HTTP/1.1
RVP-Hop-Count: 1
RVP-Ack-Type: DeepOr
Content-Type: text/xml
```
```xml
<r:notification xmlns:d="DAV:" xmlns:r="http://schemas.microsoft.com/rvp/" xmlns:a="...acl/">
  <r:message>
    <r:notification-from><r:contact><d:href>http://.../aliases/luke</d:href><r:description>Luke</r:description></r:contact></r:notification-from>
    <r:notification-to><r:contact><d:href>http://.../aliases/kate</d:href><r:description/></r:contact></r:notification-to>
    <r:msgbody><r:mime-data><![CDATA[MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
X-MMS-IM-Format: FN=MS%20Shell%20Dlg; EF=; CO=0; CS=0; PF=0
Session-Id: {guid}

Hello]]></r:mime-data></r:msgbody>
  </r:message>
</r:notification>
```
(MIME lines are CRLF-separated.) A `200` means delivered; anything else is shown as "Not delivered".

The `mime-data` Content-Type selects the kind:

| Content-Type | Meaning |
|---|---|
| `text/plain` | chat text |
| `text/x-msmsgscontrol` + `TypingUser: <name>` header | typing indicator, re-sent every ~4 s while typing |
| `text/x-msmsgsinvite` | file transfer / app invite (not supported in v1) |
| `text/x-imleave` | left a multi-party conversation |

`Session-Id` groups a conversation. Reply with the session id the peer used.

## Incoming NOTIFY

Root `notification`, children either `message` (as above) or `propnotification`:

```xml
<r:propnotification>
  <r:notification-from><r:contact><d:href>...kate</d:href></r:contact></r:notification-from>
  <d:propertyupdate><d:set><d:prop><r:state><r:busy/></r:state></d:prop></d:set></d:propertyupdate>
</r:propnotification>
```

The client answers every callback with `HTTP/1.1 200 Successful`.

## Authentication

IIS on the `instmsg` virtual directory challenges with `WWW-Authenticate: Negotiate` and `NTLM` (draft 6.3), and possibly Digest. librvp supports NTLM and Digest.

This client relies on **URLSession's built-in NTLM/Digest/Basic** handling and declines Negotiate (Kerberos) so it falls back to NTLM. **RISK:** not yet proven with RVP's custom methods. If sign-in fails with "rejected the user name or password" while the same account works in Windows Messenger, the fallback is a raw-socket HTTP transport with NTLMv2 in Swift (needs MD4 and HMAC-MD5; about 300 lines).

NTLM user name: the alias by default, or `DOMAIN\user` in Advanced settings.

## Not in v1

- DNS SRV discovery (`_rvp._tcp.<domain>`). The server defaults to `im.<domain>` and can be overridden.
- ACL editing (block/allow lists). Exchange's default ACL lets all principals see presence and send messages (draft example 5.7.3).
- Multi-party chat, file transfer, idle detection, notifications when the app is in the background.
- Background delivery on iOS. Would need a LAN relay that holds the RVP session and pushes to the phone (overlaps with the Claude gateway design).
