local M = {}
local sanitize = require("ui.startup.git").sanitize

local function unit(text, highlight, kind)
  return { type = kind or "git", string = text, hl = highlight }
end

local function text_line(text, highlight)
  return { unit(text, highlight or "Normal") }
end

local function width_of(line, display_width)
  local text = ""
  for _, part in ipairs(line) do
    text = text .. part.string
  end
  return display_width(text)
end

local function truncate(text, width, display_width)
  if display_width(text) <= width then
    return text
  end
  if width <= 0 or display_width("…") > width then
    return ""
  end
  local low, high, best = 0, vim.fn.strchars(text, true), ""
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local prefix = vim.fn.strcharpart(text, 0, middle, true)
    if display_width(prefix .. "…") <= width then
      best, low = prefix, middle + 1
    else
      high = middle - 1
    end
  end
  return best .. "…"
end

local function fit(line, width, display_width, prefix)
  local result = {}
  local rendered = prefix or ""
  local end_column = display_width(rendered) + width
  for _, part in ipairs(line) do
    local copy = vim.tbl_extend("force", {}, part)
    local used = display_width(rendered)
    copy.string = truncate(part.string, end_column - used, function(text)
      return display_width(rendered .. text) - used
    end)
    result[#result + 1] = copy
    rendered = rendered .. copy.string
  end
  return result
end

local function status_highlight(change)
  if change.kind == "conflicted" then
    return "DiagnosticError"
  elseif change.kind == "untracked" or change.xy:find("A", 1, true) then
    return "DiffAdd"
  elseif change.xy:find("D", 1, true) then
    return "DiffDelete"
  end
  return "DiffChange"
end

local function change_tree(changes, limit)
  local root = { children = {}, order = {} }
  for index = 1, limit do
    local change, node = changes[index], root
    local segments = vim.split(change.path, "/", { plain = true })
    for depth, segment in ipairs(segments) do
      if not node.children[segment] then
        local child = { name = sanitize(segment), children = {}, order = {} }
        node.children[segment] = child
        node.order[#node.order + 1] = segment
      end
      node = node.children[segment]
      if depth == #segments then
        node.change = change
      end
    end
  end
  local rows = {}
  local function visit(node, prefix)
    table.sort(node.order)
    for index, key in ipairs(node.order) do
      local child = node.children[key]
      local last = index == #node.order
      local connector = last and "└─ " or "├─ "
      local name = child.name
      while not child.change and #child.order == 1 do
        local next_child = child.children[child.order[1]]
        if next_child.change then
          break
        end
        name, child = name .. "/" .. next_child.name, next_child
      end
      if child.change then
        local change = child.change
        if change.original_path then
          local original =
            vim.tbl_map(sanitize, vim.split(change.original_path, "/", { plain = true }))
          name = name .. " ← " .. table.concat(original, "/")
        end
        rows[#rows + 1] = {
          unit(change.xy .. " ", status_highlight(change)),
          unit(prefix .. connector, "Comment"),
          unit(name, "Normal"),
        }
      else
        rows[#rows + 1] = text_line(prefix .. connector .. name .. "/", "Directory")
      end
      visit(child, prefix .. (last and "   " or "│  "))
    end
  end
  visit(root, "")
  return rows
end

local function repository_panel(view, budget)
  local branch = view.branch or {}
  local identity = branch.detached and ("detached HEAD " .. (branch.oid or ""):sub(1, 7))
    or branch.head
    or "HEAD"
  if branch.upstream then
    identity = "+"
      .. (branch.ahead or 0)
      .. " -"
      .. (branch.behind or 0)
      .. " "
      .. identity
      .. " → "
      .. branch.upstream
  end
  local history, changes = view.history or {}, view.changes or {}
  local commits = 0
  for _, entry in ipairs(history) do
    if entry.oid then
      commits = commits + 1
    end
  end
  local total = (view.counts or {}).total or #changes
  local histories, trees = {}, {}
  for count = 0, math.min(5, commits) do
    local rows, seen = {}, 0
    if count > 0 then
      rows[#rows + 1] = text_line("History", "Title")
      for _, entry in ipairs(history) do
        if entry.oid then
          if seen == count then
            break
          end
          seen = seen + 1
        end
        rows[#rows + 1] = {
          unit(entry.graph or "", "Comment"),
          unit(entry.oid and (" " .. entry.oid .. " ") or "", "Identifier"),
          unit(entry.subject or "", "Normal"),
        }
      end
    end
    if commits == 0 then
      rows[#rows + 1] =
        text_line(branch.unborn and "No commits yet" or "No recent commits", "Comment")
    elseif commits > count then
      rows[#rows + 1] = text_line("+" .. (commits - count) .. " more commits", "Comment")
    end
    histories[count] = rows
  end
  for count = 0, math.min(12, #changes) do
    local rows = {}
    if count > 0 then
      rows[#rows + 1] = text_line("Changes", "Title")
      vim.list_extend(rows, change_tree(changes, count))
    end
    if total == 0 then
      rows[#rows + 1] = text_line("Working tree clean", "DiagnosticOk")
    elseif total > count then
      rows[#rows + 1] = text_line("+" .. (total - count) .. " more paths", "Comment")
    end
    trees[count] = rows
  end
  local best_history, best_tree, best_score = histories[0], trees[0], -1
  for commit_count = 0, math.min(5, commits) do
    local history_rows = histories[commit_count]
    for path_count = 0, math.min(12, #changes) do
      local tree_rows = trees[path_count]
      local context = (commit_count > 0 and 1 or 0) + (path_count > 0 and 1 or 0)
      local score = context * 1000 + commit_count * 2 + path_count
      if #history_rows + #tree_rows <= budget - 4 and score > best_score then
        best_history, best_tree, best_score = history_rows, tree_rows, score
      end
    end
  end
  local rows = {
    text_line(view.name, "Title"),
    text_line(sanitize(view.root), "Comment"),
    text_line(identity, "Identifier"),
  }
  vim.list_extend(rows, best_history)
  vim.list_extend(rows, best_tree)
  rows[#rows + 1] = text_line(commits .. " commits · " .. total .. " changed", "Comment")
  return rows
end

local function menu_lines(items, horizontal)
  local result = {}
  for _, item in ipairs(items) do
    local line = horizontal and result[1] or nil
    if not line then
      line = {}
      result[#result + 1] = line
    elseif #line > 0 then
      line[#line + 1] = unit("  ")
    end
    line[#line + 1] = unit("  ", "Special", "pointer")
    line[#line + 1] = item
  end
  result[#result + 1] = text_line("")
  result[#result + 1] = text_line("j/k ↑↓ move; ↵ opens", "Comment")
  return result
end

function M.compose(content, view, options)
  local display_width = options.display_width or vim.fn.strdisplaywidth
  local width, height = math.max(1, options.width), math.max(1, options.height)
  local items = {}
  for _, line in ipairs(content) do
    for _, part in ipairs(line) do
      if part.type == "item" then
        items[#items + 1] = part
      end
    end
  end
  local has_panel = view.kind == "repository" or view.kind == "loading"
  -- Preserve the compact 22-column view when full margins would crowd it.
  local margin = math.min(2, math.max(0, math.floor((width - 22) / 2)))
  local block_width = math.min(width - 2 * margin, 112)
  local wide = has_panel and block_width >= 112
  local horizontal = menu_lines(items, true)
  local menu = menu_lines(
    items,
    has_panel and not wide and width_of(horizontal[1], display_width) <= block_width
  )
  local panel = {}
  if view.kind == "loading" then
    panel = { text_line("Loading Git status...", "Comment") }
  elseif view.kind == "repository" then
    panel = repository_panel(view, wide and height or height - #menu - 1)
  end
  if width >= 22 then
    local padding = math.max(0, math.floor((width - block_width) / 2))
    for row, line in ipairs(panel) do
      panel[row] = fit(
        line,
        wide and block_width - 26 or block_width,
        display_width,
        string.rep(" ", padding + (wide and 26 or 0))
      )
    end
  end
  local result = {}
  if wide then
    for row = 1, math.max(#menu, #panel) do
      local line = menu[row] or {}
      local line_width = width_of(line, display_width)
      line[#line + 1] = unit(string.rep(" ", math.max(0, 26 - line_width)))
      for _, part in ipairs(panel[row] or {}) do
        line[#line + 1] = part
      end
      result[#result + 1] = line
    end
  else
    result = menu
    if has_panel then
      result[#result + 1] = text_line("")
      vim.list_extend(result, panel)
    else
      block_width = 0
      for _, line in ipairs(result) do
        block_width = math.max(block_width, width_of(line, display_width))
      end
    end
  end
  local top = math.max(0, math.floor((height - #result) / 2))
  local left = math.max(0, math.floor((width - block_width) / 2))
  for _, line in ipairs(result) do
    table.insert(line, 1, unit(string.rep(" ", left)))
  end
  for _ = 1, top do
    table.insert(result, 1, text_line(""))
  end
  return result
end

return M
