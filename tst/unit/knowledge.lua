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

-- Run them
test_reply_has_visible_reasoning_detects_markers()
test_classify_reply_four_way_split()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All knowledge.lua tests passed")
