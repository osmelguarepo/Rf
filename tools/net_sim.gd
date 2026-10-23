extends SceneTree
## A room and N simulated clients over the loopback with a degraded network, measured (docs/SPEC_ONLINE.md §13 M2, §16.7: the
## gates of M2 are the size of the correction in pixels, the depth of the resimulation and the frame time). Pure simulation on a
## virtual clock, no window, no sockets:
##
##   godot --headless --path . -s res://tools/net_sim.gd [-- OPTION...]
##
## Options (defaults in brackets): --clients=N [6], --latency=MS one way [150], --jitter=MS [30], --loss=P chance that a packet
## needs a retransmission, 0..1 [0.02], --stall=MS a stall of that length on a few clients every 20 s of the match [1200] (0 for
## none), --slow=MS one extra client with this one-way latency, to see that it harms nobody [0], --races=N [3], --race-px=PX [1800],
## --seed=N [7], --max-seconds=N of virtual time [900], --no-hash (do not compare every confirmed state with the server's: faster).
##
## It prints, per client: rollbacks, the depth of each in ticks (median, 95th, 99th, largest), the correction in px (how far a
## car moved when a rollback replaced the prediction: the largest of any car and of the player's own), the frame time of the
## client's update in microseconds (median, 99th, largest), resyncs, late inputs; and for the server the time a Match.step took and
## whether every client's confirmed state matched the server's at every tick. Exit code 0 when they all matched with no resync, 1
## when not. Run the project's import once first (tools/test.sh does), as for every tool.

const Harness := preload("res://tools/net_harness.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const Rollback := preload("res://scripts/net/rollback.gd")
const Room := preload("res://scripts/server/room.gd")


func _initialize() -> void:
	var clients := int(_arg("clients", "6"))
	var latency := int(_arg("latency", "150"))
	var jitter := int(_arg("jitter", "30"))
	var loss := float(_arg("loss", "0.02"))
	var stall := int(_arg("stall", "1200"))
	var slow := int(_arg("slow", "0"))
	var races := int(_arg("races", "3"))
	var race_px := float(_arg("race-px", "1800"))
	var max_ms := int(_arg("max-seconds", "900")) * 1000
	var hash_states := not OS.get_cmdline_user_args().has("--no-hash")
	var total := clients + (1 if slow > 0 else 0)
	var h := Harness.new({
		"humans": (1 << total) - 1, "seat_count": total, "seed_value": int(_arg("seed", "7")),
		"tuning": {"race_finish_px": race_px, "match_races": races}, "track_hashes": hash_states,
	})
	for seat in clients:
		h.add_client(seat, latency, jitter, loss)
	if slow > 0:
		h.add_client(clients, slow, jitter, loss)
	print("net_sim: %d clients, %d ms one way, %d ms jitter, %.1f%% retransmissions, stalls %d ms, %d races of %d px" % [
		total, latency, jitter, loss * 100.0, stall, races, int(race_px),
	])
	var real_start := Time.get_ticks_msec()
	var next_stall := 20000
	var room: Room = null
	while h.now_ms < max_ms:
		h.step()
		room = h.room()
		if stall > 0 and h.now_ms >= next_stall:
			next_stall += 20000
			h.clients[floori(next_stall / 20000.0) % clients].link.stall(stall)
		if room != null and room.phase == Room.Phase.ENDED:
			break
	h.run_ms(3000)
	var real_ms := Time.get_ticks_msec() - real_start
	var all_ok := room != null and room.phase == Room.Phase.ENDED
	print("match: %d ticks (%.1f s of game), %.1f s of real time, %s" % [
		room.tick - room.start_tick if room != null else 0, float(room.tick - room.start_tick) / 60.0 if room != null else 0.0,
		float(real_ms) / 1000.0, "ended" if all_ok else "DID NOT END",
	])
	if room != null:
		print("server: Match.step %.0f us on average, %d us at most; late inputs %d, dropped far-future %d, skipped ticks %d" % [
			float(room.step_total_us) / maxf(float(room.steps_run), 1.0), room.step_max_us, room.counters.get("late_inputs", 0),
			room.counters.get("future_dropped", 0), room.counters.get("skipped_ticks", 0),
		])
	var all_depths: Array = []
	var all_corrections: Array = []
	var all_own: Array = []
	var all_frames: Array = []
	for c in h.clients:
		var rb: Rollback = c.session.rollback
		all_depths.append_array(rb.depths)
		all_corrections.append_array(rb.corrections)
		all_own.append_array(rb.own_corrections)
		all_frames.append_array(c.frame_us)
		var compared: Dictionary = h.compare(c) if hash_states else {"checked": 0, "mismatches": 0}
		var ok: bool = compared["mismatches"] == 0 and c.session.resyncs == 0 and c.session.desyncs == 0 and c.session.state == OnlineSession.State.ENDED
		all_ok = all_ok and ok
		print("seat %d (%3d ms): rollbacks %4d  depth p50/p95/p99/max %2d/%2d/%2d/%2d ticks  correction max %5.1f px (own %5.1f)  frame p50/p99/max %4d/%5d/%5d us  resyncs %d  checked %d  %s" % [
			c.seat, c.latency, rb.rebuilds, _p(rb.depths, 0.5), _p(rb.depths, 0.95), _p(rb.depths, 0.99), _p(rb.depths, 1.0),
			_pf(rb.corrections, 1.0), _pf(rb.own_corrections, 1.0), _p(c.frame_us, 0.5), _p(c.frame_us, 0.99), _p(c.frame_us, 1.0),
			c.session.resyncs, compared["checked"], "OK" if ok else "FAIL",
		])
	print("all clients: depth p99 %d ticks (max %d); correction p99 %.1f px, max %.1f px (the player's own car: p99 %.1f, max %.1f); frame time p99 %d us, max %d us" % [
		_p(all_depths, 0.99), _p(all_depths, 1.0), _pf(all_corrections, 0.99), _pf(all_corrections, 1.0),
		_pf(all_own, 0.99), _pf(all_own, 1.0), _p(all_frames, 0.99), _p(all_frames, 1.0),
	])
	print("net_sim: %s" % ("PASS" if all_ok else "FAIL"))
	h.dispose()
	quit(0 if all_ok else 1)


static func _arg(name: String, fallback: String) -> String:
	var prefix := "--%s=" % name
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


static func _p(values: Array, p: float) -> int:
	return roundi(Harness.percentile(values, p))


static func _pf(values: Array, p: float) -> float:
	return Harness.percentile(values, p)
