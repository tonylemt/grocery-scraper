#!/usr/bin/env python3
"""Daily price collector: Flipp flyer search -> data/prices.json.

Usage: POSTAL_CODE=K1A0A6 python3 collector/collect.py
       python3 collector/collect.py --selfcheck
"""
import json, os, re, sys, urllib.parse, urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Toronto")

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "prices.json"
API = "https://backflipp.wishabi.com/flipp/items/search"
# merchant-name prefix (lowercase) -> name shown in the app. Keep in sync with
# FlippSearch.stores in ios/GroceryPrices/GroceryPrices/GitHub.swift (add-item preview).
STORES = {
    "freshco": "FreshCo",
    "t&t": "T&T",
    "real canadian superstore": "Superstore",
    "walmart": "Walmart",
    "metro": "Metro",
    "farm boy": "Farm Boy",
}
KEEP = 5  # ponytail: cheapest 5 (per unit) per item/store/day keeps the file small; raise if you want every match


def store_for(merchant):
    m = (merchant or "").lower()
    return next((v for k, v in STORES.items() if m.startswith(k)), None)


def matches(entry, name):
    if not re.search(entry["match"], name, re.I):
        return False
    return not (entry.get("exclude") and re.search(entry["exclude"], name, re.I))


LB = 0.45359237
NUM = r"(\d+(?:[.,]\d+)?)"


def unit_price(row, entry):
    """Price per entry["per"] (kg, L, dozen, or each = shelf price), or None when the size can't be read."""
    per, text, price = entry.get("per"), row["unit"].lower(), row["price"]
    name = row["name"].lower()
    num = lambda s: float(s.replace(",", "."))
    qty = None  # size of what `price` buys, in `per` units
    if per == "kg":
        if re.match(r"^/?\s*lb\b", text):
            qty = LB
        elif re.match(r"^/?\s*kg\b", text):
            qty = 1
        elif re.match(r"^/?\s*100\s*g\b", text):
            qty = 0.1
        elif m := re.search(NUM + r"\s*(kg|g|lb)\b", name):
            qty = num(m[1]) * {"kg": 1, "g": 0.001, "lb": LB}[m[2]]
    elif per == "L":
        if m := re.search(NUM + r"\s*(ml|l)\b", name):
            qty = num(m[1]) * (0.001 if m[2] == "ml" else 1)
    elif per == "each":
        qty = 1  # compared on shelf price, e.g. a loaf of bread or a box of cereal
    elif per == "dozen":
        if m := re.search(r"(\d+)\s*(?:pcs|pc|'s|eggs|ct|pk)\b", name):
            qty = int(m[1]) / 12
    if qty is None and not text and "assume" in entry:
        qty = entry["assume"]  # ponytail: typical size for unsized items (dozen eggs, one banana ~120 g)
    return round(price / qty, 2) if qty else None


def search(query, postal):
    qs = urllib.parse.urlencode({"locale": "en-ca", "postal_code": postal, "q": query})
    req = urllib.request.Request(f"{API}?{qs}", headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.load(r)
    return (d.get("items") or []) + (d.get("ecom_items") or [])


def source(it):
    """Where a price came from: the flyer page on Flipp, or the store's own product page."""
    if it.get("item_type") == "ecom":  # only Walmart among our stores
        return {"source": "online", "url": f"https://www.walmart.ca/en/ip/{it.get('sku') or it.get('item_id')}",
                "image": it.get("image_url")}
    return {
        "source": "flyer", "url": f"https://flipp.com/en-ca/item/{it.get('flyer_item_id') or it.get('id')}",
        "image": it.get("clean_image_url"), "valid_from": local_day(it.get("valid_from")),
        "valid_to": local_day(it.get("valid_to")), "sale": it.get("sale_story"),
    }


def local_day(ts):
    """Flipp gives UTC timestamps ("...T04:59:59+00:00" ends the previous Ottawa day)."""
    return datetime.fromisoformat(ts).astimezone(TZ).date().isoformat() if ts else None


def collect(watchlist, postal, today):
    rows = []
    for entry in watchlist:
        by_store = {}
        for it in search(entry["query"], postal):
            store = store_for(it.get("merchant_name") or it.get("merchant"))
            name, price = (it.get("name") or "").strip(), it.get("current_price")
            if not store or not price or not matches(entry, name):
                continue  # no price = "2/$5"-style deals Flipp doesn't give a number for
            if (local_day(it.get("valid_from")) or today) > today:
                continue  # next week's flyer, published early: not today's price
            row = {
                "date": today, "item": entry["item"], "store": store, "name": name,
                "price": float(price), "unit": (it.get("post_price_text") or "").strip(),
                **source(it),
            }
            seen = by_store.setdefault(store, {})
            if name not in seen or row["price"] < seen[name]["price"]:
                seen[name] = row  # same name listed twice (pack sizes): keep the cheaper
        for found in by_store.values():
            for r in found.values():
                r["unit_price"] = unit_price(r, entry)
            # cheapest per unit first; unsized products after, by shelf price
            key = lambda r: (r["unit_price"] is None, r["unit_price"] or 0, r["price"])
            rows += sorted(found.values(), key=key)[:KEEP]
    return rows


def save(rows, today, watchlist, path=DATA):
    old = json.loads(path.read_text()) if path.exists() else []
    allrows = [r for r in old if r["date"] != today] + rows  # rerun same day = replace
    wl = {e["item"]: e for e in watchlist}
    for r in allrows:  # recomputed every run, so parser fixes reach old rows too
        if e := wl.get(r["item"]):  # removed items keep their history as it was
            r["per"], r["unit_price"] = e.get("per"), unit_price(r, e)
    path.parent.mkdir(exist_ok=True)
    # one row per line so git diffs stay readable
    body = ",\n".join(json.dumps(r, ensure_ascii=False) for r in allrows)
    path.write_text(f"[\n{body}\n]\n")


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
    up = lambda item, name, price, unit="": unit_price(
        {"name": name, "price": price, "unit": unit}, wl[item])
    assert up("Chicken breast", "HALAL CHICKEN BREAST", 4.88, "lb") == 10.76
    assert up("Ground beef", "BOEUF HACHÉ MAIGRE", 8.99, "/lb - 19,82$/kg") == 19.82
    assert up("Apples", "NO NAME® NATURALLY IMPERFECT APPLES, 6 LB", 4.99) == 1.83
    assert up("Apples", "LOCAL APPLES", 3.99, "ea.") is None  # bag of unknown size
    assert up("Chicken breast", "Maple Leaf Boneless Skinless Chicken Breasts", 11.9) is None
    assert up("Chicken breast", "PC® CHICKEN BREASTS, 3'S, UP TO 630 G", 13) == 20.63
    assert up("18g protein milk", "Natrel Plus 2% Protein Milk 2l 2 L", 8.64) == 4.32
    assert up("18g protein milk", "Lactantia Ultrapur 3.25% Milk 20 G Protein 1.5 L 1.5l", 5.98) == 3.99
    assert up("Eggs", "BURNBRAE FARMS OMEGA 3 BROWN EGGS, 18pcs", 6.88, "/ea") == 4.59
    assert up("Eggs", "PC® FREE RUN BROWN EGGS LARGE, 12'S", 6.5) == 6.5
    assert up("Eggs", "SELECTION WHITE EGGS", 5.99) == 5.99  # assumed dozen
    assert up("Bananas", "Banana", 0.29) == 2.42
    assert source({"item_type": "ecom", "sku": "123"})["url"] == "https://www.walmart.ca/en/ip/123"
    fl = source({"item_type": "flyer", "flyer_item_id": 9, "valid_from": "2026-11-12T05:00:00+00:00"})
    assert fl["url"] == "https://flipp.com/en-ca/item/9" and fl["valid_from"] == "2026-11-12"
    assert local_day("2026-11-19T04:59:59+00:00") == "2026-11-18"
    assert unit_price({"name": "Bread", "price": 3.49, "unit": ""}, {"per": "each"}) == 3.49
    import tempfile  # removing an item from the watchlist must not wipe its history
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "prices.json"
        old = {"date": "2026-01-01", "item": "Gone", "name": "X 1 kg", "price": 5.0, "unit": "",
               "per": "kg", "unit_price": 5.0}
        p.write_text(json.dumps([old]))
        save([], "2026-01-02", [], path=p)
        assert json.loads(p.read_text())[0]["unit_price"] == 5.0
    print("selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        selfcheck()
        sys.exit()
    postal = os.environ.get("POSTAL_CODE", "").replace(" ", "")
    if not postal:
        sys.exit("set POSTAL_CODE")
    today = datetime.now(TZ).date().isoformat()
    watchlist = json.loads((ROOT / "watchlist.json").read_text())
    rows = collect(watchlist, postal, today)
    if not rows:
        sys.exit("no rows collected - endpoint changed or blocked?")  # fail the workflow loudly
    save(rows, today, watchlist)
    print(f"{today}: {len(rows)} rows")
