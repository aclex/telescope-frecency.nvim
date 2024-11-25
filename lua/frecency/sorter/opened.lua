local Default = require "frecency.sorter.default"

---@class FrecencySorterOpened: FrecencySorterDefault
---@field protected buffers string[]
---@field protected buffers_map table<string, boolean>
local Opened = setmetatable({}, { __index = Default })

---@return FrecencySorterOpened
Opened.new = function()
  local self = setmetatable(Default.new(), { __index = Opened }) --[[@as FrecencySorterOpened]]
  self.buffers = vim.tbl_map(vim.api.nvim_buf_get_name, vim.api.nvim_list_bufs())
  self.buffers_map = {}
  for _, buffer in ipairs(self.buffers) do
    self.buffers_map[buffer] = true
  end
  return self
end

function Opened:sort(files)
  local sorted = Default.sort(self, files)
  ---@type FrecencyDatabaseEntry[], FrecencyDatabaseEntry[]
  local result, others = {}, {}
  for _, entry in ipairs(sorted) do
    table.insert(self.buffers_map[entry.path] and result or others, entry)
  end
  for _, entry in ipairs(others) do
    table.insert(result, entry)
  end
  return result
end

return Opened