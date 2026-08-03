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
}

local details = require("archlens.details")
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

local render = require("archlens.render")
local rendered = render.build(model, { width = 80 })
local section_line
local row_line
local row_location_line
for line, selection in pairs(rendered.details) do
  if selection.row == section.rows[1] then
    if rendered.targets[line] then
      row_line = line
    else
      row_location_line = line
    end
  elseif selection.section == section then
    section_line = section_line or line
  end
end
assert(section_line, "section headings should be inspectable")
assert(row_line, "relationship rows should be inspectable")
assert(row_location_line, "row location lines should inspect the same relationship")
equal(rendered.details[row_location_line].row, section.rows[1])

local view = require("archlens.view")
local source_window = vim.api.nvim_get_current_win()
local session = {
  expanded = {},
  expanded_groups = {},
  group_limits = {},
  collapsed = {},
  history = { "unchanged" },
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

local close_mapping
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(detail_buffer, "n")) do
  if mapping.lhs == "q" then
    close_mapping = mapping
    break
  end
end
assert(close_mapping and close_mapping.callback, "the details float should be closeable")
close_mapping.callback()
assert(
  not vim.api.nvim_win_is_valid(detail_window),
  "closing details should dismiss only the float"
)
assert(vim.api.nvim_win_is_valid(main_window), "closing details must leave ArchLens open")

vim.api.nvim_win_close(main_window, true)
if vim.api.nvim_win_is_valid(source_window) then
  vim.api.nvim_set_current_win(source_window)
end

print("archlens details tests passed")
vim.cmd("quitall")
