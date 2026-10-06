"""Converts the official TCG Genesys point list into a versioned points table for the game.

Run with the portable Python from bootstrap:
    tools/python/python.exe scripts/import_genesys_points.py [saved_page.html]

Without an argument it downloads https://www.yugioh-card.com/en/genesys/ (the list is an
HTML table of card names and points, Windows-1252 encoded). Names are matched to passcodes
using our card databases, then YGOPRODeck's current TCG names (third_party/card_images/
cardinfo.json, from fetch-card-images.ps1), then MANUAL below. Any name left unmatched
aborts the import instead of being skipped.

Only point values are imported. Genesys' card pool restrictions are not.
"""
import datetime
import html
import json
import os
import re
import sqlite3
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://www.yugioh-card.com/en/genesys/"
DATABASES = ["third_party/BabelCDB/cards.cdb", "third_party/BabelCDB/release-betb.cdb"]
CARDINFO = "third_party/card_images/cardinfo.json"
# Names the page cannot spell like our databases do (it has no Omega in Windows-1252).
MANUAL = {"Exstellarknight Constellar Ptolemy O7": 6195332}


def main():
    if len(sys.argv) > 1:
        raw = open(sys.argv[1], "rb").read()
    else:
        request = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0 (YGO_PVE points import)"})
        raw = urllib.request.urlopen(request).read()
    page = raw.decode("cp1252")
    rows = re.findall(r'<td class="column-1">([^<]*)</td><td class="column-2">([^<]*)', page)
    if not rows:
        sys.exit("no point rows found; the page layout may have changed")

    by_name = {}
    for db in DATABASES:
        con = sqlite3.connect(os.path.join(ROOT, db))
        # Prefer each name's base printing (alias 0); keep alias cards that have no base row.
        for code, name, alias in con.execute("SELECT t.id, t.name, d.alias FROM texts t JOIN datas d ON d.id = t.id ORDER BY d.alias != 0"):
            by_name.setdefault(name.lower(), code)
    tcg_names = {}
    cardinfo = os.path.join(ROOT, CARDINFO)
    if os.path.exists(cardinfo):
        for card in json.load(open(cardinfo, encoding="utf-8"))["data"]:
            tcg_names[card["name"].lower()] = card["id"]

    points, names, unmatched = {}, {}, []
    for raw_name, raw_points in rows:
        name = html.unescape(raw_name).strip()
        code = MANUAL.get(name) or by_name.get(name.lower()) or tcg_names.get(name.lower())
        if code is None:
            unmatched.append(name)
            continue
        if str(code) in points:
            sys.exit(f"two list entries map to card {code}: {names[str(code)]!r} and {name!r}")
        points[str(code)] = int(raw_points)
        names[str(code)] = name
    if unmatched:
        sys.exit("unmatched card names (add them to MANUAL): " + ", ".join(unmatched))

    today = datetime.date.today().isoformat()
    table = {
        "format": "ygo-pve-points/1",
        "version": f"genesys-tcg-{today}",
        "source": f"{URL} (retrieved {today}; the page shows no effective date)",
        "unlisted_points": 0,
        "unlisted_note": "Genesys rule: cards that are not on the list cost 0 points.",
        "points": dict(sorted(points.items(), key=lambda kv: int(kv[0]))),
        "names": dict(sorted(names.items(), key=lambda kv: int(kv[0]))),
    }
    out = os.path.join(ROOT, "game", "data", "points", f"genesys-tcg-{today}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(table, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{len(points)} cards -> {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
