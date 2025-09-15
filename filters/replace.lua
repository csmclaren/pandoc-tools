local stringify = pandoc.utils.stringify
local ptype     = pandoc.utils.type

local function meta_scalar_to_string(v)
  if v == nil then return nil end
  local k = ptype(v)
  if k == "Inlines" or k == "MetaInlines" or k == "MetaBlocks"
    or k == "MetaString" or k == "Bool" or k == "MetaBool" then
    return stringify(v)
  end
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then
    return tostring(v)
  end
  return nil
end

local function parse_segment(seg)
  local name, idx = seg:match("^(.-)%[(%d+)%]$")
  if name then return name, tonumber(idx) end
  return seg, nil
end

local function split_path(path)
  local segs = {}
  for seg in tostring(path):gmatch("[^%.]+") do segs[#segs+1] = seg end
  return segs
end

local function resolve_key(meta, key)
  if not meta or not key or key == "" then return nil end

  local literal = meta[key]
  local s = meta_scalar_to_string(literal)
  if s ~= nil then return s end

  local node = meta
  for _, rawseg in ipairs(split_path(key)) do
    local seg, idx = parse_segment(rawseg)
    local t = ptype(node)

    if t == "MetaList" then
      if idx then
        node = node[idx]
      else
        return nil
      end
    elseif t == "MetaMap" then
      node = node[seg]
    elseif type(node) == "table" then
      node = node[seg]
    else
      return nil
    end

    if node == nil then return nil end

    if idx and ptype(node) == "MetaList" then
      node = node[idx]
      if node == nil then return nil end
    end
  end
  return meta_scalar_to_string(node)
end

local function replace_placeholders_in_string(s, resolver, pattern, left_delim, right_delim)
  return (s:gsub(pattern, function(inner)
    local raw  = inner
    local key  = raw:gsub("^%s+",""):gsub("%s+$", "")
    local val  = resolver(key)
    return val or (left_delim .. raw .. right_delim)
  end))
end

local function replace_in_inlines(inlines, resolver, pattern, left_delim, right_delim)
  local out, buf = {}, {}

  local function flush()
    if #buf == 0 then return end
    local joined = table.concat(buf)
    local after = replace_placeholders_in_string(joined, resolver, pattern, left_delim, right_delim)
    out[#out+1] = pandoc.Str(after)
    buf = {}
  end

  for _, il in ipairs(inlines) do
    if il.t == "Str" then
      buf[#buf+1] = il.text
    else
      flush()
      out[#out+1] = il
    end
  end
  flush()
  return out
end

local function parse_codeblocks(meta)
  local codeblocks = {}

  local rep = meta["filter_replace"]
  if rep then
    local container = rep["codeblocks"]
    if container then
      local k = ptype(container)
      if k == "MetaList" then
        for _, v in ipairs(container) do
          local s = stringify(v):lower()
          if #s > 0 then
            codeblocks[s] = true
          end
        end
      else
        for codeblock in stringify(container):gmatch("[^,%s]+") do
          local s = codeblock:lower()
          if #s > 0 then
            codeblocks[s] = true
          end
        end
      end
    end
  end

  do
    local dotted = meta["filter_replace.codeblocks"]
    if dotted ~= nil then
      local s = stringify(dotted)
      for token in s:gmatch("[^,%s]+") do
        local t = token:lower()
        if #t > 0 then
          codeblocks[t] = true
        end
      end
    end
  end

  return codeblocks
end

local function codeblock_classes(el)
  if el.classes and type(el.classes) == "table" then return el.classes end
  if el.attr and el.attr.classes and type(el.attr.classes) == "table" then return el.attr.classes end
  if el.attr and type(el.attr[2]) == "table" then return el.attr[2] end
  return {}
end

function Pandoc(doc)
  local meta = doc.meta or {}

  local left_delim, right_delim = "{{", "}}"

  local function esc(p) return (p:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")) end
  local pattern = esc(left_delim) .. "(.-)" .. esc(right_delim)

  local _cache, _miss = {}, {}
  local function resolver(key)
    local v = _cache[key]
    if v ~= nil then
      return (v == _miss) and nil or v
    end
    v = resolve_key(meta, key)
    _cache[key] = (v == nil) and _miss or v
    return v
  end

  local function rewrite_inlines_container(el)
    el.content = replace_in_inlines(el.content, resolver, pattern, left_delim, right_delim)
    return el
  end

  local function truthy(v)
    if not v then return false end
    local s = stringify(v):lower()
    return (s == "true" or s == "1" or s == "yes" or s == "on")
  end

  local allow_code = false
  if meta["filter_replace"] and meta["filter_replace"]["code"] ~= nil then
    allow_code = truthy(meta["filter_replace"]["code"])
  elseif meta["filter_replace.code"] ~= nil then
    allow_code = truthy(meta["filter_replace.code"])
  end

  local allowed_codeblocks = parse_codeblocks(meta)

  return doc:walk({
    Cite        = rewrite_inlines_container,
    Emph        = rewrite_inlines_container,
    Header      = rewrite_inlines_container,
    Link        = rewrite_inlines_container,
    Para        = rewrite_inlines_container,
    Plain       = rewrite_inlines_container,
    Quoted      = rewrite_inlines_container,
    SmallCaps   = rewrite_inlines_container,
    Span        = rewrite_inlines_container,
    Strikeout   = rewrite_inlines_container,
    Strong      = rewrite_inlines_container,
    Subscript   = rewrite_inlines_container,
    Superscript = rewrite_inlines_container,

    Code = function(el)
      if allow_code then
        el.text = replace_placeholders_in_string(el.text, resolver, pattern, left_delim, right_delim)
      end
      return el
    end,

    CodeBlock = function(el)
      local classes = codeblock_classes(el)
      if next(allowed_codeblocks) then
        local match = false
        for _, cls in ipairs(classes) do
          local key = tostring(cls):lower()
          if allowed_codeblocks[key] then
            match = true
            break
          end
        end
        if match then
          el.text = replace_placeholders_in_string(el.text, resolver, pattern, left_delim, right_delim)
        end
      end
      return el
    end,
  })
end
