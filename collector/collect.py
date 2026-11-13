#!/usr/bin/env python3
"""Daily price collector: Flipp flyer search -> data/prices.json.

Usage: POSTAL_CODE=K1A0A6 python3 collector/collect.py
       python3 collector/collect.py --selfcheck
"""
import json, os, re, sys, urllib.parse, urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "prices.json"
API = "https://backflipp.wishabi.com/flipp/items/search"
# merchant-name prefix (lowercase) -> name shown in the app
STORES = {
    "freshco": "FreshCo",
    "t&t": "T&T",
    "real canadian superstore": "Superstore",
    "walmart": "Walmart",
    "metro": "Metro",
    "farm boy": "Farm Boy",
}
KEEP = 5  # ponytail: cheapest 5 per item/store/day keeps the file small; raise if you want every match


def store_for(merchant):
    m = (merchant or "").lower()
    return next((v for k, v in STORES.items() if m.startswith(k)), None)


def matches(entry, name):
    if not re.search(entry["match"], name, re.I):
        return False
    return not (entry.get("exclude") and re.search(entry["exclude"], name, re.I))


def search(query, postal):
    qs = urllib.parse.urlencode({"locale": "en-ca", "postal_code": postal, "q": query})
    req = urllib.request.Request(f"{API}?{qs}", headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.load(r)
    return (d.get("items") or []) + (d.get("ecom_items") or [])


def collect(watchlist, postal, today):
    rows = []
    for entry in watchlist:
        by_store = {}
        for it in search(entry["query"], postal):
            store = store_for(it.get("merchant_name") or it.get("merchant"))
            name, price = (it.get("name") or "").strip(), it.get("current_price")
            if not store or not price or not matches(entry, name):
                continue  # no price = "2/$5"-style deals Flipp doesn't give a number for
            row = {
                "date": today, "item": entry["item"], "store": store, "name": name,
                "price": float(price), "unit": (it.get("post_price_text") or "").strip(),
            }
            seen = by_store.setdefault(store, {})
            if name not in seen or row["price"] < seen[name]["price"]:
                seen[name] = row  # same name listed twice (pack sizes): keep the cheaper
        for found in by_store.values():
            rows += sorted(found.values(), key=lambda r: r["price"])[:KEEP]
    return rows


def save(rows, today):
    old = json.loads(DATA.read_text()) if DATA.exists() else []
    allrows = [r for r in old if r["date"] != today] + rows  # rerun same day = replace
    DATA.parent.mkdir(exist_ok=True)
    # one row per line so git diffs stay readable
    body = ",\n".join(json.dumps(r, ensure_ascii=False) for r in allrows)
    DATA.write_text(f"[\n{body}\n]\n")


def selfcheck():
    wl = {e["item"]: e for e in json.loads((ROOT / "watchlist.json").read_text())}
    yes = [("18g protein milk", "Natrel Plus 2% Protein Milk 2l 2 L"),
           ("Eggs", "ŒUFS BLANCS SELECTION | SELECTION WHITE EGGS"),
           ("Eggs", "Great Value Large 12 Eggs L"),
           ("Bananas", "Banana"),
           ("Chicken breast", "CHICKEN BREAST VALUE PACK, 13.12/kg")]
    no = [("18g protein milk", "Natrel Plus Chocolate Protein Milk 2l 2 L"),
          ("18g protein milk", "Silk Soy Milk Alternative, 8g Of Protein 946 Ml"),
          ("Eggs", "LIFE SMART EGG WHITES"),
          ("Eggs", "Pastaio Gnocchi Traditional Egg Free 0"),
          ("Bananas", "Compass Dried Banana Chips 170 G"),
          ("Chicken breast", "Piller's Smoked Chicken Breast, High Protein")]
    for item, name in yes:
        assert matches(wl[item], name), (item, name)
    for item, name in no:
        assert not matches(wl[item], name), (item, name)
    assert store_for("T&T Supermarket") == "T&T" and store_for("Metro") == "Metro"
    assert store_for("Food Basics") is None
    print("selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        selfcheck()
        sys.exit()
    postal = os.environ.get("POSTAL_CODE", "").replace(" ", "")
    if not postal:
        sys.exit("set POSTAL_CODE")
    today = datetime.now(ZoneInfo("America/Toronto")).date().isoformat()
    rows = collect(json.loads((ROOT / "watchlist.json").read_text()), postal, today)
    if not rows:
        sys.exit("no rows collected - endpoint changed or blocked?")  # fail the workflow loudly
    save(rows, today)
    print(f"{today}: {len(rows)} rows")
