local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        message or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function contains(lines, expected)
  return vim.iter(lines):any(function(line)
    return line:find(expected, 1, true) ~= nil
  end)
end

local function row(id, name, line)
  return {
    id = id,
    name = name,
    path_label = "src/example.lua",
    line = line,
    location = {
      uri = "file:///workspace/src/example.lua",
      range = {
        start = { line = line - 1, character = 0 },
        ["end"] = { line = line - 1, character = #name },
      },
    },
    evidence = { provider = "lua_ls", method = "references", class = "semantic" },
  }
end

local function run()
  local renderer = require("archlens.render")
  local view = require("archlens.view")
  local group = {
    id = "test_references:group:example",
    name = "tests › example",
    rows = {
      row("test:1", "first test", 11),
      row("test:2", "second test", 12),
      row("test:3", "third test", 13),
    },
  }
  local model = {
    title = "ArchLens",
    sections = {
      {
        id = "outgoing",
        label = "Touches",
        marker = "→",
        rows = {
          row("outgoing:1", "first", 1),
          row("outgoing:2", "second", 2),
          row("outgoing:3", "third", 3),
          row("outgoing:4", "fourth", 4),
        },
      },
      {
        id = "test_references",
        label = "Referenced from tests",
        marker = "◇",
        rows = group.rows,
        groups = { group },
      },
      {
        id = "siblings",
        label = "Nearby definitions",
        marker = "·",
        rows = {
          row("sibling:1", "alpha", 21),
          row("sibling:2", "beta", 22),
        },
      },
      {
        id = "test_structural",
        label = "Potential test matches",
        marker = "⋄",
        default_collapsed = true,
        rows = {
          row("structural:1", "possible match", 31),
        },
      },
    },
  }

  local rendered = renderer.build(model, {
    width = 100,
    max_items = 1,
    section_max_items = { outgoing = 2 },
    collapsed = { siblings = true },
  })
  assert(contains(rendered.lines, "  → first"), "the first outgoing row should render")
  assert(contains(rendered.lines, "  → second"), "the section override should raise its limit")
  assert(not contains(rendered.lines, "  → third"), "the section override should remain bounded")
  assert(contains(rendered.lines, "  … 2 more"), "the remaining outgoing count should be exact")
  assert(
    contains(rendered.lines, "▸ Nearby definitions  2"),
    "default policy should collapse siblings"
  )
  assert(not contains(rendered.lines, "  · alpha"), "collapsed sections should hide rows")
  assert(
    contains(rendered.lines, "▸ Potential test matches  1"),
    "model-level secondary sections should start collapsed"
  )
  assert(
    not contains(rendered.lines, "  ⋄ possible match"),
    "secondary section rows should stay hidden until requested"
  )
  assert(
    contains(rendered.lines, "zM/zR collapse/expand all"),
    "the footer should advertise whole-view controls"
  )

  local source_window = vim.api.nvim_get_current_win()
  local options = {
    width = 100,
    max_items = 1,
    sections = {
      default_collapsed = { "siblings" },
      max_items = { outgoing = 2, test_references = 2 },
    },
  }
  local session = {
    expanded = {},
    expanded_groups = {},
    group_limits = {},
    collapsed = { siblings = true },
  }
  local noop = function() end
  view.ensure(session, options, {
    open = noop,
    focus = noop,
    back = noop,
    refresh = noop,
    close = noop,
    dismiss = noop,
  })
  view.render(session, model, options)

  local mappings = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.buffer, "n")) do
    mappings[mapping.lhs] = mapping.callback
  end
  assert(mappings.zM and mappings.zR, "the pane should map zM and zR")

  local structural_line = vim.fn.index(session.rendered.lines, "▸ Potential test matches  1") + 1
  local toggle_mapping = mappings["<Space>"] or mappings[" "]
  assert(structural_line > 0 and toggle_mapping, "secondary sections should remain toggleable")
  vim.api.nvim_win_set_cursor(session.window, { structural_line, 0 })
  toggle_mapping()
  equal(
    session.collapsed.test_structural,
    false,
    "opening a secondary section should override its model default"
  )
  assert(
    contains(session.rendered.lines, "  ⋄ possible match"),
    "opening a secondary section should reveal its candidates"
  )

  mappings.zR()
  equal(session.collapsed, {}, "expand all should open every section")
  equal(
    session.expanded,
    { outgoing = true, siblings = true, test_references = true, test_structural = true },
    "expand all should remove top-level result limits"
  )
  equal(
    session.expanded_groups,
    { [group.id] = true },
    "expand all should open nested context groups"
  )
  equal(
    session.group_limits,
    { [group.id] = 3 },
    "expand all should reveal every row in nested groups"
  )
  assert(contains(session.rendered.lines, "  → fourth"), "expand all should reveal all rows")
  assert(
    contains(session.rendered.lines, "    ◇ third test"),
    "expand all should reveal grouped rows"
  )

  mappings.zM()
  equal(session.expanded, {}, "collapse all should clear expanded sections")
  equal(session.expanded_groups, {}, "collapse all should close nested groups")
  equal(session.group_limits, {}, "collapse all should clear progressive nested limits")
  equal(
    session.collapsed,
    { outgoing = true, siblings = true, test_references = true, test_structural = true },
    "collapse all should close every visible section"
  )
  assert(
    not contains(session.rendered.lines, "  → first"),
    "collapse all should hide section rows"
  )

  vim.api.nvim_win_close(session.window, true)
  vim.api.nvim_set_current_win(source_window)

  local projected_model = {
    title = "ArchLens",
    sections = {
      {
        id = "subtypes",
        view_id = "subtypes:extended",
        label = "Extended by",
        marker = "↓",
        rows = { row("subtype:interface", "Contract", 41) },
      },
      {
        id = "subtypes",
        view_id = "subtypes:implemented",
        label = "Implemented by",
        marker = "↓",
        rows = { row("subtype:struct", "Concrete", 42) },
      },
    },
  }
  local projected_session = {
    expanded = {},
    expanded_groups = {},
    group_limits = {},
    collapsed = {},
  }
  view.ensure(projected_session, options, {
    open = noop,
    focus = noop,
    back = noop,
    refresh = noop,
    close = noop,
    dismiss = noop,
  })
  view.render(projected_session, projected_model, options)
  local projected_mappings = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(projected_session.buffer, "n")) do
    projected_mappings[mapping.lhs] = mapping.callback
  end
  local extended_line = vim.fn.index(projected_session.rendered.lines, "▾ Extended by  1") + 1
  assert(extended_line > 0, "the first projected subtype section should render")
  vim.api.nvim_win_set_cursor(projected_session.window, { extended_line, 0 })
  local projected_toggle = projected_mappings["<Space>"] or projected_mappings[" "]
  projected_toggle()
  equal(
    projected_session.collapsed,
    { ["subtypes:extended"] = true },
    "projected sections should keep independent collapse state"
  )
  assert(
    contains(projected_session.rendered.lines, "▸ Extended by  1")
      and contains(projected_session.rendered.lines, "▾ Implemented by  1"),
    "collapsing one projected section must not collapse its sibling"
  )
  projected_mappings.zM()
  equal(projected_session.collapsed, {
    ["subtypes:extended"] = true,
    ["subtypes:implemented"] = true,
  }, "collapse all should address projected view identities")
  projected_mappings.zR()
  equal(projected_session.expanded, {
    ["subtypes:extended"] = true,
    ["subtypes:implemented"] = true,
  }, "expand all should address projected view identities")
  vim.api.nvim_win_close(projected_session.window, true)
  vim.api.nvim_set_current_win(source_window)
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim view state tests passed")
vim.cmd("quitall!")
