local function url_encode_path(path)
  path = path:gsub("\\", "/")
  local i, protected = 0, {}
  path = path:gsub("%%([%da-fA-F][%da-fA-F])", function(hh)
    i = i + 1
    protected[i] = "%" .. hh
    return "\0" .. i .. "\0"
  end)
  path = path:gsub("([^A-Za-z0-9_.~/-])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  path = path:gsub("\0(%d+)\0", function(idx)
    return protected[tonumber(idx)]
  end)
  return path
end

local function url_encode_q_component(component)
  local i, protected = 0, {}
  component = component:gsub("%%([%da-fA-F][%da-fA-F])", function(hh)
    i = i + 1
    protected[i] = "%" .. hh
    return "\0" .. i .. "\0"
  end)
  component = component:gsub("([^A-Za-z0-9_.~%-])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  component = component:gsub("\0(%d+)\0", function(idx)
    return protected[tonumber(idx)] end)
  return component
end

local function url_encode_q_components(components)
  if not components or #components == 0 then return "" end
  local out = {}
  for _, component in ipairs(components) do
    local eq = component:find("=", 1, true)
    if eq then
      local k = component:sub(1, eq - 1)
      local v = component:sub(eq + 1)
      out[#out+1] = url_encode_q_component(k) .. "=" .. url_encode_q_component(v)
    else
      out[#out+1] = url_encode_q_component(component)
    end
  end
  return table.concat(out, "&")
end

local function url_encode_f(f)
  local i, protected = 0, {}
  f = f:gsub("%%([%da-fA-F][%da-fA-F])", function(hh)
    i = i + 1
    protected[i] = "%" .. hh
    return "\0" .. i .. "\0"
  end)
  f = f:gsub("([^A-Za-z0-9_.~%-])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  f = f:gsub("\0(%d+)\0", function(idx)
    return protected[tonumber(idx)]
  end)
  return f
end

local function url_split_q(q)
  local components = {}
  if not q or q == "" then return components end
  for component in q:gmatch("[^&]+") do
    table.insert(components, component)
  end
  return components
end

local function url_split_qf(url)
  local url_no_qf, q, f = url, nil, nil
  local hash = url:find("#", 1, true)
  local ques = url:find("?", 1, true)
  if hash and ques then
    if ques < hash then
      url_no_qf, q, f = url:sub(1, ques-1), url:sub(ques+1, hash-1), url:sub(hash+1)
    else
      url_no_qf, f = url:sub(1, hash-1), url:sub(hash+1)
    end
  elseif hash then
    url_no_qf, f = url:sub(1, hash-1), url:sub(hash+1)
  elseif ques then
    url_no_qf, q = url:sub(1, ques-1), url:sub(ques+1)
  end
  return url_no_qf, q, f
end

local function classify_url(url)
  if url:match("^[a-zA-Z][a-zA-Z0-9+.-]*:") then
    return "absolute"
  end
  if url:match("^//") then
    return "protocolrelative"
  end
  if url:match("^/") then
    return "rootrelative"
  end
  if url:match("^#") then
    return "fragment"
  end
  return "pathrelative"
end

local function build_blob_url(org, repo, ref, path)
  return string.format(
    "https://github.com/%s/%s/blob/%s/%s", org, repo, ref, path)
end

local function build_raw_url(org, repo, ref, path)
  return string.format(
    "https://raw.githubusercontent.com/%s/%s/%s/%s", org, repo, ref, path)
end

local function build_root_url(org, repo)
  return string.format(
    "https://github.com/%s/%s", org, repo)
end

local function build_tree_url(org, repo, ref, path)
  if path == "" then
    return string.format(
      "%s/tree/%s", build_root_url(org, repo), ref)
  else
    return string.format(
      "%s/tree/%s/%s", build_root_url(org, repo), ref, path)
  end
end

local function get_cfg(meta)
  local function str(s)
    return s and pandoc.utils.stringify(s) or nil
  end
  local cfg = meta.filter_process_github_links or {}
  local function pick(key)
    return str(cfg[key]) or str(meta["filter_process_github_links." .. key])
  end
  local org = pick("org")
  local repo = pick("repo")
  local ref = pick("ref") or "main"
  local root = pick("root") or ""
  if not org or org == "" then
    io.stderr:write("[process-github-links] Missing required metadata field 'filter_process_github_links.org'\n")
  end
  if not repo or repo == "" then
    io.stderr:write("[process-github-links] Missing required metadata field 'filter_process_github_links.repo'\n")
  end
  return { org = org, repo = repo, ref = ref, root = root }
end

local function strip_sentinel(components, sentinel)
  local out = {}
  local found = false
  for _, component in ipairs(components) do
    if component == sentinel then
      found = true
    else
      table.insert(out, component)
    end
  end
  return out, found
end

local function rewrite_target(target, cfg, force_raw)
  local org, repo, ref, root = cfg.org, cfg.repo, cfg.ref, cfg.root
  if target == "/" then
    return build_root_url(org, repo)
  end
  local kind = classify_url(target)
  if kind == "absolute" or kind == "protocolrelative" or kind == "fragment" then
    return target
  end
  local path, q, f = url_split_qf(target)
  local components = url_split_q(q)
  if kind == "rootrelative" then
    path = path:gsub("^/+", "")
  else
    path = pandoc.path.join{ root, path }
  end
  path = pandoc.path.normalize(path):gsub("^%./", "")
  if path == "." then
    path = ""
  end
  local tree = false
  if path == "" or path:sub(-1) == "/" then
    path = path:gsub("/+$", "")
    tree = true
  end
  local found_raw
  components, found_raw = strip_sentinel(components, "raw")
  local use_raw = found_raw or force_raw
  path = url_encode_path(path)
  if components and #components ~= 0 then
    path = path .. "?" .. url_encode_q_components(components)
  end
  if f and f ~= "" then
    path = path .. "#" .. url_encode_f(f)
  end
  if tree then
    return build_tree_url(org, repo, ref, path)
  end
  return use_raw
    and build_raw_url(org, repo, ref, path)
    or build_blob_url(org, repo, ref, path)
end

local cfg

local function Meta(meta)
  cfg = get_cfg(meta)
  return nil
end

local function Link(elem)
  if not (cfg and cfg.org and cfg.repo and cfg.ref and cfg.root ~= nil) then
    return nil
  end
  elem.target = rewrite_target(elem.target, cfg, false)
  return elem
end

local function Image(elem)
  if not (cfg and cfg.org and cfg.repo and cfg.ref and cfg.root ~= nil) then
    return nil
  end
  elem.src = rewrite_target(elem.src, cfg, true)
  return elem
end

return {
  { Meta = Meta },
  { Link = Link, Image = Image }
}
