# search_adv web GUI follow-ups — all done 2026-07-16

All five tweaks from the original list are implemented in search_adv_web.html:

1. Actor hot-links in cast tables — clicking an actor name switches to
   --actor mode, fills the query, and fires /api/run (no reload).
2. Inline help beside the no-cache / no-resolve checkboxes.
3. Empty-stdout runs (e.g. --validate on an unparseable reference) now show
   the CLI's stderr message instead of an empty result. Root cause: the CLI
   prints "no confident show match" to stderr and exits 0.
4. site/exclude help moved inline under those fields.
5. Examples panel revised (--cast / --actor / Validate sections; domain
   filters section removed).

Not yet live-tested in a browser (JS syntax-checked only) — user runs live
tests. Server binds 0.0.0.0:5025 (port 5000 is macOS AirPlay).
