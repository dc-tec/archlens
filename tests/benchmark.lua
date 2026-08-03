local fixture_root =
  assert(vim.env.ARCHLENS_BENCHMARK_FIXTURE_ROOT, "ARCHLENS_BENCHMARK_FIXTURE_ROOT is required")
local iterations = tonumber(vim.env.ARCHLENS_BENCHMARK_ITERATIONS or "50")
assert(
  iterations and iterations >= 1 and iterations == math.floor(iterations),
  "ARCHLENS_BENCHMARK_ITERATIONS must be a positive integer"
)

local graph = require("archlens.graph")
local model = require("archlens.model")
local performance = require("archlens.performance")
local render = require("archlens.render")
local treesitter = require("archlens.treesitter")

local function percentile(samples, fraction)
  local ordered = vim.deepcopy(samples)
  table.sort(ordered)
  return ordered[math.max(1, math.ceil(#ordered * fraction))]
end

local function summary(samples)
  return {
    first = samples[1],
    median = percentile(samples, 0.5),
    p95 = percentile(samples, 0.95),
  }
end

local cases = {
  { label = "Go", file = "types.go", filetype = "go", position = { line = 2, character = 6 } },
  {
    label = "Rust",
    file = "types.rs",
    filetype = "rust",
    position = { line = 0, character = 10 },
  },
  {
    label = "Nix",
    file = "flake.nix",
    filetype = "nix",
    position = { line = 5, character = 8 },
  },
  {
    label = "OCaml",
    file = "types.ml",
    filetype = "ocaml",
    position = { line = 0, character = 5 },
  },
}

local function benchmark_case(case)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(fixture_root, case.file)))
  vim.bo.filetype = case.filetype
  collectgarbage("collect")

  local samples = {}
  for _ = 1, iterations do
    local measurement = performance.start()
    local context = assert(
      treesitter.resolve(0, case.position),
      string.format("%s fixture did not resolve through Tree-sitter", case.label)
    )
    local built = model.build(context, graph.new(context), {})
    performance.observe(measurement, built)
    local elapsed = performance.snapshot(measurement).first_result_ms
    assert(elapsed, string.format("%s fixture produced no useful relationship", case.label))
    local rendered = render.build(built, { width = 62, max_items = 8 })
    assert(#rendered.lines > 0, string.format("%s fixture produced no rendered lines", case.label))
    samples[#samples + 1] = elapsed
  end
  return summary(samples)
end

local function bounded_model()
  local rows = {}
  for index = 1, 2000 do
    rows[index] = {
      id = "benchmark:" .. index,
      name = "relationship_" .. index,
      path_label = "project/file_" .. index .. ".go",
      line = index,
      location = {
        uri = "file:///project/file_" .. index .. ".go",
        range = {
          start = { line = index - 1, character = 0 },
          ["end"] = { line = index - 1, character = 1 },
        },
      },
      evidence = { provider = "benchmark", method = "benchmark", class = "structural" },
    }
  end
  return {
    title = "ArchLens",
    sections = {
      {
        id = "structural",
        label = "Structural matches",
        marker = "≈",
        rows = rows,
      },
    },
  }
end

local function benchmark_bounded_render()
  local input = bounded_model()
  collectgarbage("collect")
  local samples = {}
  for _ = 1, iterations do
    local started = vim.uv.hrtime()
    local rendered = render.build(input, { width = 62, max_items = 8 })
    samples[#samples + 1] = (vim.uv.hrtime() - started) / 1000000
    assert(#rendered.lines < 40, "bounded rendering exposed the complete relationship set")
  end
  return summary(samples)
end

local ok, err = xpcall(function()
  print("ArchLens local benchmark")
  print(string.format("Iterations: %d (report only; no pass/fail timing threshold)", iterations))
  print("")
  print(string.format("%-18s %10s %10s %10s", "Scenario", "first ms", "median ms", "p95 ms"))
  for _, case in ipairs(cases) do
    local result = benchmark_case(case)
    print(
      string.format(
        "%-18s %10.3f %10.3f %10.3f",
        case.label .. " first result",
        result.first,
        result.median,
        result.p95
      )
    )
  end
  local bounded = benchmark_bounded_render()
  print(
    string.format(
      "%-18s %10.3f %10.3f %10.3f",
      "Bounded render",
      bounded.first,
      bounded.median,
      bounded.p95
    )
  )
  vim.cmd("quitall!")
end, debug.traceback)

if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end
