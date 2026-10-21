local M = {}
local context = require("navigation.location_pin_context")

local function call(ctx, action, input)
  local valid, context_error = context.validate(ctx)
  if not valid then
    return nil, context_error
  end
  local helper, helper_error = require("config.platform").dotfiles_helper("location_pins")
  if not helper then
    return nil, helper_error
  end
  local ok, process = pcall(vim.system, {
    helper,
    action,
    "--socket",
    ctx.socket,
    "--session",
    ctx.session,
    "--server-pid",
    ctx.pid,
  }, { text = true, stdin = input and vim.json.encode(input) or nil })
  if not ok then
    return nil, "Could not start the line-pin helper: " .. tostring(process)
  end
  local result = process:wait(10000)
  if result.code ~= 0 then
    local detail = vim.trim(result.stderr or "")
    return nil, detail ~= "" and detail or "The line-pin helper did not complete"
  end
  if action == "list" or action == "add" then
    local decoded, value = pcall(vim.json.decode, result.stdout or "")
    if not decoded or type(value) ~= "table" then
      return nil, "The line-pin helper returned invalid data"
    end
    if action == "list" then
      if value.version ~= 1 or type(value.pins) ~= "table" then
        return nil, "The line-pin helper returned an unsupported state"
      end
      return value.pins
    end
    return value
  end
  return true
end

function M.list(ctx)
  return call(ctx, "list")
end

function M.add(ctx, location)
  return call(ctx, "add", location)
end

function M.delete(ctx, id)
  return call(ctx, "delete", { id = id })
end

function M.clear(ctx)
  return call(ctx, "clear")
end

return M
