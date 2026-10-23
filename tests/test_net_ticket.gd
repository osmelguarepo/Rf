extends "res://tests/test_case.gd"
## The match ticket (scripts/net/ticket.gd; docs/SPEC_ONLINE.md §16.2): signed with a shared key, bound to a match, a seat and a
## Steam id, and refused when it is expired, forged, for another seat or malformed. Dev tickets only on a --dev server.

const Ticket := preload("res://scripts/net/ticket.gd")

const NOW := 1000000
## Beyond 2^53: a Steam id must stay text.
const BIG_ID := "76561198123456789"


func _issuer() -> Ticket:
	return Ticket.new("secret-A", false)


func test_a_valid_ticket_gives_back_what_it_was_issued_with() -> void:
	var ticket := _issuer().issue("match-1", 2, BIG_ID, 4000000000, NOW + 60, 6, 0b000111)
	var got := _issuer().verify(ticket, NOW)
	assert_true(got["ok"])
	assert_eq(got["match_id"], "match-1")
	assert_eq(got["seat"], 2)
	assert_eq(got["steam_id"], BIG_ID, "the Steam id is text all the way")
	assert_eq(got["seed"], 4000000000)
	assert_eq(got["seats"], 6)
	assert_eq(got["humans"], 0b000111)
	assert_eq(got["expiry"], NOW + 60)


func test_an_expired_ticket_is_refused() -> void:
	var ticket := _issuer().issue("m", 0, "1", 5, NOW - 1, 6, 1)
	assert_eq(_issuer().verify(ticket, NOW)["error"], Ticket.ERR_EXPIRED)
	assert_true(_issuer().verify(_issuer().issue("m", 0, "1", 5, NOW, 6, 1), NOW)["ok"], "valid up to and including its expiry")


func test_a_ticket_signed_with_another_key_is_refused() -> void:
	var ticket := Ticket.new("secret-B", false).issue("m", 0, "1", 5, NOW + 60, 6, 1)
	assert_eq(_issuer().verify(ticket, NOW)["error"], Ticket.ERR_SIGNATURE)


func test_a_ticket_for_another_seat_does_not_pass_as_this_seat() -> void:
	var ticket := _issuer().issue("m", 1, "1", 5, NOW + 60, 6, 0b11)
	# Changing the seat in the text breaks the signature.
	var parts := ticket.split(".")
	parts[2] = "0"
	assert_eq(_issuer().verify(".".join(parts), NOW)["error"], Ticket.ERR_SIGNATURE)
	# A signed ticket for a seat that is no person's, or past the cars, is no ticket either.
	assert_eq(_issuer().verify(_issuer().issue("m", 2, "1", 5, NOW + 60, 6, 0b11), NOW)["error"], Ticket.ERR_SEAT)
	assert_eq(_issuer().verify(_issuer().issue("m", 6, "1", 5, NOW + 60, 6, 0b111111), NOW)["error"], Ticket.ERR_SEAT)


func test_changing_any_field_breaks_the_signature() -> void:
	var ticket := _issuer().issue("m", 1, "123", 5, NOW + 60, 6, 0b11)
	var parts := ticket.split(".")
	for index: int in [1, 3, 4, 5, 6, 7]:
		var forged := parts.duplicate()
		forged[index] = forged[index] + "1" if index in [1, 3] else str(int(forged[index]) + 1)
		var got := _issuer().verify(".".join(forged), NOW)
		assert_false(got["ok"], "field %d" % index)


func test_unsigned_dev_tickets_need_a_dev_server() -> void:
	var dev := Ticket.issue_dev("m", 3, BIG_ID, 9, 6, 0b1000)
	assert_eq(Ticket.new("", false).verify(dev, NOW)["error"], Ticket.ERR_UNSIGNED)
	var got := Ticket.new("", true).verify(dev, NOW)
	assert_true(got["ok"])
	assert_eq(got["steam_id"], BIG_ID)
	assert_eq(got["seat"], 3)
	assert_false(Ticket.new("k", false).verify("dev.m.0.1.5.0.6.1", NOW)["ok"])


func test_a_dev_server_still_checks_signed_tickets() -> void:
	var dev_server := Ticket.new("secret-A", true)
	var forged := Ticket.new("other", false).issue("m", 0, "1", 5, NOW + 60, 6, 1)
	assert_eq(dev_server.verify(forged, NOW)["error"], Ticket.ERR_SIGNATURE)
	assert_true(dev_server.verify(_issuer().issue("m", 0, "1", 5, NOW + 60, 6, 1), NOW)["ok"])


func test_malformed_tickets_are_refused_without_errors() -> void:
	var bad: Array[String] = [
		"", "x", "v1", "v1.a.b.c", "v1.m.0.1.5.9.6.1", "v1.m.0.1.5.9.6.1.sig.extra", "v1.m.0.abc.5.99999999.6.1.00",
		"v1.m.-1.1.5.99999999.6.1.00", "v1.m e.0.1.5.99999999.6.1.00", "dev.m.0.1.5.0.6", "dev.m.0.1.5.0.6.1.x",
		"v1..0.1.5.99999999.6.1.00", "v1.m.0.1.5.99999999.0.1.00", "v1.m.0.1.5.99999999.9.1.00", "ü.m.0.1.5.0.6.1",
		"v1.m.0.99999999999999999999.5.99999999.6.1.00", "v1.m.0.1.5.99999999.6.1.0",
	]
	var server := Ticket.new("k", true)
	for text in bad:
		var got := server.verify(text, NOW)
		assert_false(got["ok"], text)
		assert_true(got.has("error"))
	assert_false(server.verify("v1." + "a".repeat(400), NOW)["ok"], "long tickets are cut off early")


func test_the_signature_is_the_hmac_sha256_of_the_rest() -> void:
	var ticket := Ticket.new("key", false)
	assert_eq(
		ticket.sign_text("The quick brown fox jumps over the lazy dog"),
		"f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
		"the standard HMAC-SHA256 test vector"
	)
