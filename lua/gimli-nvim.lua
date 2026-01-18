---@class Config
---@field opt string Your config option
local config = {
}

---@class MyModule
local M = {}

---@type Config
M.config = config

---@param args Config?
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
end

M.run = function()
  -- exit if we don't have the JSON parsing tool
  if vim.fn.executable('jq') == 0 then
    vim.notify("jq tool not found", vim.log.levels.ERROR)
    return
  end
  -- find the project root, and a bazel-produced file.
  local workspace = vim.fs.root(0, { ".git", "MODULE.bzl", "WORKSPACE" })
  if not workspace then
    vim.notify("No workspace found", vim.log.levels.WARN)
    return
  end
  local path = workspace .. '/.build_event.json'
  if vim.fn.filereadable(path) == 0 then
    vim.notify("No .build_event.json file", vim.log.levels.WARN)
    return
  end
  -- extract the stderr content from compilation
  local cmd = [[jq -j 'select(.id.progress)|.progress.stderr|gsub("\\\\x1b\\\\[[0-9;?]*[ -/]*[@-~]"; "")?']]
  local lines = vim.fn.systemlist(cmd .. ' ' .. path)
  -- manually parse the errors because I couldn't find how to use vim's
  -- getqflist to do it.
  local items
  local item
  for _, line in ipairs(lines) do
    local match, _, filename, lnum, col, message = line:find('^([^:]+):(%d+):(%d+): error: (.+)$')
    if match then
      items = items or {}
      item = {}
      table.insert(items, item)
      item.filename = workspace .. '/' .. filename
      item.module = filename
      item.lnum = tonumber(lnum)
      item.col = tonumber(col)
      item.type = 'E'
      item.text = message
      item.context = {}
      goto continue
    end
    if item then
      table.insert(item.context, line)
    end
    ::continue::
  end
  -- set the quickfix list and open it if not empty.
  vim.fn.setqflist({}, 'r', { items = items, title = 'bazel errors ' .. workspace })
  if items then
    vim.cmd("copen")
  else
    vim.notify("No build errors found.")
  end
end

return M
