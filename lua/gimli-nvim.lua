---@class Config
---@field opt string Your config option
local config = {}

---@class MyModule
local M = {}

---@type Config
M.config = config

---@param args Config?
M.setup = function(args) M.config = vim.tbl_deep_extend('force', M.config, args or {}) end

M.run = function()
  -- find the project root, and a bazel-produced file.
  local workspace = vim.fs.root(0, { '.git', 'MODULE.bzl', 'WORKSPACE' })
  if not workspace then
    vim.notify('No workspace found', vim.log.levels.WARN)
    return
  end
  local path
  for _, name in ipairs { '.build_event.json', '.build_events.json', 'build_event.json', 'build_events.json' } do
    local p = workspace .. '/' .. name
    if vim.fn.filereadable(p) == 1 then
      path = p
      break
    end
  end
  if not path then
    vim.notify('No build event JSON file found in workspace', vim.log.levels.WARN)
    return
  end

  -- extract stderr and stdout from compilation & test runs
  local file, err = io.open(path, 'r')
  if not file then
    vim.notify('Failed to open ' .. path .. ': ' .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local stderr_chunks = {}
  local stdout_chunks = {}
  for line in file:lines() do
    if line ~= '' then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == 'table' and event.id and event.id.progress and event.progress then
        if type(event.progress.stderr) == 'string' and event.progress.stderr ~= '' then
          local clean = (event.progress.stderr:gsub('\x1b%[[0-9;?]*[ -/]*[@-~]', ''))
          table.insert(stderr_chunks, clean)
        end
        if type(event.progress.stdout) == 'string' and event.progress.stdout ~= '' then
          local clean = (event.progress.stdout:gsub('\x1b%[[0-9;?]*[ -/]*[@-~]', ''))
          table.insert(stdout_chunks, clean)
        end
      end
    end
  end
  file:close()

  local full_output = table.concat(stderr_chunks) .. '\n' .. table.concat(stdout_chunks)
  local lines = vim.split(full_output, '\n', { plain = true })

  local items
  local item
  local current_test

  for _, line in ipairs(lines) do
    -- Track test boundaries to associate failure with the running test
    local test_start = line:match '^%[%s*RUN%s*%]%s+(%S+)'
    if test_start then
      current_test = test_start
      item = nil
    elseif line:match '^%[%s*(.-)%s*%]' then
      -- [ FAILED ], [ PASSED ], [ OK ], etc. mark the end of the test's failure output
      item = nil
    end

    -- 1. Compiler error: filename:lnum:col: [fatal ]error: message
    local f, lnum, col, err_type, msg = line:match '^([^:]+):(%d+):(%d+):%s*(.-error):%s*(.+)$'
    if f then
      items = items or {}
      item = {
        filename = f:sub(1, 1) == '/' and f or (workspace .. '/' .. f),
        module = f,
        lnum = tonumber(lnum),
        col = tonumber(col),
        type = 'E',
        text = msg,
        context = {},
      }
      table.insert(items, item)
    else
      -- 2. GUnit / Google Test failure: filename:lnum: Failure
      local f_fail, l_fail, fail_msg = line:match '^(%S+):(%d+):%s*Failure%s*(.*)$'
      if f_fail then
        items = items or {}
        local text = 'Failure'
        if current_test then text = text .. ' in ' .. current_test end
        fail_msg = fail_msg:gsub('^:%s*', '')
        if fail_msg ~= '' then text = text .. ': ' .. fail_msg end
        item = {
          filename = f_fail:sub(1, 1) == '/' and f_fail or (workspace .. '/' .. f_fail),
          module = f_fail,
          lnum = tonumber(l_fail),
          col = 1,
          type = 'E',
          text = text,
          context = {},
        }
        table.insert(items, item)
      else
        -- 3. Fatal logging / CHECK failures: Fmmdd hh:mm:ss.uuuuuu pid file:line] Check failed: ...
        local f_fatal, l_fatal, check_msg = line:match '^F%d%d%d%d %d%d:%d%d:%d%d%.%d+%s+%d+%s+([^:]+):(%d+)%]%s*(.+)$'
        if f_fatal then
          items = items or {}
          item = {
            filename = f_fatal:sub(1, 1) == '/' and f_fatal or (workspace .. '/' .. f_fatal),
            module = f_fatal,
            lnum = tonumber(l_fatal),
            col = 1,
            type = 'E',
            text = check_msg,
            context = {},
          }
          table.insert(items, item)
        elseif item then
          table.insert(item.context, line)
        end
      end
    end
  end

  -- set the quickfix list and open it if not empty.
  vim.fn.setqflist({}, 'r', { items = items or {}, title = 'bazel errors ' .. workspace })
  if items and #items > 0 then
    vim.cmd 'copen'
    vim.cmd 'cfirst'
  else
    vim.notify 'No build or test errors found.'
  end
end

return M
