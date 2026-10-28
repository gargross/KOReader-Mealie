# KOReader-Mealie

A [KOReader](https://koreader.rocks) plugin for reading recipes from a self-hosted [Mealie](https://mealie.io) server on an e-reader, such as a jailbroken Kindle in the kitchen.

- Browse by **today's meal plan**, **newest recipes**, **categories**, **tags**, **cookbooks** or **A–Z**, or **search**.
- A recipe opens as a clean, large-type page: title, times, servings, photo, ingredients (with Mealie's section headers), numbered steps (with section headers), notes, categories and tags.
- **Keeps the screen awake while a recipe is open**, so the Kindle doesn't sleep mid-cook. It releases the device when you close the recipe, or after a set time without a tap (default 3 hours).
- Opened recipes are saved, so they can be read later **offline** (*Saved recipes*).
- Returns to the list you came from when you close a recipe. Has a home-screen icon.
- Verified HTTPS and the other guard rails from [KOReader-Paperless](https://github.com/gargross/KOReader-Paperless); see [SECURITY.md](SECURITY.md).

Read-only: it doesn't edit recipes, meal plans or shopping lists.

Tested against Mealie **v3.29.0**'s API (read from its source). The Mealie API is unversioned, so a future Mealie release could change it.

## Install

1. Close KOReader. Connect the Kindle by USB.
2. Copy the `mealie.koplugin` folder to `koreader/plugins/`.
3. Optional home-screen icon: copy `scriptlet/Mealie.sh` to the `documents` folder.
4. Start KOReader. The plugin is at **Tools → Mealie recipes** (both in the file browser and while reading).

## Set up

On the Kindle: **Tools → Mealie recipes → Settings**

| Setting | What to enter |
|---|---|
| Server URL | e.g. `mealie.example.com` (https is assumed) |
| Log in with username/password | **Easiest.** Creates an API token named `KOReader <date>` in Mealie and stores only that token. The password isn't saved. |
| API token | Alternative to logging in. A Mealie token is about 200 characters, so put it in the settings file over USB instead of typing it (below). |
| Cloudflare Access headers | Only if the server sits behind Cloudflare Access and you use it away from home. |
| Custom CA certificate file | Leave empty for Let's Encrypt or any public CA. Set a PEM path only for a private CA such as Caddy `tls internal`. |
| Recipe folder | Where recipe pages are saved. Default: `<home>/Mealie`. |
| Keep screen awake while a recipe is open | On by default. |
| Keep awake for up to (hours without a tap) | 1–12. Default 3. |
| Show recipe photos | On by default. Mealie stores photos as WebP. |
| Open saved copy instead of refreshing | Off by default: opening a recipe fetches the current version. Turn on to open the saved copy without the network. |

### Recommended: a dedicated Mealie user

Create a regular (non-admin) user for the Kindle in your existing group **and household**, and log in as it. Recipes are shared across the group. Meal plans and cookbooks belong to a household, so put the user in the same household or it won't see them. If the device is lost, delete that user's `KOReader …` token in Mealie.

### Creating a token in Mealie instead (optional)

The *API Tokens* card is hidden until the user turns on **Show advanced features**: Profile → User Settings → *Manage User Profile* → tick *Show advanced features*. Then go to Profile → *API Tokens* (`/user/profile/api-tokens`), create a token, and paste it into `examples/mealie.lua.example`. Save that file as `koreader/settings/mealie.lua`, with KOReader closed.

## Using it

- **Tap** a recipe to open it, fresh from Mealie. **Hold** a recipe for: open (refresh), open saved copy, save for offline, delete saved copy.
- **Back arrow** goes up one level; **✕** closes the plugin.
- To leave a recipe, use the reader's top-menu **File browser** button, or a gesture bound to "File browser". You return to the list you came from.
- Meal-plan notes without a recipe show their text when tapped.

### Keep-awake details

While a page from the recipe folder is open:

- On Kindle it runs `lipc-set-prop com.lab126.powerd preventScreenSaver 1`, the same command as KOReader's built-in *Keep alive* plugin. It also pauses KOReader's AutoSuspend.
- Everything is restored when you close the recipe, or after the idle limit.
- If KOReader crashes, the next start releases it.
- If you already had KOReader's own *Keep alive* on, it's left on.
- The power button still puts the device to sleep. The frontlight stays on while awake, so it uses battery.

## Troubleshooting

| Message | Meaning |
|---|---|
| Secure connection refused: certificate verify failed | The certificate isn't from a trusted CA, or something is intercepting traffic. Nothing was sent. For a private CA, set *Custom CA certificate file*. |
| …certificate does not match host… | The certificate is valid but for a different name. Check the server URL. |
| Server redirected (HTTP 302) to … | A proxy or login page is in front of Mealie (e.g. Cloudflare Access), or the URL is wrong. |
| The server did not return JSON | Same as above: a login page answered instead of Mealie. |
| Authentication failed (401) | The token is wrong or was deleted in Mealie. Log in again. |
| A recipe opens with no photo | The recipe has no image, *Show recipe photos* is off, or this KOReader build can't render WebP in HTML. |

Errors and crashes are in `koreader/crash.log`.

## Files

```
mealie.koplugin/
  _meta.lua      plugin name/description
  main.lua       UI, API client, settings
  render.lua     recipe JSON -> escaped HTML page
  keepawake.lua  keep-awake while a recipe is open
  tls.lua        verified TLS for LuaSocket (shared with KOReader-Paperless)
  cacert.pem     Mozilla CA bundle (from certifi)
scriptlet/       home-screen launcher + icon
examples/        settings file template
tests/           behaviour harness (lupa) + real-TLS tests (LuaSec)
```

## Development

```
pip install lupa
python3 -I tests/harness.py mealie.koplugin           # 138 behaviour/security checks
sudo apt install luajit lua-socket lua-sec lua-cjson lua-filesystem
tests/run_tls_tests.sh                                 # real LuaSec TLS tests
```

Refresh the CA bundle occasionally: `pip install -U certifi && cp "$(python3 -c 'import certifi;print(certifi.where())')" mealie.koplugin/cacert.pem`

Neither test suite has run on the Kindle itself. Verify on the device.
