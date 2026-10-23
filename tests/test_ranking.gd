extends "res://tests/test_case.gd"
## The ranking (scripts/sim/ranking.gd, scripts/app/ranking_store.gd; docs/SPEC_RANKING.md): the table of changes by
## place, the floor at 0, the divisions, and the session's store.

const Ranking := preload("res://scripts/sim/ranking.gd")
const RankingStore := preload("res://scripts/app/ranking_store.gd")


func test_every_table_is_symmetric_so_a_field_gains_what_it_loses() -> void:
	for field: int in range(2, 7):
		var total := 0
		for place in field:
			total += Ranking.delta(field, place)
			assert_eq(Ranking.delta(field, place), -Ranking.delta(field, field - 1 - place), "%d cars, place %d" % [field, place])
		assert_eq(total, 0, "%d cars: zero sum" % field)


func test_the_table_is_best_to_worst() -> void:
	for field: int in range(2, 7):
		for place in field - 1:
			assert_gt(Ranking.delta(field, place), Ranking.delta(field, place + 1))
	assert_eq([Ranking.delta(6, 0), Ranking.delta(6, 5)], [30, -30])
	assert_eq(Ranking.delta(5, 2), 0, "the middle of an odd field stays level")
	assert_eq([Ranking.delta(1, 0), Ranking.delta(7, 0), Ranking.delta(6, 6), Ranking.delta(6, -1)], [0, 0, 0, 0])


func test_the_total_never_goes_below_zero() -> void:
	assert_eq(Ranking.apply(10, -30), 0)
	assert_eq(Ranking.apply(0, -30), 0)
	assert_eq(Ranking.apply(10, 30), 40)


func test_divisions_change_at_their_thresholds() -> void:
	var cases := {0: 0, 299: 0, 300: 1, 699: 1, 700: 2, 1199: 2, 1200: 3, 1799: 3, 1800: 4, 99999: 4}
	for points: int in cases:
		assert_eq(Ranking.division(points), cases[points], "%d points" % points)
	assert_eq(Ranking.division_name(0), "BRONZE")
	assert_eq(Ranking.division_name(1800), "DIAMOND")
	assert_eq(Ranking.points_to_next(250), 50)
	assert_eq(Ranking.points_to_next(5000), -1, "nothing above diamond")


func test_a_new_player_starts_at_zero() -> void:
	var store := RankingStore.new()
	assert_eq(store.record("seat:0")["points"], 0)
	assert_eq(store.record("seat:0")["matches"], 0)


func test_the_store_applies_changes_and_reports_before_and_after() -> void:
	var store := RankingStore.new()
	assert_eq(store.apply("seat:0", "P1", 30), {"before": 0, "after": 30, "delta": 30})
	assert_eq(store.apply("seat:0", "P1", -50), {"before": 30, "after": 0, "delta": -30}, "the change actually applied")
	assert_eq(store.record("seat:0")["matches"], 2)
	assert_eq(store.record("seat:0")["name"], "P1")


func test_top_lists_the_best_first() -> void:
	var store := RankingStore.new()
	store.apply("seat:2", "P3", 10)
	store.apply("seat:0", "P1", 30)
	store.apply("seat:1", "P2", 10)
	var ids: Array = []
	for r: Dictionary in store.top(2):
		ids.append(r["id"])
	assert_eq(ids, ["seat:0", "seat:1"], "most points first, then by id; only the best 2")
	assert_eq(store.top(10).size(), 3)
