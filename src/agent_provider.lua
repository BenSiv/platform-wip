-- The seam a real LLM backend plugs into: `generate(model, system_prompt,
-- prompt) -> (result, err)`, optionally `embeddings(model, text) ->
-- (vector, err)`. Loaded dynamically by name (AGENT_PROVIDER env var,
-- default "vertex") rather than required directly, so swapping
-- providers -- or, just as importantly, swapping in the deterministic
-- test provider for repeatable, cost-free test runs -- is a config
-- change, not a code change.

agent_provider = {}

-- Same default-resolution as agent_provider.load() itself, split out
-- so a caller that just wants the *name* (task #87's knowledge_chat_eval
-- recording, e.g.) doesn't need to load/require the actual provider
-- module to get it.
function agent_provider.name()
    name = os.getenv("AGENT_PROVIDER")
    if name == nil or name == "" then
        name = "vertex"
    end
    return name
end

function agent_provider.load()
    ok, mod = pcall(require, "agent_provider_" .. agent_provider.name())
    if ok == false or mod == nil then
        return nil, "could not load agent provider '" .. agent_provider.name() .. "': " .. tostring(mod)
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
