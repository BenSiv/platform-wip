-- Minimal multipart/form-data parser (RFC 7578) for CGI POST bodies --
-- just enough to support a file field (Settings' logo/favicon uploads)
-- alongside plain text fields in the same form. Not a general MIME
-- parser: no nested multipart, no non-form content dispositions,
-- no header folding.

multipart = {}

function multipart.boundary_from_content_type(content_type)
    if content_type == nil then
        return nil
    end
    return string.match(content_type, "boundary=\"?([^\";]+)\"?")
end

-- Returns a plain {field_name = value} table, the same shape
-- parse_query's own table already has for ordinary forms -- a file
-- field's value is instead {filename = ..., content_type = ..., data
-- = ...}, distinguishing it from a plain string value at the call
-- site (io.type/type(value) == "table").
--
-- Boundary matching uses string.find(..., true) (plain-text search),
-- not a Lua pattern -- a boundary token can contain characters ("+",
-- "/") that are pattern-magic, and the content itself is arbitrary
-- binary (image bytes), so nothing here should ever be interpreted as
-- a pattern.
function multipart.parse(content_type, body)
    result = {}
    boundary = multipart.boundary_from_content_type(content_type)
    if boundary == nil or body == nil then
        return result
    end
    delimiter = "--" .. boundary

    -- Each occurrence's `stop` is where the following part's content
    -- starts; the NEXT occurrence's `start` (not its own stop) is
    -- where that content ends -- using stop/stop for both ends, as an
    -- earlier version of this function did, silently swallows the
    -- entire next boundary marker into the current part's content.
    positions = {}
    search_from = 1
    while true do
        match_start, match_end = string.find(body, delimiter, search_from, true)
        if match_start == nil then
            break
        end
        table.insert(positions, {start = match_start, stop = match_end})
        search_from = match_end + 1
    end

    -- Content between consecutive boundary occurrences is one part;
    -- the span after the LAST occurrence is the closing "--" epilogue,
    -- never a real part, so the loop stops one short of #positions.
    for i = 1, #positions - 1 do
        part = string.sub(body, positions[i].stop + 1, positions[i + 1].start - 1)
        part = string.gsub(part, "^\r\n", "")
        part = string.gsub(part, "\r\n$", "")

        header_end = string.find(part, "\r\n\r\n", 1, true)
        if header_end != nil then
            header_block = string.sub(part, 1, header_end - 1)
            content = string.sub(part, header_end + 4)

            name = string.match(header_block, 'name="([^"]*)"')
            filename = string.match(header_block, 'filename="([^"]*)"')
            part_content_type = string.match(header_block, "[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)")

            if name != nil then
                if filename != nil and filename != "" then
                    result[name] = {filename = filename, content_type = part_content_type, data = content}
                else
                    result[name] = content
                end
            end
        end
    end

    return result
end

return multipart
