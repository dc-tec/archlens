local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
if vim.fn.exists(":ArchLensHere") ~= 2 then
  vim.cmd.runtime("plugin/archlens.lua")
end

local function run()
  local file =
    vim.fs.normalize(assert(vim.env.ARCHLENS_SMOKE_FILE, "ARCHLENS_SMOKE_FILE is required"))
  local line = tonumber(vim.env.ARCHLENS_SMOKE_LINE or "1")
  local column = tonumber(vim.env.ARCHLENS_SMOKE_COLUMN or "0")

  if vim.fs.normalize(vim.api.nvim_buf_get_name(0)) ~= file then
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  local source_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { line, column })

  local attached = vim.wait(15000, function()
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = source_buffer })) do
      if client.initialized then
        return true
      end
    end
    return false
  end, 50)
  assert(attached, "no language server attached before the timeout")

  vim.cmd.ArchLensHere()

  local map_buffer
  local rendered = vim.wait(15000, function()
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].filetype == "archlens" then
        map_buffer = buffer
        local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
        local text = table.concat(lines, "\n")
        return not text:find("Resolving the symbol", 1, true)
          and not text:find("Loading relationships", 1, true)
          and not text:find("Loading local and project relationships", 1, true)
          and not text:find("Pending:", 1, true)
      end
    end
    return false
  end, 50)
  assert(rendered and map_buffer, "ArchLens did not finish rendering before the timeout")

  local lines = vim.api.nvim_buf_get_lines(map_buffer, 0, -1, false)
  local text = table.concat(lines, "\n")
  print(text)
  assert(text:find("ArchLens", 1, true), "ArchLens title is missing")
  if vim.env.ARCHLENS_SMOKE_REQUIRE_RELATIONSHIPS ~= "0" then
    assert(
      text:find("Entered through", 1, true) or text:find("Touches", 1, true),
      "no relationships rendered"
    )
  end
  local expected = vim.env.ARCHLENS_SMOKE_EXPECT
  if expected and expected ~= "" then
    assert(text:find(expected, 1, true), "expected map content is missing: " .. expected)
  end

  local focus_name = vim.env.ARCHLENS_SMOKE_FOCUS
  if focus_name and focus_name ~= "" then
    local focus_expected = vim.env.ARCHLENS_SMOKE_FOCUS_EXPECT or ("└─ " .. focus_name .. "  ")
    local back_expected = vim.env.ARCHLENS_SMOKE_BACK_EXPECT or ("  → " .. focus_name)
    local map_windows = vim.fn.win_findbuf(map_buffer)
    assert(map_windows[1], "the ArchLens window is missing")
    local focus_line
    for index, value in ipairs(lines) do
      if value:find(focus_name, 1, true) then
        focus_line = index
      end
    end
    assert(focus_line, "the requested focus row is missing")
    vim.api.nvim_set_current_win(map_windows[1])
    vim.api.nvim_win_set_cursor(map_windows[1], { focus_line, 0 })
    vim.api.nvim_feedkeys("f", "mx", false)
    local focused = vim.wait(15000, function()
      local focused_text = table.concat(vim.api.nvim_buf_get_lines(map_buffer, 0, -1, false), "\n")
      return focused_text:find(focus_expected, 1, true)
        and not focused_text:find("Loading relationships", 1, true)
        and not focused_text:find("Loading local and project relationships", 1, true)
        and not focused_text:find("Pending:", 1, true)
    end, 50)
    assert(
      focused,
      "focusing the selected relationship timed out\n"
        .. table.concat(vim.api.nvim_buf_get_lines(map_buffer, 0, -1, false), "\n")
    )

    local back_keys = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
    vim.api.nvim_feedkeys(back_keys, "mx", false)
    local restored = vim.wait(15000, function()
      local restored_text = table.concat(vim.api.nvim_buf_get_lines(map_buffer, 0, -1, false), "\n")
      return restored_text:find(back_expected, 1, true)
        and not restored_text:find("Loading relationships", 1, true)
        and not restored_text:find("Loading local and project relationships", 1, true)
        and not restored_text:find("Pending:", 1, true)
    end, 50)
    assert(restored, "returning to the previous focus timed out")
  end
  vim.cmd.quitall()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end
