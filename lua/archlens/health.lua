local treesitter = require("archlens.treesitter")

local M = {}

local minimum_version = { major = 0, minor = 12 }

local project_markers = {
  ".git",
  "flake.nix",
  "go.mod",
  "Cargo.toml",
  "dune-project",
  "package.json",
  "pyproject.toml",
}

local lsp_methods = {
  { method = "textDocument/documentSymbol", label = "document symbols" },
  { method = "textDocument/prepareCallHierarchy", label = "call hierarchy preparation" },
  { method = "callHierarchy/incomingCalls", label = "incoming calls" },
  { method = "callHierarchy/outgoingCalls", label = "outgoing calls" },
  { method = "textDocument/references", label = "project references" },
}

local function item(level, message)
  return { level = level, message = message }
end

local function version_string(version)
  return string.format("%d.%d.%d", version.major or 0, version.minor or 0, version.patch or 0)
end

local function version_supported(version)
  if (version.major or 0) ~= minimum_version.major then
    return (version.major or 0) > minimum_version.major
  end
  return (version.minor or 0) >= minimum_version.minor
end

local function is_health_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name == "health://" or vim.bo[bufnr].filetype == "checkhealth"
end

local function context_buffer()
  local current = vim.api.nvim_get_current_buf()
  if not is_health_buffer(current) then
    return current
  end

  local alternate = vim.fn.bufnr("#")
  if
    alternate ~= -1
    and vim.api.nvim_buf_is_valid(alternate)
    and not is_health_buffer(alternate)
  then
    return alternate
  end
  return nil
end

local function inspect_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return { valid = false }
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local marker_root
  local root
  if name ~= "" then
    marker_root = vim.fs.root(name, project_markers)
    root = marker_root or vim.fs.dirname(name)
  end

  return {
    valid = true,
    bufnr = bufnr,
    name = name,
    filetype = filetype,
    root = root,
    marker_root = marker_root ~= nil,
  }
end

local function inspect_treesitter(bufnr, buffer)
  if not buffer.valid or buffer.filetype == "" then
    return { parser = false, adapter = false }
  end

  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  local adapter_ok, adapter = pcall(treesitter.supports, bufnr)
  return {
    parser = parser_ok and parser ~= nil,
    parser_error = parser_ok and nil or tostring(parser),
    adapter = adapter_ok and adapter == true,
    adapter_error = adapter_ok and nil or tostring(adapter),
  }
end

local function inspect_lsp(bufnr, buffer)
  if not buffer.valid then
    return { clients = {} }
  end

  local clients_ok, attached = pcall(vim.lsp.get_clients, { bufnr = bufnr })
  if not clients_ok then
    return { clients = {}, error = tostring(attached) }
  end

  local clients = {}
  for _, client in ipairs(attached) do
    local methods = {}
    local errors = {}
    for _, spec in ipairs(lsp_methods) do
      local ok, supported = pcall(client.supports_method, client, spec.method, bufnr)
      if not ok then
        errors[#errors + 1] = string.format("%s: %s", spec.method, tostring(supported))
      elseif supported then
        methods[#methods + 1] = spec.label
      end
    end
    clients[#clients + 1] = {
      id = client.id,
      name = client.name or "unnamed client",
      methods = methods,
      errors = errors,
    }
  end
  table.sort(clients, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    return (left.id or 0) < (right.id or 0)
  end)
  return { clients = clients }
end

local function first_line(text)
  text = vim.trim(text or "")
  return text ~= "" and text:match("[^\r\n]+") or nil
end

local function inspect_ast_grep(command, enabled)
  command = command or "ast-grep"
  if enabled == false then
    return { command = command, enabled = false }
  end
  if vim.fn.executable(command) ~= 1 then
    return { command = command, enabled = true, available = false }
  end

  local path = vim.fn.exepath(command)
  if path == "" then
    path = command
  end
  local start_ok, process = pcall(vim.system, { path, "--version" }, { text = true })
  if not start_ok then
    return {
      command = command,
      enabled = true,
      path = path,
      available = true,
      error = tostring(process),
    }
  end

  local wait_ok, result = pcall(process.wait, process, 3000)
  if not wait_ok then
    return {
      command = command,
      enabled = true,
      path = path,
      available = true,
      error = tostring(result),
    }
  end
  if result.code ~= 0 then
    return {
      command = command,
      enabled = true,
      path = path,
      available = true,
      error = first_line(result.stderr) or string.format("exited with code %d", result.code),
    }
  end
  return {
    command = command,
    enabled = true,
    path = path,
    available = true,
    version = first_line(result.stdout) or first_line(result.stderr),
  }
end

local function inspect()
  local bufnr = context_buffer()
  local buffer = inspect_buffer(bufnr)
  local archlens_ok, archlens = pcall(require, "archlens")
  local configured = archlens_ok and archlens.get_config and archlens.get_config() or {}
  local ast_grep = configured.ast_grep or {}
  return {
    version = vim.version(),
    buffer = buffer,
    treesitter = inspect_treesitter(bufnr, buffer),
    lsp = inspect_lsp(bufnr, buffer),
    ast_grep = inspect_ast_grep(ast_grep.command, ast_grep.enabled),
  }
end

function M._diagnose(state)
  local sections = {}

  local runtime = { title = "ArchLens runtime", items = {} }
  sections[#sections + 1] = runtime
  local current_version = version_string(state.version or {})
  if version_supported(state.version or {}) then
    runtime.items[#runtime.items + 1] = item("ok", "Neovim " .. current_version)
  else
    runtime.items[#runtime.items + 1] = item(
      "error",
      string.format(
        "Neovim %s is unsupported; ArchLens requires Neovim %d.%d or newer.",
        current_version,
        minimum_version.major,
        minimum_version.minor
      )
    )
  end

  local context = { title = "ArchLens context", items = {} }
  sections[#sections + 1] = context
  local buffer = state.buffer or { valid = false }
  if not buffer.valid then
    context.items[#context.items + 1] = item(
      "error",
      "No source buffer is available. Run :checkhealth archlens from a source buffer."
    )
  else
    local name = buffer.name ~= "" and buffer.name or "[No Name]"
    local filetype = buffer.filetype ~= "" and buffer.filetype or "none"
    context.items[#context.items + 1] =
      item("info", string.format("Buffer %d: %s (filetype: %s)", buffer.bufnr, name, filetype))
    if buffer.name == "" then
      context.items[#context.items + 1] = item(
        "warn",
        "The source buffer is unnamed; project-scoped analysis cannot determine a root."
      )
    end
    if buffer.filetype == "" then
      context.items[#context.items + 1] = item(
        "warn",
        "The source buffer has no filetype; parser and adapter detection are unavailable."
      )
    end
    if buffer.root and buffer.marker_root then
      context.items[#context.items + 1] = item("ok", "Project root: " .. buffer.root)
    elseif buffer.root then
      context.items[#context.items + 1] =
        item("warn", "No project marker was found; project scope falls back to: " .. buffer.root)
    elseif buffer.name ~= "" then
      context.items[#context.items + 1] = item("warn", "No project root could be determined.")
    end
  end

  local parser = { title = "ArchLens Tree-sitter", items = {} }
  sections[#sections + 1] = parser
  local tree_state = state.treesitter or {}
  if tree_state.parser then
    parser.items[#parser.items + 1] =
      item("ok", "A Tree-sitter parser is available for the source buffer.")
  elseif tree_state.parser_error then
    parser.items[#parser.items + 1] =
      item("warn", "Tree-sitter parser detection failed: " .. tree_state.parser_error)
  else
    parser.items[#parser.items + 1] =
      item("warn", "No Tree-sitter parser is available for the source buffer.")
  end
  if tree_state.adapter then
    parser.items[#parser.items + 1] =
      item("ok", "The ArchLens Tree-sitter adapter supports the source buffer.")
  elseif tree_state.adapter_error then
    parser.items[#parser.items + 1] =
      item("error", "ArchLens Tree-sitter adapter detection failed: " .. tree_state.adapter_error)
  else
    parser.items[#parser.items + 1] =
      item("warn", "No ArchLens Tree-sitter adapter is available for the source buffer.")
  end

  local lsp = { title = "ArchLens LSP", items = {} }
  sections[#sections + 1] = lsp
  local lsp_state = state.lsp or { clients = {} }
  if lsp_state.error then
    lsp.items[#lsp.items + 1] =
      item("error", "Attached LSP client detection failed: " .. lsp_state.error)
  elseif #(lsp_state.clients or {}) == 0 then
    lsp.items[#lsp.items + 1] = item(
      "warn",
      "No LSP clients are attached to the source buffer; semantic relationships are unavailable."
    )
  else
    local useful_clients = 0
    for _, client in ipairs(lsp_state.clients) do
      local identity = string.format("%s (id: %s)", client.name, tostring(client.id or "unknown"))
      if #(client.errors or {}) > 0 then
        lsp.items[#lsp.items + 1] = item(
          "error",
          string.format(
            "%s capability detection failed: %s",
            identity,
            table.concat(client.errors, "; ")
          )
        )
      end
      if #(client.methods or {}) > 0 then
        useful_clients = useful_clients + 1
        lsp.items[#lsp.items + 1] =
          item("ok", string.format("%s: %s", identity, table.concat(client.methods, ", ")))
      else
        lsp.items[#lsp.items + 1] =
          item("info", identity .. ": no ArchLens LSP methods are advertised for this buffer.")
      end
    end
    if useful_clients == 0 then
      lsp.items[#lsp.items + 1] = item(
        "warn",
        "Attached LSP clients do not advertise methods used by ArchLens for this buffer."
      )
    end
  end

  local ast = { title = "ArchLens ast-grep", items = {} }
  sections[#sections + 1] = ast
  local ast_state = state.ast_grep or { command = "ast-grep", available = false }
  if ast_state.enabled == false then
    ast.items[#ast.items + 1] = item("info", "ast-grep is disabled by the ArchLens configuration.")
  elseif not ast_state.available then
    ast.items[#ast.items + 1] = item(
      "warn",
      string.format(
        "%s is unavailable; structural project matches will be skipped.",
        ast_state.command
      )
    )
  else
    ast.items[#ast.items + 1] = item("ok", "Executable: " .. (ast_state.path or ast_state.command))
    if ast_state.version then
      ast.items[#ast.items + 1] = item("ok", "Version: " .. ast_state.version)
    else
      ast.items[#ast.items + 1] = item(
        "warn",
        "The ast-grep version could not be determined"
          .. (ast_state.error and ": " .. ast_state.error or ".")
      )
    end
  end

  return sections
end

local function emit(sections)
  for _, section in ipairs(sections) do
    vim.health.start(section.title)
    for _, diagnostic in ipairs(section.items) do
      vim.health[diagnostic.level](diagnostic.message)
    end
  end
end

function M.check()
  emit(M._diagnose(inspect()))
end

M._context_buffer = context_buffer

return M
