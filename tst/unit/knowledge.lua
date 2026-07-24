-- tst/unit/knowledge.lua
-- Unit tests for src/knowledge.lua's remaining pure heuristics: reply
-- classification for chat evaluation (task #87). The tier/heat/dedup
-- heuristics that used to live here moved to src/document.lua under
-- task #106 (see tst/unit/document.lua) when knowledge_note was
-- collapsed into `document` directly.

knowledge = require("knowledge")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_reply_has_visible_reasoning_detects_markers()
    print("Testing reply_has_visible_reasoning detects <think> tags and 'Thinking...' prefix")
    check(knowledge.reply_has_visible_reasoning("<think>some reasoning</think>Final answer") == true, "should detect <think> tag")
    check(knowledge.reply_has_visible_reasoning("Thinking...\nStep 1...") == true, "should detect 'Thinking...' marker")
    check(knowledge.reply_has_visible_reasoning("A plain final answer.") == false, "plain text should not be flagged")
    check(knowledge.reply_has_visible_reasoning(nil) == false, "nil should not be flagged")
    check(knowledge.reply_has_visible_reasoning("") == false, "empty string should not be flagged")
end

function test_classify_reply_four_way_split()
    print("Testing classify_reply's four-way classification (error/reasoning-visible/final/empty)")
    kind, quality, reasoning = knowledge.classify_reply(true, nil)
    check(kind == "error" and quality == "error" and reasoning == "none",
        "error case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))

    kind, quality, reasoning = knowledge.classify_reply(false, "<think>reasoning</think>answer")
    check(kind == "reasoning-visible" and quality == "review" and reasoning == "visible",
        "reasoning-visible case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))

    kind, quality, reasoning = knowledge.classify_reply(false, "A clean final answer.")
    check(kind == "final" and quality == "ok" and reasoning == "none",
        "final case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))

    kind, quality, reasoning = knowledge.classify_reply(false, "")
    check(kind == "empty" and quality == "empty" and reasoning == "none",
        "empty case classified wrong: " .. tostring(kind) .. "/" .. tostring(quality) .. "/" .. tostring(reasoning))
end

function test_co_retrieval_eligible_threshold_and_hub_ratio()
    print("Testing co_retrieval_eligible's absolute threshold + hub-ratio guard (task #109)")
    -- Below the absolute threshold (3) at all -- never eligible
    -- regardless of how favorable the ratio would be.
    check(knowledge.co_retrieval_eligible(2, 2, 2) == false, "co_count below CO_RETRIEVAL_LINK_THRESHOLD should never be eligible")
    -- Clears the threshold, and co_count(3)/min(4,10)=0.75 clears the
    -- 0.25 hub ratio comfortably.
    check(knowledge.co_retrieval_eligible(3, 4, 10) == true, "threshold met + healthy ratio should be eligible")
    -- A hub document: co_count(3) clears the absolute threshold, but
    -- its own retrieval_count(50) is so high that 3/50 = 0.06 falls
    -- well under the 0.25 ratio guard -- must NOT be eligible.
    check(knowledge.co_retrieval_eligible(3, 50, 4) == false, "a hub document's low co_count/retrieval_count ratio should be rejected")
    -- Both retrieval_counts zero (shouldn't really happen alongside a
    -- real co_count, but must not divide by zero/crash).
    check(knowledge.co_retrieval_eligible(3, 0, 0) == false, "both retrieval_counts zero should be rejected, not error")
end

function test_due_for_link_review_first_time_and_reevaluation_step()
    print("Testing due_for_link_review's first-time/decline/re-evaluation-step logic (task #109)")
    check(knowledge.due_for_link_review(nil, 3) == true, "a never-reviewed pair should be due")
    check(knowledge.due_for_link_review({decision = "linked", last_co_count = 3}, 10) == false, "an already-linked pair should never be re-evaluated")
    check(knowledge.due_for_link_review({decision = "declined", last_co_count = 3}, 4) == false, "co_count only 1 past a decline (< CO_RETRIEVAL_REEVALUATION_STEP=3) should not be due yet")
    check(knowledge.due_for_link_review({decision = "declined", last_co_count = 3}, 6) == true, "co_count exactly last_co_count + CO_RETRIEVAL_REEVALUATION_STEP should be due")
    check(knowledge.due_for_link_review({decision = "declined", last_co_count = 3}, 9) == true, "co_count well past the re-evaluation step should be due")
end

-- Run them
test_reply_has_visible_reasoning_detects_markers()
test_classify_reply_four_way_split()
test_co_retrieval_eligible_threshold_and_hub_ratio()
test_due_for_link_review_first_time_and_reevaluation_step()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All knowledge.lua tests passed")
