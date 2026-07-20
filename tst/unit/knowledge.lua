-- tst/unit/knowledge.lua
-- Unit tests for src/knowledge.lua's pure math/heuristics: the
-- reinforcement formula, tier-promotion thresholds, and the
-- rule-based review gates -- all ported from a Fossil SCM fork's
-- ai_note/ai_retrieval system (see knowledge.lua's own header).

knowledge = require("knowledge")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_reinforcement_delta_matches_tier_weights()
    print("Testing reinforcement_delta for each tier")
    check(knowledge.reinforcement_delta(0) == 0.15, "tier 0 should be 0.15, got " .. tostring(knowledge.reinforcement_delta(0)))
    check(knowledge.reinforcement_delta(1) == 0.25, "tier 1 should be 0.25, got " .. tostring(knowledge.reinforcement_delta(1)))
    check(knowledge.reinforcement_delta(2) == 0.35, "tier 2 should be 0.35, got " .. tostring(knowledge.reinforcement_delta(2)))
    check(knowledge.reinforcement_delta(3) == 0.50, "tier 3 should be 0.50, got " .. tostring(knowledge.reinforcement_delta(3)))
end

function test_promotion_tier_0_to_1_at_two_retrievals()
    print("Testing promotion from tier 0 to 1 at retrieval_count >= 2")
    check(knowledge.promotion_target_tier(0, 1, 1.0, false, "ok") == 0, "1 retrieval should not promote")
    check(knowledge.promotion_target_tier(0, 2, 1.0, false, "ok") == 1, "2 retrievals should promote to tier 1")
end

function test_promotion_tier_1_to_2_requires_count_heat_and_atomicity()
    print("Testing promotion from tier 1 to 2 requires count>=4, heat>=1.60, and atomicity ok")
    check(knowledge.promotion_target_tier(1, 4, 1.60, false, "ok") == 2, "count=4, heat=1.60, ok atomicity should promote to tier 2")
    check(knowledge.promotion_target_tier(1, 3, 1.60, false, "ok") == 1, "count=3 should not promote (below threshold)")
    check(knowledge.promotion_target_tier(1, 4, 1.59, false, "ok") == 1, "heat=1.59 should not promote (below threshold)")
    check(knowledge.promotion_target_tier(1, 4, 1.60, false, "needs-split") == 1, "needs-split atomicity should block promotion to tier 2")
end

function test_promotion_tier_2_to_3_requires_count_heat_and_ok_atomicity()
    print("Testing promotion from tier 2 to 3 requires count>=7, heat>=2.60, and atomicity == ok")
    check(knowledge.promotion_target_tier(2, 7, 2.60, false, "ok") == 3, "count=7, heat=2.60, ok atomicity should promote to tier 3")
    check(knowledge.promotion_target_tier(2, 6, 2.60, false, "ok") == 2, "count=6 should not promote (below threshold)")
    check(knowledge.promotion_target_tier(2, 7, 2.59, false, "ok") == 2, "heat=2.59 should not promote (below threshold)")
    check(knowledge.promotion_target_tier(2, 7, 2.60, false, "thin") == 2, "non-ok atomicity should block promotion to tier 3")
end

function test_promotion_duplicate_never_advances()
    print("Testing a duplicate note never advances tier regardless of other inputs")
    check(knowledge.promotion_target_tier(0, 100, 100.0, true, "ok") == 0, "duplicate should stay at tier 0 even with huge count/heat")
    check(knowledge.promotion_target_tier(2, 100, 100.0, true, "ok") == 2, "duplicate should stay at its current tier, not advance")
end

function test_atomicity_needs_split_on_multiple_headings()
    print("Testing atomicity_status flags multiple headings as needs-split")
    body = "# First heading\nSome text.\n\n# Second heading\nMore text."
    check(knowledge.atomicity_status(body) == "needs-split", "2 headings should be needs-split, got " .. knowledge.atomicity_status(body))
end

function test_atomicity_needs_split_on_many_paragraphs()
    print("Testing atomicity_status flags more than 6 paragraphs as needs-split")
    body = "P1.\n\nP2.\n\nP3.\n\nP4.\n\nP5.\n\nP6.\n\nP7."
    check(knowledge.atomicity_status(body) == "needs-split", "7 paragraphs should be needs-split, got " .. knowledge.atomicity_status(body))
end

function test_atomicity_thin_on_short_single_paragraph()
    print("Testing atomicity_status flags a short single paragraph as thin")
    check(knowledge.atomicity_status("Too short.") == "thin", "short single paragraph should be thin")
end

function test_atomicity_ok_on_normal_body()
    print("Testing atomicity_status is ok for a normal single-heading multi-paragraph body")
    body = "# Heading\n\nThis is a real paragraph with enough content to not be thin.\n\nAnd a second paragraph here."
    check(knowledge.atomicity_status(body) == "ok", "normal body should be ok, got " .. knowledge.atomicity_status(body))
end

function test_connectivity_status_format()
    print("Testing connectivity_status formats peer count")
    check(knowledge.connectivity_status(3) == "linked-3", "expected linked-3, got " .. knowledge.connectivity_status(3))
    check(knowledge.connectivity_status(0) == "linked-0", "expected linked-0, got " .. knowledge.connectivity_status(0))
end

function test_title_is_generic_case_insensitive()
    print("Testing title_is_generic detects generic titles case-insensitively")
    check(knowledge.title_is_generic("Note") == true, "'Note' should be generic")
    check(knowledge.title_is_generic("UNTITLED NOTE") == true, "'UNTITLED NOTE' should be generic")
    check(knowledge.title_is_generic("") == true, "empty string should be generic")
    check(knowledge.title_is_generic(nil) == true, "nil should be generic")
    check(knowledge.title_is_generic("Bioreactor cleaning steps") == false, "a real title should not be generic")
end

function test_guess_title_skips_heading_uses_first_real_line()
    print("Testing guess_title_from_body skips the heading and uses the first real line")
    title = knowledge.guess_title_from_body("# Heading\n\nFirst real line here.")
    check(title == "First real line here.", "expected 'First real line here.', got '" .. tostring(title) .. "'")
end

function test_guess_title_strips_bullet_decoration()
    print("Testing guess_title_from_body strips leading bullet/quote decoration")
    title = knowledge.guess_title_from_body("- A bulleted first line")
    check(title == "A bulleted first line", "expected stripped bullet, got '" .. tostring(title) .. "'")
end

function test_guess_title_truncates_long_lines_on_word_boundary()
    print("Testing guess_title_from_body truncates a long line on a word boundary")
    long_line = "This is a very long first line that definitely exceeds the seventy two character budget we allow"
    title = knowledge.guess_title_from_body(long_line)
    check(string.len(title) <= 72, "truncated title should be <= 72 chars, got " .. string.len(title))
    check(string.sub(title, -1) != " ", "truncated title should not end with a trailing space")
end

function test_guess_title_empty_body_returns_untitled()
    print("Testing guess_title_from_body falls back to 'Untitled note' for empty/nil body")
    check(knowledge.guess_title_from_body(nil) == "Untitled note", "nil body should return 'Untitled note'")
    check(knowledge.guess_title_from_body("") == "Untitled note", "empty body should return 'Untitled note'")
end

function test_content_hash_is_deterministic()
    print("Testing content_hash is deterministic and content-sensitive")
    check(knowledge.content_hash("hello world") == knowledge.content_hash("hello world"), "same content should hash the same")
    check(knowledge.content_hash("hello world") != knowledge.content_hash("hello there"), "different content should hash differently")
end

-- Run them
test_reinforcement_delta_matches_tier_weights()
test_promotion_tier_0_to_1_at_two_retrievals()
test_promotion_tier_1_to_2_requires_count_heat_and_atomicity()
test_promotion_tier_2_to_3_requires_count_heat_and_ok_atomicity()
test_promotion_duplicate_never_advances()
test_atomicity_needs_split_on_multiple_headings()
test_atomicity_needs_split_on_many_paragraphs()
test_atomicity_thin_on_short_single_paragraph()
test_atomicity_ok_on_normal_body()
test_connectivity_status_format()
test_title_is_generic_case_insensitive()
test_guess_title_skips_heading_uses_first_real_line()
test_guess_title_strips_bullet_decoration()
test_guess_title_truncates_long_lines_on_word_boundary()
test_guess_title_empty_body_returns_untitled()
test_content_hash_is_deterministic()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All knowledge.lua tests passed")
