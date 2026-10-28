# Security notes

This plugin applies the same guard rails as [KOReader-Paperless](https://github.com/gargross/KOReader-Paperless). The transport code (`tls.lua`, the `httpRequest` wrapper and the http policy) is carried over unchanged. Findings that are new to Mealie are marked **new**.

## Threat model

The plugin holds two kinds of secret:

- the Mealie API token;
- optional Cloudflare Access service-token credentials. They're not used in the default home-only setup.

During *Log in* it also briefly holds the Mealie password and a short-lived Mealie session token.

It talks to one server chosen by the user, possibly over an untrusted network. It writes recipe pages and photos to one folder. It changes the device's power behaviour while a recipe is open.

## Findings and fixes

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | **Critical** | KOReader's HTTPS stack (LuaSocket → LuaSec 1.3.2 `ssl.https`) defaults to `verify = "none"`. Anyone on the network path could impersonate the server and capture the token, Cloudflare secret and login password. | `tls.lua` supplies a custom `create` for every request: `verify = "peer"` against the bundled Mozilla CA store (certifi 2026.10.18, which includes Let's Encrypt's ISRG roots). SSLv2/v3 and TLS 1.0 are disabled. |
| 2 | **Critical** | LuaSec does no hostname verification. | The peer certificate's subjectAltName (DNS, single-label wildcard, or IP) is checked against the requested host. There's no CN fallback; it fails closed. |
| 3 | **High** | LuaSocket follows GET redirects to other hosts and re-sends `Authorization` and Cloudflare headers. | `redirect = false` on every request, including the login, token creation and photo requests. A 3xx is reported with its target URL. |
| 4 | Medium | An `http://` server URL would send the token and password in cleartext. | Plain http is refused unless the host is a loopback/RFC 1918 IPv4 literal or `*.local`. A bare hostname defaults to https. The login is refused the same way, before anything is sent. |
| 5 | Medium **(new)** | Mealie's login (`POST /api/auth/token`) returns a session token. Storing it, or the password, would leave a reusable credential on the device. | *Log in* uses the session token once, to create a named long-lived API token (`KOReader <date>`) through `POST /api/users/api-tokens`. Only that API token is stored. The password and session token are never written. The token can be revoked by name in Mealie. |
| 6 | Medium **(new)** | Recipe text from the server is written into an HTML page. Markup in a recipe name, step or note could change the page or make it load remote content. | Every server string is HTML-escaped. Only `**bold**`, paragraphs and line breaks are produced, after escaping. The source URL is shown as text, not as a link. The only `<img>` points to a local file name chosen by the plugin. The page references nothing on the network. |
| 7 | Medium **(new)** | Recipe, category, tag and cookbook IDs come from the server and go into URL paths, query strings and file names. | IDs must be UUIDs (`8-4-4-4-12` hex). Anything else is dropped from lists or refused before any request. File names are always `<uuid>.html` / `<uuid>.webp`; server text never becomes a path. |
| 8 | Low **(new)** | A misbehaving server or proxy could send an unbounded response and exhaust memory or storage. | Responses are streamed through a capped sink: 8 MB for JSON, 4 MB for a photo. Larger responses are aborted and discarded. A photo is kept only when the response is `image/*`. Partial files are removed. |
| 9 | Low **(new)** | Keep-awake sets a system property (`preventScreenSaver`) that outlives KOReader if it crashes, draining the battery. | Keep-awake runs only while a page in the recipe folder is open, and is released on close. It's also released after a configurable time without a tap (default 3 hours). A persisted flag lets the next KOReader start release a keep-awake left on by a crash. If KOReader's own *Keep alive* was already on, it is left on. |
| 10 | Low | A non-JSON 200 (e.g. a proxy login page) could be misread. | Reported as "did not return JSON". |

## Residual risks (by design or out of scope)

- **Secrets at rest:** `koreader/settings/mealie.lua` is plaintext, as with every KOReader plugin. Use a dedicated, non-admin Mealie user for the Kindle, and revoke its API token in Mealie if the device is lost.
- **Token scope:** a Mealie API token has its user's full rights. The plugin only reads, apart from creating its own token at login. A stolen token could edit recipes the user can edit.
- **Saved recipes:** pages and photos in the recipe folder are readable by anyone with the device. They contain only recipe content.
- **Keep-awake and the power button:** keep-awake only stops *idle* sleep. If KOReader is killed without restarting, `preventScreenSaver` stays set until KOReader next starts or the Kindle reboots.
- **CA bundle age:** refresh `cacert.pem` periodically (see README).
- **Device OS:** the jailbreak runs code as root on the Kindle; keep KOReader updated through KPM.

## Verification

- `tests/run_tls_tests.sh` runs real LuaJIT + LuaSocket + LuaSec 1.3.2 (the version KOReader ships) against local HTTPS servers. It checks that:
  - an untrusted CA, a self-signed certificate, a hostname mismatch and a missing CA file are all refused before any request is sent;
  - a trusted custom CA works;
  - a redirect is not followed and leaks nothing;
  - an oversized response is aborted by the size cap;
  - the login is refused on an untrusted server, and the password never reaches it;
  - login and token creation work over verified TLS.
- `tests/harness.py` runs 138 checks of behaviour and policy:
  - every request (lists, recipe, photo, login, token creation) carries `redirect = false` and the verified-TLS `create`;
  - HTML escaping and the absence of links or remote references in a hostile recipe;
  - rejection of non-UUID IDs;
  - size caps;
  - nothing is sent over refused http;
  - the password and session token are not stored;
  - the full keep-awake lifecycle (start, tap, idle limit, close, user's own Keep alive, crash recovery, non-Kindle).
- **Not verified here:** the bundled CA store against your real server, and keep-awake on a real Kindle. Test both on the device.
