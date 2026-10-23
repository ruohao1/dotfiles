local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), label .. "\n" .. vim.inspect(actual))
end

local layout = require("ui.startup.layout")
local items = {}
for index, name in ipairs({ "f  Find files", "r  Recent files", "q  Quit" }) do
  items[index] =
    { type = "item", string = name, hl = "MiniStarterItem", item = { action = function() end } }
end
local content = {
  { { type = "header", string = "ignored" } },
  { items[1] },
  { items[2] },
  { items[3] },
}
local function lines(result)
  return vim.tbl_map(function(line)
    return table.concat(vim.tbl_map(function(unit)
      return unit.string
    end, line))
  end, result)
end
local function compose(view, width, height, display_width)
  local before = vim.deepcopy({ content, view })
  local result = layout.compose(content, view, {
    width = width or 100,
    height = height or 30,
    display_width = display_width or vim.fn.strdisplaywidth,
  })
  eq({ content, view }, before, "composition mutated input")
  local seen = {}
  for _, line in ipairs(result) do
    for column, unit in ipairs(line) do
      if unit.type == "item" then
        seen[#seen + 1] = unit
        assert(unit == items[#seen], "item identity/order lost")
        eq(line[column - 1].type, "pointer", "missing pointer")
        eq(vim.fn.strdisplaywidth(line[column - 1].string), 2, "pointer must occupy two cells")
      end
    end
  end
  eq(#seen, 3, "all actions must survive composition")
  return result, lines(result)
end

local _, menu = compose({ kind = "non_repository" }, 80, 20)
assert(table.concat(menu, "\n"):find("f  Find files", 1, true), "missing menu")
assert(menu[1]:match("^%s*$"), "menu should be vertically centered")
local _, error_menu = compose({ kind = "error", message = "private diagnostic" }, 80, 20)
eq(error_menu, menu, "errors fall back to menu only")
local _, loading = compose({ kind = "loading" }, 100, 20)
assert(table.concat(loading, "\n"):find("Loading Git status...", 1, true), "missing loading state")

local repository = {
  kind = "repository",
  root = "/work/project",
  name = "project",
  branch = { head = "main", oid = "abcdef123456", upstream = "origin/main", ahead = 2, behind = 1 },
  changes = {},
  counts = { total = 0 },
  history = { { graph = "*", oid = "abcdef1", subject = "First commit" } },
}
local _, wide = compose(repository, 116, 30)
local wide_text = table.concat(wide, "\n")
assert(wide_text:find("Working tree clean", 1, true), "clean state missing")
assert(wide_text:find("origin/main", 1, true), "upstream missing")
assert(wide_text:find("+2", 1, true) and wide_text:find("-1", 1, true), "divergence missing")
for _, width in ipairs({ 80, 92, 96, 100, 111, 112, 115, 116 }) do
  local result, output = compose(repository, width, 30)
  local menu_rows, repository_row = {}, nil
  for row, line in ipairs(result) do
    for _, unit in ipairs(line) do
      if unit.type == "item" then
        menu_rows[#menu_rows + 1] = row
      elseif unit.string == repository.name then
        repository_row = row
      end
    end
  end
  assert(repository_row, "repository missing at " .. width)
  if width < 116 then
    eq(menu_rows[1], menu_rows[3], "narrow menu shares a row at " .. width)
    assert(repository_row > menu_rows[3], "Git panel stacks below the menu at " .. width)
    assert(
      output[repository_row]:match("^  project"),
      "narrow Git panel keeps two columns of padding"
    )
  else
    assert(menu_rows[1] < menu_rows[3], "wide menu uses separate rows")
    eq(repository_row, menu_rows[1], "wide Git panel sits beside the menu")
  end
end

local dense = vim.deepcopy(repository)
dense.history = {
  { graph = "*", oid = "1111111", subject = "subject1" },
  { graph = "|\\" },
  { graph = "| *", oid = "2222222", subject = "subject2" },
  { graph = "| *", oid = "3333333", subject = "subject3" },
  { graph = "|/" },
  { graph = "*", oid = "4444444", subject = "subject4" },
  { graph = "*", oid = "5555555", subject = "subject5" },
  { graph = "*", oid = "6666666", subject = "subject6" },
}
for index = 1, 15 do
  dense.changes[index] = {
    path = "src/module/file" .. string.format("%02d", index) .. ".lua",
    xy = "M.",
    kind = "ordinary",
  }
end
dense.changes[1].xy = "MM"
dense.changes[2].xy = "??"
dense.changes[2].kind = "untracked"
dense.changes[3].xy = "UU"
dense.changes[3].kind = "conflicted"
dense.changes[4].xy = "R."
dense.changes[4].original_path = "old/place.lua"
dense.counts.total = 15
local _, dense_lines = compose(dense, 112, 48)
local dense_text = table.concat(dense_lines, "\n")
assert(
  dense_text:find("MM", 1, true)
    and dense_text:find("??", 1, true)
    and dense_text:find("UU", 1, true),
  "XY states lost"
)
assert(
  dense_text:find("src/", 1, true) and dense_text:find("module/", 1, true),
  "path hierarchy lost"
)
assert(dense_text:find("old/place.lua", 1, true), "rename origin missing")
assert(
  dense_text:find("|\\", 1, true) and dense_text:find("|/", 1, true),
  "history connectors lost"
)
assert(
  dense_text:find("subject5", 1, true) and not dense_text:find("subject6", 1, true),
  "five commit cap broken"
)
assert(
  dense_text:find("file12.lua", 1, true) and not dense_text:find("file13.lua", 1, true),
  "twelve path cap broken"
)
assert(
  dense_text:find("+1 more commit", 1, true) and dense_text:find("+3 more paths", 1, true),
  "cap omissions missing"
)
assert(
  dense_text:find("6 commits · 15 changed", 1, true),
  "summary counts must use all collected entries"
)
local conflict_highlight
local dense_result = compose(dense, 112, 48)
for _, line in ipairs(dense_result) do
  for _, part in ipairs(line) do
    if part.string == "UU " then
      conflict_highlight = part.hl
    end
  end
end
eq(conflict_highlight, "DiagnosticError", "conflicts require their own semantic highlight")
local hash = string.rep("a", 40)
local parsed_conflict = assert(require("ui.startup.git")._test.parse_status(
  "/repo",
  table.concat({
    "# branch.oid " .. hash,
    "# branch.head main",
    "u UU N... 100644 100644 100644 100644 "
      .. hash
      .. " "
      .. hash
      .. " "
      .. hash
      .. " conflict.lua",
    "",
  }, "\0")
))
local parsed_result = compose(parsed_conflict, 100, 30)
local parsed_highlight
for _, line in ipairs(parsed_result) do
  for _, part in ipairs(line) do
    if part.string == "UU " then
      parsed_highlight = part.hl
    end
  end
end
eq(parsed_highlight, "DiagnosticError", "real parser conflict kind lost in composition")

local deep = vim.deepcopy(repository)
deep.changes =
  { { path = string.rep("directory/", 24) .. "leaf.lua", xy = ".M", kind = "modified" } }
deep.counts.total = 1
local _, deep_lines = compose(deep, 44, 18)
local deep_text = table.concat(deep_lines, "\n")
assert(deep_text:find(".M", 1, true), "deep hierarchy must not crowd out file status")
assert(
  deep_text:find("abcdef1", 1, true),
  "both history and changes context should survive compact hierarchy"
)
local long_branch = vim.deepcopy(repository)
long_branch.branch.head = string.rep("branch", 40)
local _, long_branch_lines = compose(long_branch, 44, 18)
local long_branch_text = table.concat(long_branch_lines, "\n")
assert(
  long_branch_text:find("+2", 1, true) and long_branch_text:find("-1", 1, true),
  "branch truncation hid divergence"
)

for _, size in ipairs({ { 112, 18 }, { 92, 12 }, { 80, 18 }, { 44, 15 }, { 30, 18 } }) do
  local _, short_lines = compose(dense, size[1], size[2])
  assert(#short_lines <= size[2], "usable layout exceeds height at " .. vim.inspect(size))
  for _, line in ipairs(short_lines) do
    assert(
      vim.fn.strdisplaywidth(line) <= size[1],
      "layout exceeds width at " .. vim.inspect(size) .. ": " .. line
    )
  end
  local short_text = table.concat(short_lines, "\n")
  assert(
    short_text:find("project", 1, true) and short_text:find("changed", 1, true),
    "identity/summary sacrificed"
  )
  assert(short_text:find("more", 1, true), "short layout must report omitted entries")
end
local _, tiny = compose(dense, 4, 2)
local tiny_text = table.concat(tiny, "\n")
assert(tiny_text:find("q  Quit", 1, true), "tiny fallback dropped action")
assert(tiny_text:find("project", 1, true), "tiny fallback dropped identity")
assert(tiny_text:find("changed", 1, true), "tiny fallback dropped summary")

local unborn = vim.deepcopy(repository)
unborn.branch = { head = "main", unborn = true }
unborn.history = {}
unborn.changes = { { path = "new.lua", xy = "A.", kind = "ordinary" } }
unborn.counts.total = 1
local _, unborn_lines = compose(unborn, 100, 30)
assert(table.concat(unborn_lines, "\n"):find("No commits yet", 1, true), "unborn state missing")
assert(table.concat(unborn_lines, "\n"):find("A.", 1, true), "unborn changes missing")
local detached = vim.deepcopy(repository)
detached.branch = { detached = true, oid = "abcdef123456" }
local _, detached_lines = compose(detached, 100, 30)
assert(
  table.concat(detached_lines, "\n"):find("detached HEAD abcdef1", 1, true),
  "detached identity missing"
)

local unusual = vim.deepcopy(dense)
unusual.name = string.rep("界é", 50)
unusual.root = "/work/line\nbreak\t" .. string.char(255)
unusual.changes[1].path = "界é/unsafe\n\t" .. string.char(255) .. ".lua"
unusual.history[1].subject = string.rep("界é", 80)
for _, width in ipairs({ 44, 91, 92, 112, 180 }) do
  local _, output = compose(unusual, width, 40)
  for _, line in ipairs(output) do
    assert(not line:find("[%z\1-\31\127]"), "unsafe controls in rendered line")
    assert(not line:find(string.char(255), 1, true), "invalid UTF-8 in rendered line")
    assert(
      vim.fn.strdisplaywidth(line) <= width,
      "Unicode display width exceeded at " .. width .. ": " .. line
    )
    assert(
      vim.fn.strdisplaywidth(line) <= 112 + math.max(0, math.floor((width - 112) / 2)),
      "content cap exceeded"
    )
  end
end

local long_subject = vim.deepcopy(repository)
long_subject.history[1].subject = string.rep("x", 100000)
local long_width_calls = 0
local _, long_lines = compose(long_subject, 92, 18, function(text)
  if #text > 1000 then
    long_width_calls = long_width_calls + 1
    assert(long_width_calls < 100, "truncation repeatedly rescans an unbounded subject")
  end
  return vim.fn.strwidth(text)
end)
for _, line in ipairs(long_lines) do
  assert(vim.fn.strwidth(line) <= 92, "long subject exceeded display-cell budget")
end

local original_ambiwidth = vim.o.ambiwidth
for _, ambiwidth in ipairs({ "single", "double" }) do
  vim.o.ambiwidth = ambiwidth
  for _, size in ipairs({
    { 22, 0 },
    { 23, 0 },
    { 24, 1 },
    { 25, 1 },
    { 26, 2 },
    { 44, 2 },
    { 96, 2 },
    { 115, 2 },
    { 116, 2 },
    { 180, 34 },
  }) do
    local width, margin = unpack(size)
    for _, view in ipairs({ unusual, { kind = "loading" }, { kind = "non_repository" } }) do
      local _, output = compose(view, width, 40)
      for _, line in ipairs(output) do
        if line:find("%S") then
          assert(line:sub(1, margin) == string.rep(" ", margin), "left padding lost at " .. width)
          assert(vim.fn.strdisplaywidth(line) <= width - margin, "right padding lost at " .. width)
        end
      end
    end
  end
end
vim.o.ambiwidth = "double"
for _, width in ipairs({ 22, 23, 44, 92, 112 }) do
  local result, output = compose(unusual, width, 40)
  for _, line in ipairs(output) do
    assert(
      vim.fn.strdisplaywidth(line) <= width,
      "ambiguous-width characters exceeded the viewport"
    )
  end
  for _, line in ipairs(result) do
    for _, part in ipairs(line) do
      if part.string:find("j/k", 1, true) then
        assert(vim.fn.strdisplaywidth(part.string) <= 22, "hint consumed the menu/panel gap")
      end
    end
  end
end
vim.o.ambiwidth = original_ambiwidth

print("Startup layout assertions: ok")
