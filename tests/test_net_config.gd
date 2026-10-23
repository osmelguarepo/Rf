extends "res://tests/test_case.gd"
## What server and clients agree on (scripts/net/net_config.gd; docs/SPEC_ONLINE.md §16.1 7): the rules travel in WELCOME, the
## digest of them travels in CHECKSUM, and the hash of the simulation in HELLO.

const NetConfig := preload("res://scripts/net/net_config.gd")
const Config := preload("res://scripts/sim/config.gd")
const Match := preload("res://scripts/sim/match.gd")


func test_the_default_rules_are_the_games() -> void:
	var cfg := NetConfig.build(NetConfig.encode())
	assert_eq(cfg.race_finish_px, Config.game().race_finish_px)
	assert_eq(cfg.match_races, 3)
	assert_eq(NetConfig.build(PackedByteArray()).race_finish_px, Config.game().race_finish_px, "no bytes: the defaults")


func test_tuning_travels_and_changes_the_digest() -> void:
	var plain := NetConfig.build(NetConfig.encode())
	var tuned := NetConfig.build(NetConfig.encode({"race_finish_px": 2500.0, "match_races": 2, "nitro_top": 500.0}))
	assert_eq(tuned.race_finish_px, 2500.0)
	assert_eq(tuned.match_races, 2, "an integer rule stays an integer")
	assert_eq(typeof(tuned.match_races), TYPE_INT)
	assert_eq(tuned.nitro_top, 500.0)
	assert_ne(NetConfig.digest(plain), NetConfig.digest(tuned))
	assert_eq(NetConfig.digest(plain), NetConfig.digest(NetConfig.build(NetConfig.encode())), "the same rules, the same digest")


func test_values_stay_inside_the_dashboards_ranges_and_unknown_keys_are_dropped() -> void:
	var cfg := NetConfig.build(NetConfig.encode({"match_races": 999.0, "time_scale": 4.0, "bogus": 1.0, "race_finish_px": "text"}))
	assert_eq(cfg.match_races, 9)
	assert_eq(cfg.race_finish_px, Config.game().race_finish_px)
	assert_eq(NetConfig.keys().has("time_scale"), false, "the clock speed is the app's, not a rule")


func test_bytes_that_are_not_rules_give_null() -> void:
	assert_null(NetConfig.build(var_to_bytes([1, 2])))
	assert_null(NetConfig.build(var_to_bytes({"match_races": "many"})))
	assert_null(NetConfig.build(var_to_bytes({"bogus": 1.0})))


func test_the_hash_of_the_simulation_is_fixed_and_follows_the_rules() -> void:
	assert_eq(NetConfig.sim_hash(), NetConfig.sim_hash())
	assert_between(NetConfig.sim_hash(), 0, 0xFFFFFFFF)
	assert_eq(NetConfig.checksum32(Match.create(Config.game(), 1, 3, 1)), NetConfig.checksum32(Match.create(Config.game(), 1, 3, 1)))
	assert_ne(NetConfig.checksum32(Match.create(Config.game(), 1, 3, 1)), NetConfig.checksum32(Match.create(Config.game(), 2, 3, 1)))
