class_name YgoDeckPoints
extends RefCounted
## Genesys-style deck building points: a versioned, replaceable points table (JSON written by
## scripts/import_genesys_points.py) and a deck total checked against a cap. Separate from
## .ydk parsing (YgoContent.load_ydk) and from the duel itself.
##
## Counted sections are a project decision (2026-10-06): main + extra deck, every copy counts.
## The side deck is not counted, unlike official Genesys. Only point values are used; the
## Genesys card pool restrictions are not applied.

const FORMAT := "ygo-pve-points/1"
const COUNTED_SECTIONS := ["main", "extra"]

var version := ""
var source := ""
var unlisted_points := 0 ## what the table itself declares for cards it does not list
var points := {} ## int code -> int points


## Returns null and appends a message to `error` if the file is missing, malformed, or does not
## declare unlisted_points (missing points are never silently treated as 0).
static func load_table(path: String, error: Array) -> YgoDeckPoints:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		error.append("cannot read points table %s" % path)
		return null
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or data.get("format") != FORMAT:
		error.append("%s is not a %s points table" % [path, FORMAT])
		return null
	if not data.has("unlisted_points") or not typeof(data.unlisted_points) in [TYPE_INT, TYPE_FLOAT]:
		error.append("points table %s does not declare unlisted_points" % path)
		return null
	var table := YgoDeckPoints.new()
	table.version = data.get("version", "")
	table.source = data.get("source", "")
	table.unlisted_points = int(data.unlisted_points)
	var listed: Dictionary = data.get("points", {})
	for code in listed:
		table.points[int(code)] = int(listed[code])
	return table


## deck: {main: [codes], extra: [codes], ...} as returned by YgoContent.load_ydk.
## Returns {total, cap, ok, errors: [String], lines: [{code, name, copies, each, total, listed}]}.
## Unknown card codes are errors; cards the table does not list use unlisted_points.
func evaluate(deck: Dictionary, cap: int, content: YgoContent) -> Dictionary:
	var copies := {}
	for section in COUNTED_SECTIONS:
		for code in deck.get(section, []):
			copies[int(code)] = copies.get(int(code), 0) + 1
	var errors := []
	var lines := []
	var total := 0
	for code: int in copies:
		var info := content.card_info(code)
		if not info.get("found", false):
			errors.append("unknown card code %d" % code)
			continue
		var listed_as: int = code if points.has(code) else int(info.alias) # alternate artworks
		var listed := points.has(listed_as)
		var each: int = points[listed_as] if listed else unlisted_points
		total += each * copies[code]
		lines.append({"code": code, "name": info.name, "copies": copies[code], "each": each,
			"total": each * copies[code], "listed": listed})
	lines.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.total > b.total or (a.total == b.total and a.name < b.name))
	if total > cap:
		errors.append("deck uses %d points, the cap is %d" % [total, cap])
	return {"total": total, "cap": cap, "ok": errors.is_empty(), "errors": errors, "lines": lines}
