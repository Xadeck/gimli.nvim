vim.api.nvim_create_user_command('Gimli', require('gimli-nvim').run, { desc = 'Load Bazel errors into quickfix' })
vim.api.nvim_create_user_command(
  'GimliDetail',
  function() require('gimli-nvim').show_detail() end,
  { desc = 'Show Gimli error details' }
)

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('GimliQF', { clear = true }),
  pattern = 'qf',
  callback = function(ev)
    vim.keymap.set(
      'n',
      'K',
      function() require('gimli-nvim').show_detail() end,
      { buffer = ev.buf, desc = 'Show Gimli error details', silent = true }
    )
  end,
})
