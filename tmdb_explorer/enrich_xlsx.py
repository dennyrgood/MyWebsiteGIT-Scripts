#!/usr/bin/env python3
"""Surgical .xlsx enrichment from TMDB.

    enrich_xlsx INPUT.xlsx [OUTPUT.xlsx]     (default OUTPUT: "<INPUT> ENRICHED.xlsx")

Takes a workbook of movie/TV titles, finds a TMDB (or IMDB) link in every data
row, looks each title up in TMDB, and appends a block of TMDB columns — WITHOUT
going through openpyxl, which would drop the sheet's external-workbook
references (the VLOOKUPs against the OneDrive master), named views, and other
parts it doesn't round-trip.

Reads the TMDB key from ~/.config/search_shows/keys.json ("tmdb"). No caching:
every run fetches fresh from TMDB (~1-2 min for a few hundred rows). The two
sheet-specific knobs are the COLUMNS list (which TMDB fields to write) and
CLEAR_COLS (formula columns to blank); both are constants near the top.

Instead this treats the .xlsx as the zip of XML parts it is and rewrites only
the two parts it must (the worksheet and its table definition), copying every
other part through byte-for-byte. The one extra edit is dropping calcChain.xml
(and its two references), which Excel regenerates on open — necessary because
we blank out formula cells and a stale calc chain triggers the repair dialog.

Row matching is link-based, not fuzzy: the id and media type come straight out
of a themoviedb.org URL sitting in a cell or a hyperlink, so there is no
guessing. A themoviedb.org link (in cell text or a hyperlink target) wins;
failing that an imdb.com/title/tt… link is resolved via TMDB's /find. Rows
with neither are left blank and reported as unresolved.

Library entry point: enrich_workbook(xlsx_bytes, fetch_details, find_imdb) -> (bytes, report)
"""

import json
import re
import sys
import zipfile
from io import BytesIO
from pathlib import Path
from xml.etree import ElementTree as ET

import requests

MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

TMDB_RE = re.compile(r"themoviedb\.org/(movie|tv)/(\d+)")
IMDB_RE = re.compile(r"imdb\.com/title/(tt\d+)")
# control chars that are illegal in XML 1.0 text (tab/LF/CR are fine)
_BAD_XML = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


# ---------- column reference helpers ----------

def _col_num(ref: str) -> int:
    n = 0
    for ch in re.match(r"[A-Z]+", ref).group(0):
        n = n * 26 + (ord(ch) - 64)
    return n


def _col_name(n: int) -> str:
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def _xesc(s) -> str:
    return _BAD_XML.sub("", str(s)).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ---------- TMDB field extractors (mirror the frontend's logic) ----------

def _us_cert_movie(d: dict) -> str:
    results = (d.get("release_dates") or {}).get("results", [])
    for want_us in (True, False):  # prefer US, then any country
        for r in results:
            if want_us and r.get("iso_3166_1") != "US":
                continue
            for x in r.get("release_dates", []):
                if x.get("certification"):
                    return x["certification"]
    return ""


def _us_cert_tv(d: dict) -> str:
    results = (d.get("content_ratings") or {}).get("results", [])
    for want_us in (True, False):
        for r in results:
            if want_us and r.get("iso_3166_1") != "US":
                continue
            if r.get("rating"):
                return r["rating"]
    return ""


def _cast_top5(d: dict, is_tv: bool) -> str:
    if is_tv:
        cast = (d.get("aggregate_credits") or {}).get("cast", [])[:5]
        def char(c):
            roles = c.get("roles") or []
            return roles[0].get("character", "") if roles else ""
    else:
        cast = sorted((d.get("credits") or {}).get("cast", []),
                      key=lambda c: c.get("order", 1_000_000))[:5]
        def char(c):
            return c.get("character", "")
    parts = []
    for c in cast:
        name, ch = c.get("name", ""), char(c)
        parts.append(f"{name} ({ch})" if ch else name)
    return "; ".join(p for p in parts if p)


def _ep_ref(e: dict) -> str:
    if not e:
        return ""
    s = f"S{e.get('season_number')}E{e.get('episode_number')} — {e.get('name', '')}"
    return s + (f" ({e['air_date']})" if e.get("air_date") else "")


def _names(items, key="name") -> str:
    return ", ".join(x.get(key, "") for x in (items or []) if x.get(key))


# (header, kind, extractor). kind "n" -> numeric cell, "s" -> inline string.
# The first 12 apply to both; the rest are TV-only and stay blank for movies.
COLUMNS = [
    ("tmdb_id", "n", lambda d, tv: d.get("id")),
    ("title", "s", lambda d, tv: (d.get("name") if tv else d.get("title")) or ""),
    ("original_language", "s", lambda d, tv: d.get("original_language", "")),
    ("origin_country", "s", lambda d, tv: ", ".join(d.get("origin_country") or [])),
    ("overview", "s", lambda d, tv: d.get("overview", "")),
    ("genres", "s", lambda d, tv: _names(d.get("genres"))),
    ("certification", "s", lambda d, tv: _us_cert_tv(d) if tv else _us_cert_movie(d)),
    ("tmdb_status", "s", lambda d, tv: d.get("status", "")),
    ("release_date", "s", lambda d, tv: (d.get("first_air_date") if tv else d.get("release_date")) or ""),
    ("runtime", "n", lambda d, tv: (d.get("episode_run_time") or [None])[0] if tv else d.get("runtime")),
    ("cast_top5", "s", lambda d, tv: _cast_top5(d, tv)),
    ("imdb_id", "s", lambda d, tv: (d.get("external_ids") or {}).get("imdb_id") or ""),
    ("type", "s", lambda d, tv: d.get("type", "") if tv else ""),
    ("in_production", "s", lambda d, tv: ("Yes" if d.get("in_production") else "No") if tv else ""),
    ("last_air_date", "s", lambda d, tv: d.get("last_air_date", "") if tv else ""),
    ("number_of_seasons", "n", lambda d, tv: d.get("number_of_seasons") if tv else None),
    ("number_of_episodes", "n", lambda d, tv: d.get("number_of_episodes") if tv else None),
    ("last_episode_to_air", "s", lambda d, tv: _ep_ref(d.get("last_episode_to_air")) if tv else ""),
    ("next_episode_to_air", "s", lambda d, tv: _ep_ref(d.get("next_episode_to_air")) if tv else ""),
    ("created_by", "s", lambda d, tv: _names(d.get("created_by")) if tv else ""),
    ("networks", "s", lambda d, tv: _names(d.get("networks")) if tv else ""),
    ("tvdb_id", "n", lambda d, tv: (d.get("external_ids") or {}).get("tvdb_id") if tv else None),
]

# columns whose formulas we blank (they reference an external workbook that
# won't come along; the user re-adds them in the master). Kept as cells with
# their style intact, just emptied of formula + cached value.
CLEAR_COLS = ("B", "D", "E")


# ---------- reading (never mutates; used only to resolve ids) ----------

def _shared_strings(zf: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in zf.namelist():
        return []
    root = ET.fromstring(zf.read("xl/sharedStrings.xml"))
    out = []
    for si in root.iter(f"{{{MAIN}}}si"):
        out.append("".join(t.text or "" for t in si.iter(f"{{{MAIN}}}t")))
    return out


def _find_data_sheet(zf: zipfile.ZipFile) -> tuple[str, str]:
    """Return (worksheet_part, table_part) for the sheet that owns a table.

    Falls back to the first worksheet if none has a table (the caller then has
    no table to widen, which is fine)."""
    sheets = sorted(n for n in zf.namelist()
                    if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n))
    first_table = None
    for ws in sheets:
        rels = f"xl/worksheets/_rels/{ws.rsplit('/', 1)[1]}.rels"
        if rels not in zf.namelist():
            continue
        for rel in ET.fromstring(zf.read(rels)):
            if rel.get("Type", "").endswith("/table"):
                tgt = rel.get("Target").replace("../", "xl/").lstrip("/")
                if not tgt.startswith("xl/"):
                    tgt = "xl/" + tgt
                first_table = first_table or (ws, tgt)
                return ws, tgt
    return (sheets[0] if sheets else ""), ""


def _read_model(zf: zipfile.ZipFile, ws_part: str):
    """Extract per-row text + hyperlink targets and the header-cell style."""
    shared = _shared_strings(zf)
    root = ET.fromstring(zf.read(ws_part))

    # hyperlink targets: cell ref -> URL (external) or #location (internal)
    rels_part = f"xl/worksheets/_rels/{ws_part.rsplit('/', 1)[1]}.rels"
    rid_target = {}
    if rels_part in zf.namelist():
        for rel in ET.fromstring(zf.read(rels_part)):
            rid_target[rel.get("Id")] = rel.get("Target")
    hyperlinks: dict[str, str] = {}
    for hl in root.iter(f"{{{MAIN}}}hyperlink"):
        ref = hl.get("ref")
        rid = hl.get(f"{{{REL}}}id")
        url = rid_target.get(rid) if rid else hl.get("location")
        if ref and url:
            hyperlinks[ref] = url

    rows: dict[int, dict[int, str]] = {}
    header_style: dict[int, str] = {}
    for row in root.iter(f"{{{MAIN}}}row"):
        rnum = int(row.get("r"))
        cells: dict[int, str] = {}
        for c in row.iter(f"{{{MAIN}}}c"):
            cnum = _col_num(c.get("r"))
            if c.get("s"):
                header_style[cnum] = c.get("s")
            t = c.get("t")
            v = c.find(f"{{{MAIN}}}v")
            if t == "inlineStr":
                val = "".join(x.text or "" for x in c.iter(f"{{{MAIN}}}t"))
            elif v is None or v.text is None:
                continue
            elif t == "s":
                val = shared[int(v.text)]
            else:
                val = v.text
            if val:
                cells[cnum] = val
        rows[rnum] = cells
    return rows, hyperlinks, header_style


def _resolve_row(cells: dict, hyperlinks: dict, rownum: int, find_imdb):
    """(media_type, tmdb_id, how) for a data row, or (None, None, reason).

    Scans cell text and hyperlink targets left-to-right so an explicit TMDB id
    in an early column (e.g. C) beats a later one (e.g. a hyperlink on L)."""
    urls = []
    for cnum, text in cells.items():
        urls.append((cnum, text))
    for ref, url in hyperlinks.items():
        m = re.match(r"([A-Z]+)(\d+)", ref)
        if m and int(m.group(2)) == rownum:
            urls.append((_col_num(m.group(1)), url))
    urls.sort(key=lambda x: x[0])

    for _, u in urls:
        m = TMDB_RE.search(u)
        if m:
            return m.group(1), m.group(2), "tmdb-link"
    for _, u in urls:
        m = IMDB_RE.search(u)
        if m:
            hit = find_imdb(m.group(1))
            if hit:
                return hit[0], hit[1], "imdb-link"
            return None, None, f"imdb {m.group(1)} not found in TMDB"
    return None, None, "no TMDB or IMDB link"


# ---------- cell / row XML builders ----------

def _cell_xml(ref: str, kind: str, value) -> str:
    if value is None or value == "":
        return ""
    if kind == "n":
        try:
            num = int(value)
        except (TypeError, ValueError):
            return ""
        if num == 0:  # 0 runtime / id is "unknown", not a real value
            return ""
        return f'<c r="{ref}"><v>{num}</v></c>'
    return f'<c r="{ref}" t="inlineStr"><is><t xml:space="preserve">{_xesc(value)}</t></is></c>'


def _set_spans(attrs: str, last_col: int) -> str:
    if re.search(r'\bspans="[^"]*"', attrs):
        return re.sub(r'\bspans="[^"]*"', f'spans="1:{last_col}"', attrs)
    return attrs + f' spans="1:{last_col}"'


def _blank_cell(inner: str, ref: str) -> str:
    """Empty a cell's formula/value but keep its style attribute."""
    def repl(m):
        s = re.search(r'\bs="(\d+)"', m.group(1))
        return f'<c r="{ref}"{f" s={chr(34)}{s.group(1)}{chr(34)}" if s else ""}/>'
    inner, n = re.subn(rf'<c r="{ref}"([^>]*)>.*?</c>', repl, inner, count=1, flags=re.S)
    if n == 0:
        inner = re.sub(rf'<c r="{ref}"([^>]*?)/>', repl, inner, count=1)
    return inner


# ---------- main ----------

def enrich_workbook(xlsx_bytes: bytes, fetch_details, find_imdb):
    """Return (enriched_xlsx_bytes, report).

    fetch_details(media_type, tmdb_id) -> details dict (with the appends the
        app requests: credits/aggregate_credits, release_dates/content_ratings,
        external_ids).
    find_imdb(imdb_id) -> (media_type, tmdb_id) or None.

    report: list of {"row", "title", "status", "media_type", "tmdb_id",
    "message"} in sheet order, one per data row (status: matched / unresolved /
    error).
    """
    zin = zipfile.ZipFile(BytesIO(xlsx_bytes))
    ws_part, table_part = _find_data_sheet(zin)
    if not ws_part:
        raise ValueError("no worksheet found in workbook")
    rows, hyperlinks, header_style = _read_model(zin, ws_part)

    # header row + data range come from the table if present, else inferred
    if table_part and table_part in zin.namelist():
        tref = ET.fromstring(zin.read(table_part)).get("ref")  # e.g. A4:N374
        start, end = tref.split(":")
        header_row = int(re.search(r"\d+", start).group())
        last_row = int(re.search(r"\d+", end).group())
        old_last_col = _col_num(re.match(r"[A-Z]+", end).group())
    else:
        header_row = min(rows) if rows else 1
        last_row = max(rows) if rows else header_row
        old_last_col = max((max(c) for c in rows.values() if c), default=0)

    new_last_col = old_last_col + len(COLUMNS)
    old_end = _col_name(old_last_col)
    new_end = _col_name(new_last_col)

    # unique (case-insensitive) header names — the sheet already has a "Title"
    used = {v.lower() for v in rows.get(header_row, {}).values()}
    headers = []
    for name, _, _ in COLUMNS:
        final = name
        while final.lower() in used:
            final += "_tmdb"
        used.add(final.lower())
        headers.append(final)

    hstyle = header_style.get(old_last_col)  # reuse last header's style
    hstyle_attr = f' s="{hstyle}"' if hstyle else ""

    # resolve + fetch every data row
    details_cache: dict[tuple, dict] = {}
    report = []
    row_values: dict[int, list] = {}
    for rnum in range(header_row + 1, last_row + 1):
        cells = rows.get(rnum, {})
        title = cells.get(6) or cells.get(_col_num("F")) or ""  # col F "Title"
        mt, tid, how = _resolve_row(cells, hyperlinks, rnum, find_imdb)
        if not tid:
            report.append({"row": rnum, "title": title, "status": "unresolved",
                           "media_type": "", "tmdb_id": "", "message": how})
            continue
        key = (mt, tid)
        try:
            if key not in details_cache:
                details_cache[key] = fetch_details(mt, tid)
            d = details_cache[key]
        except Exception as exc:  # noqa: BLE001 - report, don't abort the batch
            report.append({"row": rnum, "title": title, "status": "error",
                           "media_type": mt, "tmdb_id": tid, "message": str(exc)})
            continue
        is_tv = mt == "tv"
        values = [extract(d, is_tv) for _, _, extract in COLUMNS]
        row_values[rnum] = values
        report.append({"row": rnum, "title": title, "status": "matched",
                       "media_type": mt, "tmdb_id": tid, "message": how})

    # ---- rewrite the worksheet XML ----
    ws_xml = zin.read(ws_part).decode("utf-8")

    def process_row(m):
        rowxml = m.group(0)
        attrs = m.group(1)
        rnum = int(re.search(r'\br="(\d+)"', attrs).group(1))
        if rnum < header_row or rnum > last_row:
            return rowxml
        self_close = rowxml.rstrip().endswith("/>") and "</row>" not in rowxml
        inner = "" if self_close else re.match(r"<row\b[^>]*>(.*)</row>\s*$", rowxml, re.S).group(1)
        attrs = _set_spans(attrs, new_last_col)

        if rnum == header_row:
            add = "".join(
                f'<c r="{_col_name(old_last_col + i + 1)}{rnum}"{hstyle_attr} t="inlineStr">'
                f'<is><t xml:space="preserve">{_xesc(h)}</t></is></c>'
                for i, h in enumerate(headers))
        else:
            for col in CLEAR_COLS:
                inner = _blank_cell(inner, f"{col}{rnum}")
            values = row_values.get(rnum)
            add = "" if not values else "".join(
                _cell_xml(f"{_col_name(old_last_col + i + 1)}{rnum}", COLUMNS[i][1], v)
                for i, v in enumerate(values))
        return f"<row{attrs}>{inner}{add}</row>"

    body = re.search(r"(<sheetData\b[^>]*>)(.*)(</sheetData>)", ws_xml, re.S)
    new_body = body.group(1) + re.sub(r"<row\b([^>]*)>.*?</row>|<row\b([^>]*)/>",
                                      process_row, body.group(2), flags=re.S) + body.group(3)
    ws_xml = ws_xml[:body.start()] + new_body + ws_xml[body.end():]
    # widen dimension + autofilter end columns
    ws_xml = re.sub(rf':{old_end}(\d+)"', rf':{new_end}\1"', ws_xml)

    # ---- rewrite the table XML ----
    table_xml = None
    if table_part and table_part in zin.namelist():
        table_xml = zin.read(table_part).decode("utf-8")
        table_xml = re.sub(rf':{old_end}(\d+)"', rf':{new_end}\1"', table_xml)
        ids = [int(x) for x in re.findall(r'<tableColumn[^>]*\bid="(\d+)"', table_xml)]
        next_id = (max(ids) + 1) if ids else 1
        cols_xml = "".join(
            f'<tableColumn id="{next_id + i}" name="{_xesc(h)}"/>'
            for i, h in enumerate(headers))
        table_xml = table_xml.replace("</tableColumns>", cols_xml + "</tableColumns>")
        table_xml = re.sub(r'(<tableColumns\b[^>]*\bcount=")\d+(")',
                           rf"\g<1>{old_last_col + len(COLUMNS)}\g<2>", table_xml)

    # ---- drop calcChain (blanked formula cells make it stale) ----
    drop = {"xl/calcChain.xml"}
    ct_xml = zin.read("[Content_Types].xml").decode("utf-8")
    ct_xml = re.sub(r'<Override PartName="/xl/calcChain\.xml"[^>]*/>', "", ct_xml)
    wbrels_part = "xl/_rels/workbook.xml.rels"
    wbrels = zin.read(wbrels_part).decode("utf-8")
    wbrels = re.sub(r'<Relationship[^>]*Target="calcChain\.xml"[^>]*/>', "", wbrels)

    replaced = {ws_part: ws_xml, "[Content_Types].xml": ct_xml, wbrels_part: wbrels}
    if table_xml is not None:
        replaced[table_part] = table_xml

    out = BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            if item.filename in drop:
                continue
            data = replaced.get(item.filename)
            if data is not None:
                zout.writestr(item, data.encode("utf-8"))
            else:
                zout.writestr(item, zin.read(item.filename))
    return out.getvalue(), report


# ---------- TMDB fetch layer (live, no cache) ----------

KEYS_FILE = Path.home() / ".config" / "search_shows" / "keys.json"
TMDB_BASE = "https://api.themoviedb.org/3"
MOVIE_APPEND = "credits,release_dates,external_ids"
TV_APPEND = "aggregate_credits,content_ratings,external_ids"


def _tmdb_key() -> str:
    return json.loads(KEYS_FILE.read_text())["tmdb"]


def _tmdb_get(path: str, **params) -> dict:
    resp = requests.get(f"{TMDB_BASE}{path}",
                        params={**params, "api_key": _tmdb_key()}, timeout=20)
    resp.raise_for_status()
    return resp.json()


def fetch_details(media_type: str, tmdb_id) -> dict:
    append = MOVIE_APPEND if media_type == "movie" else TV_APPEND
    return _tmdb_get(f"/{media_type}/{tmdb_id}", append_to_response=append)


def find_imdb(imdb_id: str):
    d = _tmdb_get(f"/find/{imdb_id}", external_source="imdb_id")
    for results, mt in ((d.get("movie_results"), "movie"), (d.get("tv_results"), "tv")):
        if results:
            return mt, str(results[0]["id"])
    return None


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.exit(__doc__)
    src = Path(argv[0]).expanduser()
    if not src.exists():
        sys.exit(f"no such file: {src}")
    out = (Path(argv[1]).expanduser() if len(argv) > 1
           else src.with_name(f"{src.stem} ENRICHED{src.suffix}"))
    if not KEYS_FILE.exists():
        sys.exit(f"keys file not found: {KEYS_FILE}")

    print(f"enriching {src.name} …", file=sys.stderr)
    enriched, report = enrich_workbook(src.read_bytes(), fetch_details, find_imdb)
    out.write_bytes(enriched)

    matched = [r for r in report if r["status"] == "matched"]
    unresolved = [r for r in report if r["status"] == "unresolved"]
    errors = [r for r in report if r["status"] == "error"]
    print(f"\n{len(report)} rows: {len(matched)} matched, "
          f"{len(unresolved)} unresolved, {len(errors)} error", file=sys.stderr)
    for label, group in (("unresolved", unresolved), ("errors", errors)):
        if group:
            print(f"\n{label}:", file=sys.stderr)
            for r in group:
                print(f"  row {r['row']}: {r['title'][:50]!r} — {r['message']}", file=sys.stderr)
    print(f"\nwrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
