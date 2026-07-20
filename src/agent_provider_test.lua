-- A deterministic, cost-free provider for tests -- not a mock bolted
-- onto agent.lua, just another named backend behind agent_provider's
-- own dynamic-loading facade, selected the same way Vertex is (the
-- AGENT_PROVIDER env var). Running the real turn loop/compaction logic
-- against real Vertex AI on every test run would make the test suite
-- slow, flaky (network), and genuinely cost money on every invocation
-- -- fine for a handful of dedicated end-to-end confirmations, wrong
-- for routine test iteration.
--
-- Scripted via the AGENT_TEST_RESPONSES env var: a "\1"-delimited list
-- of canned responses, returned in order across successive generate()
-- calls within one process (a single web request's turn loop can call
-- generate() several times in a row -- see agent.lua). Once the list
-- is exhausted, the last response repeats rather than erroring, so a
-- test that doesn't care about exact scripting still terminates.
-- With no script at all, replies with a plain <done> so an unscripted
-- call still completes cleanly.

agent_provider_test = {}

TEST_RESPONSE_INDEX = 0

function agent_provider_test.generate(model, system_prompt, prompt)
    -- Optional: write the exact system_prompt this call received to a
    -- file, for tests asserting on it directly (e.g. task #70's
    -- deployment-configurable system_prompt_extra) rather than
    -- indirectly through model behavior. Off unless a test opts in --
    -- never touches the normal (no env var) test path.
    capture_path = os.getenv("AGENT_TEST_CAPTURE_SYSTEM_PROMPT")
    if capture_path != nil and capture_path != "" then
        capture_file = io.open(capture_path, "w")
        if capture_file != nil then
            io.write(capture_file, system_prompt)
            io.close(capture_file)
        end
    end

    TEST_RESPONSE_INDEX = TEST_RESPONSE_INDEX + 1
    raw = os.getenv("AGENT_TEST_RESPONSES")
    if raw == nil or raw == "" then
        return "<done>Test response.</done>"
    end
    responses = {}
    for piece in string.gmatch(raw, "([^\1]+)") do
        table.insert(responses, piece)
    end
    if responses[TEST_RESPONSE_INDEX] != nil then
        return responses[TEST_RESPONSE_INDEX]
    end
    return responses[#responses]
end

-- A stable, content-derived pseudo-embedding -- not a real semantic
-- vector, just enough determinism for ranking-formula tests to
-- exercise the cosine-similarity code path reproducibly.
function agent_provider_test.embeddings(model, text)
    seed = 0
    for i = 1, string.len(text) do
        seed = seed + string.byte(text, i)
    end
    vector = {}
    for i = 1, 8 do
        table.insert(vector, math.sin(seed + i))
    end
    return vector
end

return agent_provider_test
