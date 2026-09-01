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
        lnum = tonumber(lnum),
        col = tonumber(col),
        type = 'E',
        text = msg,
        user_data = {
          details = { line },
        },
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
          lnum = tonumber(l_fail),
          col = 1,
          type = 'E',
          text = text,
          user_data = {
            details = { line },
            test = current_test,
          },
        }
        table.insert(items, item)
      else
        -- 3. Fatal logging / CHECK failures: Fmmdd hh:mm:ss.uuuuuu pid file:line] Check failed: ...
        local f_fatal, l_fatal, check_msg = line:match '^F%d%d%d%d %d%d:%d%d:%d%d%.%d+%s+%d+%s+([^:]+):(%d+)%]%s*(.+)$'
        if f_fatal then
          items = items or {}
          item = {
            filename = f_fatal:sub(1, 1) == '/' and f_fatal or (workspace .. '/' .. f_fatal),
            lnum = tonumber(l_fatal),
            col = 1,
            type = 'E',
            text = check_msg,
            user_data = {
              details = { line },
            },
          }
          table.insert(items, item)
        elseif item and item.user_data and item.user_data.details then
          table.insert(item.user_data.details, line)
        end
      end
    end
  end

  -- trim trailing blank lines from details
  if items then
    for _, it in ipairs(items) do
      if it.user_data and it.user_data.details then
        while #it.user_data.details > 0 and it.user_data.details[#it.user_data.details]:match '^%s*$' do
          table.remove(it.user_data.details)
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

M._detail_win = nil

--- Show full error details in a floating window
M.show_detail = function()
  if M._detail_win and vim.api.nvim_win_is_valid(M._detail_win) then
    vim.api.nvim_win_close(M._detail_win, true)
    M._detail_win = nil
    return
  end

  local is_qf = vim.bo.buftype == 'quickfix'
  local qf = vim.fn.getqflist { items = 1, idx = 0 }
  if not qf.items or #qf.items == 0 then
    vim.notify('Quickfix list is empty', vim.log.levels.WARN)
    return
  end

  local item
  if is_qf then
    local cur_line = vim.fn.line '.'
    item = qf.items[cur_line]
  else
    -- In source buffer: find item matching current file & line, else fallback to current qf index
    local cur_buf = vim.api.nvim_get_current_buf()
    local cur_file = vim.api.nvim_buf_get_name(cur_buf)
    local cur_line = vim.fn.line '.'
    for _, it in ipairs(qf.items) do
      if (it.bufnr == cur_buf or it.filename == cur_file) and it.lnum == cur_line then
        item = it
        break
      end
    end
    if not item and qf.idx > 0 then item = qf.items[qf.idx] end
  end

  if not item or not item.user_data or not item.user_data.details or #item.user_data.details == 0 then
    vim.notify('No extra details for this item', vim.log.levels.INFO)
    return
  end

  local lines = item.user_data.details
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'

  -- Apply syntax/diagnostic highlights
  vim.api.nvim_buf_call(buf, function()
    vim.fn.matchadd('diffAdded', '^%s*added:.*')
    vim.fn.matchadd('diffRemoved', '^%s*deleted:.*')
    vim.fn.matchadd('DiagnosticWarn', '^%s*Expected:.*')
    vim.fn.matchadd('DiagnosticInfo', '^%s*Value of:.*')
    vim.fn.matchadd('DiagnosticError', 'Failure')
  end)

  local max_width = math.floor(vim.o.columns * 0.85)
  local max_height = math.floor(vim.o.lines * 0.8)

  local longest_line = 0
  for _, l in ipairs(lines) do
    longest_line = math.max(longest_line, vim.fn.strdisplaywidth(l))
  end

  local width = math.min(max_width, math.max(50, longest_line))
  local height = math.min(max_height, math.max(1, #lines))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local title = ' ' .. (item.user_data.test or item.text or 'Error Detail') .. ' '

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    border = 'rounded',
    title = title,
    title_pos = 'center',
    style = 'minimal',
  })
  M._detail_win = win

  local close = function()
    if M._detail_win and vim.api.nvim_win_is_valid(M._detail_win) then
      vim.api.nvim_win_close(M._detail_win, true)
      M._detail_win = nil
    end
  end

  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })

  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    once = true,
    callback = close,
  })
end

return M
