"""Behaviour and security tests for mealie.koplugin using stubbed KOReader
modules and a fake Mealie (v3.29 API shape) server.
Run: python3 -I tests/harness.py mealie.koplugin"""
import json
import os
import shutil
import sys
import tempfile
import urllib.parse

try:
    from lupa.luajit21 import LuaRuntime
    RUNTIME = "luajit21"
except Exception:  # pragma: no cover
    from lupa import LuaRuntime
    RUNTIME = "lua"

plugin_dir = os.path.abspath(sys.argv[1])
lua = LuaRuntime(unpack_returned_tuples=True)
work = tempfile.mkdtemp(prefix="mealie_test_")

# ---------------------------------------------------------------- fake server
U = lambda n: "%08x-0000-4000-8000-%012x" % (n, n)
CHILI, RIB, THIGHS, BAD = U(1), U(2), U(3), "../../etc/passwd"
SUMMARIES = [
    {"id": THIGHS, "name": "Dan-O's Chicken Thighs", "slug": "thighs", "totalTime": "1 hour 30 minutes"},
    {"id": CHILI, "name": "Boilermaker Tailgate Chili", "slug": "chili", "totalTime": "2 hours 30 minutes"},
    {"id": RIB, "name": "Prime Rib Roast", "slug": "rib", "totalTime": None},
]
CATEGORIES = [{"id": U(100), "name": "Main", "slug": "main"}, {"id": "not-a-uuid", "name": "Bad", "slug": "bad"},
              {"id": U(101), "name": "Dessert", "slug": "dessert"}]
TAGS = [{"id": U(200), "name": "Chicken", "slug": "chicken"}]
COOKBOOKS = [{"id": U(300), "name": "Weeknights", "slug": "weeknights"}]
DETAIL = {
    CHILI: {
        "id": CHILI, "name": "Chili <script>alert(1)</script> & \"beans\"", "description": "A **crowd** pleaser.\n\nGame day!",
        "totalTime": "2 hours 30 minutes", "prepTime": "30 minutes", "performTime": "2 hours",
        "recipeServings": 12, "recipeYield": "", "orgURL": "https://example.com/chili?a=1&b=<x>",
        "recipeIngredient": [
            {"display": "2 pounds ground beef chuck", "title": None},
            {"title": "Seasoning rub:", "display": "3 cloves garlic, minced"},
            {"display": "", "originalText": "1 tablespoon bacon bits"},
            {"display": "", "quantity": 2.5, "unit": {"name": "cups"}, "food": {"name": "beef broth"}, "note": "low-salt"},
            {"display": "", "quantity": 0, "food": {"name": "salt"}},
        ],
        "recipeInstructions": [
            {"title": "", "text": "Gather all ingredients."},
            {"title": "Seasoning rub", "text": "Combine.\nRub it in."},
            {"title": "", "summary": "Simmer", "text": "Cover and simmer <low>."},
        ],
        "notes": [{"title": "Tip", "text": "Better the next day."}, {"title": "", "text": ""}],
        "recipeCategory": [{"name": "Main"}], "tags": [{"name": "American"}, {"name": "Beef"}],
    },
}
for s in SUMMARIES:
    DETAIL.setdefault(s["id"], dict(s, recipeIngredient=[], recipeInstructions=[{"text": "Cook it."}]))
MEALPLAN = [
    {"id": 5, "date": "2026-10-28", "entryType": "dinner", "title": "", "text": "", "recipeId": CHILI,
     "recipe": SUMMARIES[1]},
    {"id": 6, "date": "2026-10-28", "entryType": "breakfast", "title": "Leftover pizza", "text": "From Friday",
     "recipeId": None, "recipe": None},
    {"id": 7, "date": "2026-10-28", "entryType": "side", "title": "", "text": "", "recipe": {"id": BAD, "name": "evil"}},
]
state = {"requests": [], "mode": "ok", "image": "ok", "plan": MEALPLAN}


def to_lua(o):
    if isinstance(o, dict):
        return lua.table_from({k: to_lua(v) for k, v in o.items() if v is not None})
    if isinstance(o, list):
        return lua.table_from([to_lua(v) for v in o])
    return o


def py_json_decode(s):
    return to_lua(json.loads(s))


def py_json_encode(t):
    return json.dumps({k: v for k, v in t.items()})


def read_source(src):
    body = ""
    while src is not None:
        chunk = src()
        if not chunk:
            break
        body += chunk
    return body


def page_of(items, qs):
    page = int(qs.get("page", ["1"])[0])
    per = int(qs.get("perPage", ["50"])[0])
    chunk = items if per == -1 else items[(page - 1) * per: page * per]
    total_pages = 1 if per == -1 else max(1, -(-len(items) // per))
    return {"page": page, "per_page": per, "total": len(items), "total_pages": total_pages,
            "items": chunk, "next": None, "previous": None}


def py_request(opts):
    url = opts["url"]
    method = opts["method"] or "GET"
    headers = {k: v for k, v in opts["headers"].items()}
    body = read_source(opts["source"]) if opts["source"] is not None else ""
    state["requests"].append({"method": method, "url": url, "headers": headers, "body": body,
                              "redirect": opts["redirect"], "has_create": opts["create"] is not None})
    mode = state["mode"]
    if mode == "neterr":
        return (None, "connection refused", None)
    path = url.split("://", 1)[1]
    path = path[path.index("/"):]
    parsed = urllib.parse.urlparse(path)
    qs = urllib.parse.parse_qs(parsed.query)
    sink = opts["sink"]

    def reply(code, payload=b"", rheaders=None):
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload).encode()
            rheaders = rheaders or {"content-type": "application/json"}
        if isinstance(payload, bytes):
            payload = payload.decode("latin-1")
        step = 1 << 20
        for i in range(0, len(payload), step):
            ok = sink(payload[i:i + step])
            if isinstance(ok, tuple):
                ok = ok[0]
            if ok is None:  # sink refused: LuaSocket aborts the request
                return (None, "response too large", None)
        sink(None)
        return (code, to_lua(rheaders or {}), "HTTP/1.1 %d" % code)

    if parsed.path == "/api/auth/token" and method == "POST":
        form = urllib.parse.parse_qs(body)
        if form.get("username") == ["kindle"] and form.get("password") == ["p&ss word"]:
            return reply(200, {"access_token": "SESSIONJWT", "token_type": "bearer", "expires_in": 172800})
        if form.get("username") == ["locked"]:
            return reply(423, {"detail": "User is locked out"})
        return reply(401, b"")
    if mode == "403":
        return reply(403, b"nope")
    if mode == "302":
        return reply(302, b"", {"location": "https://x.cloudflareaccess.com/cdn-cgi/access/login"})
    if mode == "html":
        return reply(200, b"<html>login</html>", {"content-type": "text/html"})
    if mode == "huge":
        return reply(200, b"[" + b"1," * (5 << 20) + b"1]", {"content-type": "application/json"})
    auth = headers.get("Authorization")
    if parsed.path == "/api/users/api-tokens" and method == "POST":
        if auth != "Bearer SESSIONJWT":
            return reply(401, b"")
        return reply(201, {"name": json.loads(body)["name"], "id": 1, "token": "LONGTOKEN"})
    if auth != "Bearer LONGTOKEN":
        return reply(401, {"detail": "Not authenticated"})
    if parsed.path == "/api/recipes":
        items = list(SUMMARIES)
        if "search" in qs:
            items = [r for r in items if qs["search"][0].lower() in r["name"].lower()]
        if "categories" in qs or "tags" in qs or "cookbook" in qs:
            items = items[:1]
        items = sorted(items, key=lambda r: r["name"]) if qs.get("orderBy") == ["name"] else items
        if mode == "badids":
            items = items + [{"id": BAD, "name": "evil"}]
        return reply(200, page_of(items, qs))
    if parsed.path.startswith("/api/recipes/"):
        rid = urllib.parse.unquote(parsed.path[len("/api/recipes/"):])
        if rid in DETAIL:
            return reply(200, DETAIL[rid])
        return reply(404, {"detail": "not found"})
    if parsed.path == "/api/organizers/categories":
        return reply(200, page_of(CATEGORIES, qs))
    if parsed.path == "/api/organizers/tags":
        return reply(200, page_of(TAGS, qs))
    if parsed.path == "/api/households/cookbooks":
        return reply(200, page_of(COOKBOOKS, qs))
    if parsed.path == "/api/households/mealplans/today":
        return reply(200, state["plan"])
    if parsed.path.startswith("/api/media/recipes/") and parsed.path.endswith("/images/min-original.webp"):
        if state["image"] == "missing":
            return reply(404, b"")
        if state["image"] == "html":
            return reply(200, b"<html>", {"content-type": "text/html"})
        if state["image"] == "huge":
            return reply(200, b"R" * (5 << 20), {"content-type": "image/webp"})
        return reply(200, b"RIFF....WEBPVP8 fake", {"content-type": "image/webp"})
    return reply(404, b"unknown route")


def py_stat(path, what=None):
    try:
        st = os.stat(path)
    except OSError:
        return None
    attr = {"mode": "directory" if os.path.isdir(path) else "file",
            "modification": int(st.st_mtime), "size": st.st_size}
    return attr[what] if what else lua.table_from(attr)


def py_read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


g = lua.globals()
g.py_json_decode = py_json_decode
g.py_json_encode = py_json_encode
g.py_request = py_request
g.py_stat = py_stat
g.py_read = py_read
g.py_listdir = lambda p: lua.table_from(sorted(os.listdir(p)))
g.WORK = work
g.PLUGIN_DIR = plugin_dir
g.py_requests = lambda: to_lua(state["requests"])
g.py_clear_requests = lambda: state["requests"].clear()
g.py_set_mode = lambda m: state.__setitem__("mode", m)
g.py_set_image = lambda m: state.__setitem__("image", m)
g.py_set_plan = lambda empty: state.__setitem__("plan", [] if empty else MEALPLAN)
g.CHILI, g.RIB, g.THIGHS, g.BAD = CHILI, RIB, THIGHS, BAD
g.CAT_MAIN, g.TAG_CHICKEN, g.COOKBOOK = U(100), U(200), U(300)

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness_tests.lua"), encoding="utf-8") as f:
    LUA_TEST = f.read()

fails = lua.execute(LUA_TEST)
print("runtime:", RUNTIME)
shutil.rmtree(work, ignore_errors=True)
for p in ("/tmp/mealie.autostart",):
    if os.path.exists(p):
        os.remove(p)
sys.exit(1 if fails else 0)
