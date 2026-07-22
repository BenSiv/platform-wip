-- Google Vertex AI backend for agent_provider's generate/embeddings
-- interface. Calls Vertex's REST API directly (generateContent for
-- text, predict for embeddings) via a curl shell-out authenticated
-- with a fresh Application Default Credentials access token -- not a
-- vendored HTTP/TLS client or a Google client library, matching the
-- "bind to an existing, battle-tested tool" stance already used for
-- bcrypt/HMAC/cmark. Verified directly against a real project (not
-- assumed): gemini-2.5-flash for generation, text-embedding-005 for
-- embeddings, both in us-central1.
--
-- Requires `gcloud` on PATH, already authenticated (`gcloud auth
-- application-default login`), and two env vars: VERTEX_PROJECT
-- (required, no default -- this is a real, potentially billed GCP
-- project, never hardcoded here) and VERTEX_REGION (optional, defaults
-- to us-central1).

json = require("dkjson")

agent_provider_vertex = {}

DEFAULT_REGION = "us-central1"

function shell_quote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

function vertex_config()
    project = os.getenv("VERTEX_PROJECT")
    if project == nil or project == "" then
        return nil, nil, "VERTEX_PROJECT env var is not set"
    end
    region = os.getenv("VERTEX_REGION")
    if region == nil or region == "" then
        region = DEFAULT_REGION
    end
    return project, region
end

-- A fresh bearer token per call, not cached -- ADC tokens are
-- short-lived (about an hour) and re-fetching costs one extra `gcloud`
-- invocation, negligible next to the LLM call itself.
function vertex_access_token()
    handle = io.popen("gcloud auth application-default print-access-token 2>/dev/null", "r")
    if handle == nil then
        return nil, "cannot run gcloud"
    end
    token = io.read(handle, "*all")
    io.close(handle)
    if token == nil then
        return nil, "no output from gcloud"
    end
    token = string.gsub(token, "%s+$", "")
    if token == "" then
        return nil, "empty access token -- is 'gcloud auth application-default login' configured?"
    end
    return token
end

-- POSTs `payload_table` (JSON-encoded) to
-- .../publishers/google/models/<model_and_method_path>, via a temp
-- file (curl -d @file) rather than shell-interpolating the payload
-- directly -- the only shell-interpolated values are the URL and a
-- path this process generated itself, never prompt/response content.
function vertex_post(model_and_method_path, payload_table)
    project, region, config_err = vertex_config()
    if project == nil then
        return nil, config_err
    end
    token, token_err = vertex_access_token()
    if token == nil then
        return nil, token_err
    end

    tmp_path = os.tmpname()
    file = io.open(tmp_path, "w")
    if file == nil then
        return nil, "cannot create temp file for request body"
    end
    io.write(file, json.encode(payload_table))
    io.close(file)

    url = "https://" .. region .. "-aiplatform.googleapis.com/v1/projects/" .. project ..
        "/locations/" .. region .. "/publishers/google/models/" .. model_and_method_path

    cmd = "curl -s -X POST " .. shell_quote(url) ..
        " -H " .. shell_quote("Authorization: Bearer " .. token) ..
        " -H " .. shell_quote("Content-Type: application/json") ..
        " -d @" .. shell_quote(tmp_path)

    handle = io.popen(cmd, "r")
    response_text = nil
    if handle != nil then
        response_text = io.read(handle, "*all")
        io.close(handle)
    end
    os.remove(tmp_path)

    if response_text == nil or response_text == "" then
        return nil, "no response from Vertex AI (curl/network failure)"
    end

    response, _, decode_err = json.decode(response_text)
    if response == nil then
        return nil, "invalid JSON response from Vertex AI: " .. tostring(decode_err)
    end
    if response.error != nil then
        return nil, "Vertex AI error: " .. tostring(response.error.message)
    end
    return response
end

-- `usageMetadata` (promptTokenCount/candidatesTokenCount/totalTokenCount)
-- is a real field on every generateContent response -- task #87 needs
-- real token accounting for knowledge_context, not just
-- agent.estimate_tokens' char/4 heuristic (still used for compaction
-- thresholding, unrelated). Absent entirely just means a nil-valued
-- table, not an error -- older API versions or a malformed response
-- shouldn't fail generation over accounting metadata.
function usage_from_response(response)
    meta = response.usageMetadata
    if meta == nil then
        return {prompt_tokens = nil, completion_tokens = nil, total_tokens = nil}
    end
    return {
        prompt_tokens = meta.promptTokenCount,
        completion_tokens = meta.candidatesTokenCount,
        total_tokens = meta.totalTokenCount,
    }
end

function agent_provider_vertex.generate(model, system_prompt, prompt)
    payload = {
        contents = {{role = "user", parts = {{text = prompt}}}},
    }
    if system_prompt != nil and system_prompt != "" then
        payload.systemInstruction = {parts = {{text = system_prompt}}}
    end

    response, err = vertex_post(model .. ":generateContent", payload)
    if response == nil then
        return nil, err
    end
    if response.candidates == nil or response.candidates[1] == nil then
        return nil, "no candidates in Vertex AI response"
    end
    candidate = response.candidates[1]
    if candidate.content == nil or candidate.content.parts == nil or candidate.content.parts[1] == nil then
        return nil, "empty response (finishReason: " .. tostring(candidate.finishReason) .. ")"
    end
    return candidate.content.parts[1].text, nil, usage_from_response(response)
end

function agent_provider_vertex.embeddings(model, text)
    response, err = vertex_post(model .. ":predict", {instances = {{content = text}}})
    if response == nil then
        return nil, err
    end
    if response.predictions == nil or response.predictions[1] == nil then
        return nil, "no predictions in Vertex AI response"
    end
    embedding = response.predictions[1].embeddings
    if embedding == nil or embedding.values == nil then
        return nil, "malformed embeddings response"
    end
    return embedding.values
end

return agent_provider_vertex
