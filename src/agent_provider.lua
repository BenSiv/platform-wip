-- The seam a real LLM backend plugs into: `generate(model, system_prompt,
-- prompt) -> (result, err)`, optionally `embeddings(model, text) ->
-- (vector, err)`. Loaded dynamically by name (AGENT_PROVIDER env var,
-- default "vertex") rather than required directly, so swapping
-- providers -- or, just as importantly, swapping in the deterministic
-- test provider for repeatable, cost-free test runs -- is a config
-- change, not a code change.

agent_provider = {}

function agent_provider.load()
    name = os.getenv("AGENT_PROVIDER")
    if name == nil or name == "" then
        name = "vertex"
    end
    ok, mod = pcall(require, "agent_provider_" .. name)
    if ok == false or mod == nil then
        return nil, "could not load agent provider '" .. name .. "': " .. tostring(mod)
    end
    return mod
end

function agent_provider.generate(model, system_prompt, prompt)
    provider, err = agent_provider.load()
    if provider == nil then
        return nil, err
    end
    return provider.generate(model, system_prompt, prompt)
end

function agent_provider.embeddings(model, text)
    provider, err = agent_provider.load()
    if provider == nil then
        return nil, err
    end
    if provider.embeddings == nil then
        return nil, "provider has no embeddings support"
    end
    return provider.embeddings(model, text)
end

return agent_provider
