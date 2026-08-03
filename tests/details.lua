local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

local function contains(lines, expected)
  for _, line in ipairs(lines) do
    if line == expected then
      return true
    end
  end
  return false
end

local function range(line, character)
  return {
    start = { line = line, character = character },
    ["end"] = { line = line, character = character + 4 },
  }
end

local section = {
  id = "module_importers",
  label = "Module dependents",
  marker = "⇠",
  anchor = { prefix = "for", label = "internal/service/workload" },
  rows = {
    {
      id = "dependent:one",
      name = "manager_test.go",
      path_label = "test/manager_test.go",
      line = 24,
      location = {
        uri = "file:///workspace/test/manager_test.go",
        range = range(23, 2),
      },
      evidence = {
        provider = "Tree-sitter+gopls",
        method = "adapter/reverseModule",
        class = "semantic",
      },
      occurrences = {
        {
          uri = "file:///workspace/test/manager_test.go",
          ranges = { range(23, 2), range(30, 4) },
        },
      },
    },
  },
}
local model = {
  title = "ArchLens",
  providers = { "gopls", "Tree-sitter", "ast-grep" },
  provider_activity = { "ast-grep retrying" },
  provider_runs = {
    { id = "lsp", label = "gopls", state = "completed", duration_ms = 42 },
    {
      id = "ast_grep",
      label = "ast-grep",
      state = "retrying",
      elapsed_ms = 1250,
      retry_delay_ms = 3000,
    },
  },
  focus = {
    name = "IsBlueGreenStrategy",
    kind_name = "Function",
    root_dir = "/workspace",
    path_label = "internal/service/workload/bluegreen_state.go",
    location = {
      uri = "file:///workspace/internal/service/workload/bluegreen_state.go",
      range = range(16, 0),
    },
  },
  sections = { section },
  notes = {
    "5 vendored relationships hidden.",
    "3 external relationships hidden.",
    "Project module discovery reached the 2000-candidate limit; module-dependent results may be incomplete.",
  },
  result = {
    parts = {
      { label = "module scan limited", severity = "warn" },
      { label = "8 filtered", severity = "info" },
    },
    notes = {
      "5 vendored relationships hidden.",
      "3 external relationships hidden.",
      "Project module discovery reached the 2000-candidate limit; module-dependent results may be incomplete.",
    },
    severity = "warn",
  },
}

local details = require("archlens.details")
local analysis_lines = details.lines({ provider_runs = model.provider_runs }, model)
assert(contains(analysis_lines, "State       Completed"))
assert(contains(analysis_lines, "Duration    42 ms"))
assert(contains(analysis_lines, "State       Retrying"))
assert(contains(analysis_lines, "Elapsed     1.2 s"))
assert(contains(analysis_lines, "Retry       in 3.0 s"))

local result_lines = details.lines({ result = model.result }, model)
assert(contains(result_lines, "Summary     module scan limited · 8 filtered"))
assert(contains(result_lines, "  • 5 vendored relationships hidden."))
assert(contains(result_lines, "  • 3 external relationships hidden."))
assert(
  contains(
    result_lines,
    "  • Project module discovery reached the 2000-candidate limit; module-dependent results may be incomplete."
  )
)

local help_lines = details.lines({ help = true }, model)
assert(contains(help_lines, "ArchLens keys"))
assert(contains(help_lines, "zM, zR          Collapse or expand the complete view"))
assert(contains(help_lines, "?               Inspect the current line, or show this help"))

local section_lines = details.lines({ section = section }, model)
assert(contains(section_lines, "Direction   Incoming — related item → focus"))
assert(contains(section_lines, "Anchor      File — for internal/service/workload"))
assert(contains(section_lines, "Items       1"))
assert(contains(section_lines, "Provider    Tree-sitter+gopls"))
assert(contains(section_lines, "Method      adapter/reverseModule"))
assert(contains(section_lines, "Class       semantic"))
assert(contains(section_lines, "Confidence  Exact semantic relationship"))
assert(contains(section_lines, "Occurrences 2 retained"))

local row_lines = details.lines({ section = section, row = section.rows[1] }, model)
assert(contains(row_lines, "Item        manager_test.go"))
assert(contains(row_lines, "Location    test/manager_test.go:24:3"))
assert(contains(row_lines, "  test/manager_test.go:24:3"))
assert(contains(row_lines, "  test/manager_test.go:31:5"))

local structural = vim.deepcopy(section)
structural.id = "structural"
structural.label = "Structural matches"
structural.anchor = nil
structural.rows[1].evidence.class = "structural"
structural.rows[1].evidence.provider = "ast-grep"
structural.rows[1].evidence.method = "structural"
local structural_lines = details.lines({ section = structural, row = structural.rows[1] }, model)
assert(contains(structural_lines, "Direction   Incoming — related item → focus"))
assert(contains(structural_lines, "Anchor      Focus — IsBlueGreenStrategy"))
assert(contains(structural_lines, "Confidence  Structural candidate"))

local projected_subtype = vim.deepcopy(section)
projected_subtype.id = "subtypes"
projected_subtype.view_id = "subtypes:extended"
projected_subtype.label = "Extended by"
projected_subtype.anchor = nil
projected_subtype.rows[1].name = "RaftActions"
projected_subtype.rows[1].evidence = {
  provider = "gopls",
  method = "typeHierarchy/subtypes",
  class = "semantic",
}
local projected_lines =
  details.lines({ section = projected_subtype, row = projected_subtype.rows[1] }, model)
assert(contains(projected_lines, "Direction   Incoming — related item → focus"))
assert(contains(projected_lines, "Method      typeHierarchy/subtypes"))
assert(contains(projected_lines, "Item        RaftActions"))

local corroborated = vim.deepcopy(structural)
corroborated.id = "references"
corroborated.label = "Referenced across project"
corroborated.rows[1].evidence = {
  provider = "rust-analyzer+ast-grep",
  method = "mixed",
  class = "mixed",
}
corroborated.rows[1].evidence_records = {
  {
    provider = "rust-analyzer",
    method = "textDocument/references",
    class = "semantic",
  },
  {
    provider = "ast-grep",
    method = "structural",
    class = "structural",
  },
}
local corroborated_lines =
  details.lines({ section = corroborated, row = corroborated.rows[1] }, model)
assert(contains(corroborated_lines, "Records     2"))
assert(contains(corroborated_lines, "  ast-grep · structural · structural"))
assert(contains(corroborated_lines, "  rust-analyzer · textDocument/references · semantic"))
assert(
  contains(corroborated_lines, "Confidence  Exact semantic relationship, structurally corroborated")
)
local ast_index = vim.fn.index(corroborated_lines, "  ast-grep · structural · structural")
local rust_index =
  vim.fn.index(corroborated_lines, "  rust-analyzer · textDocument/references · semantic")
assert(
  ast_index >= 0 and ast_index < rust_index,
  "evidence contributions should sort deterministically"
)

local semantic = vim.deepcopy(corroborated)
semantic.rows[1].evidence = {
  provider = "rust-analyzer+secondary-lsp",
  method = "textDocument/references",
  class = "semantic",
}
semantic.rows[1].evidence_records[2] = {
  provider = "secondary-lsp",
  method = "textDocument/references",
  class = "semantic",
}
local semantic_lines = details.lines({ section = semantic, row = semantic.rows[1] }, model)
assert(contains(semantic_lines, "Records     2"))
assert(contains(semantic_lines, "Confidence  Exact semantic relationship"))

local render = require("archlens.render")
local rendered = render.build(model, { width = 80 })
assert(contains(rendered.lines, "Sources [?]: gopls · Tree-sitter · ast-grep"))
assert(contains(rendered.lines, "Analysis [?]: ast-grep retrying"))
assert(contains(rendered.lines, "Results [?]: module scan limited · 8 filtered"))
assert(contains(rendered.lines, "? help · <CR> open · <Space> toggle · f focus"))
assert(not contains(rendered.lines, "5 vendored relationships hidden."))
local default_width_rendered = render.build(model, { width = 56 })
assert(
  contains(default_width_rendered.lines, "Results [?]: module scan limited · 8 filtered"),
  "the important result summary should fit the default pane width"
)
assert(
  contains(default_width_rendered.lines, "? help · <CR> open · <Space> toggle · f focus"),
  "the primary footer should fit the default pane width"
)
local priority_model = vim.deepcopy(model)
priority_model.result = {
  parts = {
    { label = "2 provider issues", severity = "error" },
    { label = "module scan limited", severity = "warn" },
    { label = "123 filtered", severity = "info" },
  },
  notes = model.notes,
  severity = "error",
}
for _, width in ipairs({ 30, 36, 56 }) do
  local narrow = render.build(priority_model, { width = width })
  local narrow_result = vim.iter(narrow.lines):find(function(line)
    return vim.startswith(line, "Results [?]:")
  end)
  local narrow_footer = narrow.lines[#narrow.lines]
  assert(
    narrow_result and narrow_result:find("provider issue", 1, true),
    "error summaries should survive truncation at width " .. width
  )
  assert(
    vim.startswith(narrow_footer, "? help"),
    "keyboard help should remain discoverable at width " .. width
  )
  if width == 56 then
    assert(
      narrow_result:find("module scan limited", 1, true),
      "warnings should remain visible after errors at the default width"
    )
  end
end
local section_line
local analysis_line
local result_line
local row_line
local row_location_line
for line, selection in pairs(rendered.details) do
  if selection.provider_runs then
    analysis_line = analysis_line or line
  elseif selection.result then
    result_line = line
  elseif selection.row == section.rows[1] then
    if rendered.targets[line] then
      row_line = line
    else
      row_location_line = line
    end
  elseif selection.section == section then
    section_line = section_line or line
  end
end
assert(analysis_line, "provider lifecycle and timing should be inspectable")
assert(result_line, "the compact result summary should expose exact notices")
assert(section_line, "section headings should be inspectable")
assert(row_line, "relationship rows should be inspectable")
assert(row_location_line, "row location lines should inspect the same relationship")
equal(rendered.details[row_location_line].row, section.rows[1])

local source_line = vim.fn.index(rendered.lines, "Sources [?]: gopls · Tree-sitter · ast-grep")
  + 1
equal(
  rendered.details[source_line].provider_runs,
  model.provider_runs,
  "the source affordance should expose provider lifecycle details"
)

local queued_model = vim.deepcopy(model)
queued_model.providers = { "Tree-sitter" }
queued_model.provider_activity = { "LSP queued", "ast-grep queued" }
queued_model.provider_runs = {
  { id = "lsp", label = "LSP", state = "queued" },
  { id = "ast_grep", label = "ast-grep", state = "queued" },
}
local queued_rendered = render.build(queued_model, { width = 62 })
assert(
  contains(queued_rendered.lines, "Analysis [?]: LSP queued · ast-grep queued"),
  "provider identities should remain visible when the full activity fits"
)

local busy_model = vim.deepcopy(model)
busy_model.provider_activity = {
  "gopls running",
  "Module dependencies running",
  "Module dependents running",
  "ast-grep running",
}
busy_model.provider_runs = {
  { id = "lsp", label = "gopls", state = "running" },
  { id = "imports", label = "Module dependencies", state = "running" },
  { id = "importers", label = "Module dependents", state = "running" },
  { id = "ast_grep", label = "ast-grep", state = "running" },
}
local busy_rendered = render.build(busy_model, { width = 62 })
assert(
  contains(busy_rendered.lines, "Analysis [?]: 4 running"),
  "long ordinary activity should collapse to a compact state count"
)

busy_model.provider_activity[4] = "ast-grep retrying"
busy_model.provider_runs[4].state = "retrying"
local retry_rendered = render.build(busy_model, { width = 54 })
assert(
  contains(retry_rendered.lines, "Analysis [?]: ast-grep retrying · 3 running"),
  "exceptional provider states should remain named ahead of ordinary activity"
)

local view = require("archlens.view")
local source_window = vim.api.nvim_get_current_win()
local session = {
  expanded = {},
  expanded_groups = {},
  group_limits = {},
  collapsed = {},
  history = { "unchanged" },
  source_window = source_window,
}
local noop = function() end
view.ensure(session, { width = 80, max_items = 8 }, {
  open = noop,
  focus = noop,
  back = noop,
  refresh = noop,
  close = noop,
  dismiss = noop,
})
view.render(session, model, { width = 80, max_items = 8 })
local main_window = session.window
local main_buffer = session.buffer
local history = vim.deepcopy(session.history)
for line, selection in pairs(session.rendered.details) do
  if selection.row == section.rows[1] and not session.rendered.targets[line] then
    row_location_line = line
    break
  end
end
vim.api.nvim_win_set_cursor(main_window, { row_location_line, 0 })

local inspect_mapping
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(main_buffer, "n")) do
  if mapping.lhs == "?" then
    inspect_mapping = mapping
    break
  end
end
assert(inspect_mapping and inspect_mapping.callback, "the details mapping should be callable")
inspect_mapping.callback()
local detail_window = vim.api.nvim_get_current_win()
local detail_buffer = vim.api.nvim_get_current_buf()
assert(detail_window ~= main_window, "details should open in a separate float")
equal(vim.api.nvim_win_get_config(detail_window).relative, "editor")
equal(vim.bo[detail_buffer].buftype, "nofile")
equal(vim.bo[detail_buffer].modifiable, false)
equal(vim.bo[detail_buffer].filetype, "archlensdetails")
equal(session.window, main_window, "inspection must not replace the ArchLens window")
equal(session.buffer, main_buffer, "inspection must not replace the ArchLens buffer")
equal(session.history, history, "inspection must not mutate navigation history")
equal(session.detail.window, detail_window, "the session should own the details window")

vim.api.nvim_set_current_win(main_window)
vim.api.nvim_win_set_cursor(main_window, { 1, 0 })
local original_win_close = vim.api.nvim_win_close
vim.api.nvim_win_close = function(window, force)
  if window == detail_window then
    error("simulated details close failure")
  end
  return original_win_close(window, force)
end
local replacement_ok, replacement_error = pcall(inspect_mapping.callback)
vim.api.nvim_win_close = original_win_close
assert(replacement_ok, replacement_error)
assert(vim.api.nvim_win_is_valid(detail_window), "a failed close should retain the details window")
equal(session.detail.window, detail_window, "a failed close should retain session ownership")
local retained_window_count = 0
for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local buffer = vim.api.nvim_win_get_buf(window)
  if vim.bo[buffer].filetype == "archlensdetails" then
    retained_window_count = retained_window_count + 1
  end
end
equal(retained_window_count, 1, "a failed close must not stack a replacement window")

inspect_mapping.callback()
local help_window = vim.api.nvim_get_current_win()
local help_buffer = vim.api.nvim_get_current_buf()
assert(help_window ~= main_window, "ordinary lines should open keyboard help")
assert(
  not vim.api.nvim_win_is_valid(detail_window),
  "opening help should replace the existing details window"
)
equal(session.detail.window, help_window, "the session should own only the replacement window")
local detail_window_count = 0
for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local buffer = vim.api.nvim_win_get_buf(window)
  if vim.bo[buffer].filetype == "archlensdetails" then
    detail_window_count = detail_window_count + 1
  end
end
equal(detail_window_count, 1, "repeated inspection should not stack details windows")
assert(
  contains(vim.api.nvim_buf_get_lines(help_buffer, 0, -1, false), "ArchLens keys"),
  "keyboard help should retain the complete pane reference"
)
local help_close_mapping
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(help_buffer, "n")) do
  if mapping.lhs == "q" then
    help_close_mapping = mapping
    break
  end
end
assert(help_close_mapping and help_close_mapping.callback, "keyboard help should be closeable")
help_close_mapping.callback()
assert(not vim.api.nvim_win_is_valid(help_window), "closing help should leave only the pane")
assert(vim.api.nvim_win_is_valid(main_window), "closing help must leave ArchLens open")
equal(vim.api.nvim_get_current_win(), main_window, "closing help should restore pane focus")
equal(session.detail, nil, "closing help should clear the session-owned window")

vim.api.nvim_win_set_cursor(main_window, { row_location_line, 0 })
inspect_mapping.callback()
local external_detail_window = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(external_detail_window, true)
assert(
  not vim.api.nvim_win_is_valid(external_detail_window),
  "external window closure should dismiss details"
)
equal(vim.api.nvim_get_current_win(), main_window, "external closure should restore pane focus")
equal(session.detail, nil, "external closure should clear the session-owned window")

vim.api.nvim_win_set_cursor(main_window, { 1, 0 })
inspect_mapping.callback()
local remote_detail_window = vim.api.nvim_get_current_win()
local owner_tab = vim.api.nvim_get_current_tabpage()
vim.cmd.tabnew()
local remote_tab = vim.api.nvim_get_current_tabpage()
local remote_tab_window = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(remote_detail_window, true)
assert(
  not vim.api.nvim_win_is_valid(remote_detail_window),
  "remote closure should dismiss details in the owner tab"
)
equal(vim.api.nvim_get_current_tabpage(), remote_tab, "remote closure must not change tabs")
equal(vim.api.nvim_get_current_win(), remote_tab_window, "remote closure must not steal focus")
equal(session.detail, nil, "remote closure should clear the owning session")
vim.api.nvim_set_current_tabpage(owner_tab)
equal(vim.api.nvim_get_current_win(), main_window, "the owner pane should retain its focus")

vim.api.nvim_win_set_cursor(main_window, { 1, 0 })
inspect_mapping.callback()
local teardown_help_window = vim.api.nvim_get_current_win()
view.close(session)
assert(not vim.api.nvim_win_is_valid(teardown_help_window), "closing the pane should close help")
assert(not vim.api.nvim_win_is_valid(main_window), "the pane should close normally")
equal(session.detail, nil, "pane teardown should clear its details window")
equal(vim.api.nvim_get_current_win(), source_window, "pane teardown should return to the source")

local inactive_session = {
  expanded = {},
  expanded_groups = {},
  group_limits = {},
  collapsed = {},
  source_window = source_window,
}
view.ensure(inactive_session, { width = 80, max_items = 8 }, {
  open = noop,
  focus = noop,
  back = noop,
  refresh = noop,
  close = noop,
  dismiss = noop,
})
view.render(inactive_session, model, { width = 80, max_items = 8 })
local inactive_pane_window = inactive_session.window
local inactive_pane_buffer = inactive_session.buffer
local inactive_inspect_mapping
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(inactive_pane_buffer, "n")) do
  if mapping.lhs == "?" then
    inactive_inspect_mapping = mapping
    break
  end
end
assert(inactive_inspect_mapping and inactive_inspect_mapping.callback)
vim.api.nvim_win_set_cursor(inactive_pane_window, { 1, 0 })
inactive_inspect_mapping.callback()
local inactive_help_window = vim.api.nvim_get_current_win()
local inactive_owner_tab = vim.api.nvim_get_current_tabpage()
local inactive_owner_number = vim.api.nvim_tabpage_get_number(inactive_owner_tab)
vim.cmd.tabnew()
local surviving_tab = vim.api.nvim_get_current_tabpage()
local surviving_window = vim.api.nvim_get_current_win()
vim.cmd("tabclose " .. inactive_owner_number)
assert(not vim.api.nvim_tabpage_is_valid(inactive_owner_tab), "the inactive owner tab should close")
assert(not vim.api.nvim_win_is_valid(inactive_help_window), "tab teardown should close help")
assert(not vim.api.nvim_win_is_valid(inactive_pane_window), "tab teardown should close the pane")
equal(inactive_session.detail, nil, "tab teardown should clear the session-owned window")
equal(
  vim.api.nvim_get_current_tabpage(),
  surviving_tab,
  "tab teardown must preserve the active tab"
)
equal(vim.api.nvim_get_current_win(), surviving_window, "tab teardown must preserve active focus")

print("archlens details tests passed")
vim.cmd("quitall")
