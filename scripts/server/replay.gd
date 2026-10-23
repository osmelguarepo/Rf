extends RefCounted
## A match replay (docs/SPEC_ONLINE.md §9, §16.1): the seed, the rules, the seats and the canonical input stream, one byte
## per seat and step exactly as the server fed them to Match.step() (bot bytes and the server's confirm presses
## included), deflated. The simulation is deterministic, so run() reproduces the match and its final checksum: that is
## what the offline review of a match does. A few KB per match.

const NetConfig := preload("res://scripts/net/net_config.gd")

const FORMAT := 1


## `info`: seed, cfg (the WELCOME config bytes), cfg_digest, seats, humans, steps, final_checksum, match_id, sim_hash.
## `stream` has seats x steps bytes.
static func build(info: Dictionary, stream: PackedByteArray) -> PackedByteArray:
	var data := info.duplicate()
	data["format"] = FORMAT
	data["stream_size"] = stream.size()
	data["stream"] = stream.compress(FileAccess.COMPRESSION_DEFLATE)
	return var_to_bytes(data)


## The replay's header and its stream, or {} if the bytes are not a replay of this format.
static func parse(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 8:
		return {}
	var data: Variant = bytes_to_var(bytes)
	if not (data is Dictionary) or data.get("format") != FORMAT:
		return {}
	for key: String in ["seed", "cfg", "seats", "humans", "steps", "final_checksum", "stream", "stream_size"]:
		if not data.has(key):
			return {}
	var size: int = data["stream_size"]
	var packed: PackedByteArray = data["stream"]
	var stream := packed.decompress(size, FileAccess.COMPRESSION_DEFLATE)
	if stream.size() != size or size != int(data["seats"]) * int(data["steps"]):
		return {}
	var info: Dictionary = data.duplicate()
	info["stream"] = stream
	return info


## Plays a replay again. Returns {"ok": bool, "checksum": String (the replayed match's), "expected": String, "match"}.
static func run(bytes: PackedByteArray) -> Dictionary:
	var info := parse(bytes)
	if info.is_empty():
		return {"ok": false, "checksum": "", "expected": ""}
	var cfg := NetConfig.build(info["cfg"])
	if cfg == null:
		return {"ok": false, "checksum": "", "expected": ""}
	var seats: int = info["seats"]
	var m := NetConfig.new_match(cfg, info["seed"], seats, info["humans"])
	if m == null:
		return {"ok": false, "checksum": "", "expected": ""}
	var stream: PackedByteArray = info["stream"]
	var steps: int = info["steps"]
	for step in steps:
		m.step(stream.slice(step * seats, (step + 1) * seats), true)
	var expected: String = info["final_checksum"]
	return {"ok": m.checksum() == expected, "checksum": m.checksum(), "expected": expected, "match": m}
