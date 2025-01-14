local config = require "frecency.config"
local fs = require "frecency.fs"
local os_util = require "frecency.os_util"
local recency = require "frecency.recency"
local log = require "frecency.log"
local timer = require "frecency.timer"
local lazy_require = require "frecency.lazy_require"
local Job = lazy_require "plenary.job" --[[@as FrecencyPlenaryJob]]
local async = lazy_require "plenary.async" --[[@as FrecencyPlenaryAsync]]

---@class FrecencyFinder
---@field config FrecencyFinderConfig
---@field closed boolean
---@field entries FrecencyEntry[]
---@field scanned_entries FrecencyEntry[]
---@field entry_maker FrecencyEntryMakerInstance
---@field paths? string[]
---@field private database FrecencyDatabase
---@field private rx FrecencyPlenaryAsyncControlChannelRx
---@field private tx FrecencyPlenaryAsyncControlChannelTx
---@field private scan_rx FrecencyPlenaryAsyncControlChannelRx
---@field private scan_tx FrecencyPlenaryAsyncControlChannelTx
---@field private need_scan_db boolean
---@field private need_scan_dir boolean
---@field private seen table<string, boolean>
---@field private process table<string, { obj: VimSystemObj, done: boolean }>
---@field private state FrecencyState
local Finder = {
  ---@type fun(): string[]?
  cmd = (function()
    local candidates = {
      { "fdfind", "-Htf", "-E", ".git" },
      { "fd", "-Htf", "-E", ".git" },
      { "rg", "-.g", "!.git", "--files" },
    }
    ---@type string[]?
    local cache
    return function()
      if not cache then
        for _, candidate in ipairs(candidates) do
          if vim.system then
            if pcall(vim.system, { candidate[1], "--version" }) then
              cache = candidate
              break
            end
          elseif
            pcall(function()
              Job:new { command = candidate[1], args = { "--version" } }
            end)
          then
            cache = candidate
            break
          end
        end
      end
      return cache
    end
  end)(),
}

---@class FrecencyFinderConfig
---@field chunk_size? integer default: 1000
---@field ignore_filenames? string[] default: {}
---@field sleep_interval? integer default: 50

---@param database FrecencyDatabase
---@param entry_maker FrecencyEntryMakerInstance
---@param need_scandir boolean
---@param paths string[]?
---@param state FrecencyState
---@param finder_config? FrecencyFinderConfig
---@return FrecencyFinder
Finder.new = function(database, entry_maker, need_scandir, paths, state, finder_config)
  local tx, rx = async.control.channel.mpsc()
  local scan_tx, scan_rx = async.control.channel.mpsc()
  local self = setmetatable({
    config = vim.tbl_extend("force", { chunk_size = 1000, sleep_interval = 50 }, finder_config or {}),
    closed = false,
    database = database,
    entry_maker = entry_maker,
    paths = paths,
    process = {},
    state = state,

    seen = {},
    entries = {},
    scanned_entries = {},
    need_scan_db = true,
    need_scan_dir = need_scandir and not not paths,
    rx = rx,
    tx = tx,
    scan_rx = scan_rx,
    scan_tx = scan_tx,
  }, {
    __index = Finder,
    ---@param self FrecencyFinder
    __call = function(self, ...)
      return self:find(...)
    end,
  })
  if self.config.ignore_filenames then
    for _, name in ipairs(self.config.ignore_filenames or {}) do
      self.seen[name] = true
    end
  end
  return self
end

---@param epoch? integer
---@return nil
function Finder:start(epoch)
  ---@type table<string, boolean>
  local results = {}
  if config.workspace_scan_cmd ~= "LUA" and self.need_scan_dir then
    local cmd = config.workspace_scan_cmd --[=[@as string[]]=]
      or Finder.cmd()
    if cmd then
      for _, path in ipairs(self.paths) do
        log.debug(("scan_dir_cmd: %s: %s"):format(vim.inspect(cmd), path))
        results[path] = self:scan_dir_cmd(path, cmd)
      end
    end
  end
  async.void(function()
    -- NOTE: return to the main loop to show the main window
    async.util.scheduler()
    for _, file in ipairs(self:get_results(self.paths, epoch)) do
      file.path = os_util.normalize_sep(file.path)
      local entry = self.entry_maker(file)
      self.tx.send(entry)
    end
    self.tx.send(nil)
    if self.need_scan_dir then
      for _, path in pairs(self.paths) do
        if not results[path] then
          log.debug("scan_dir_lua: " .. path)
          async.util.scheduler()
          self:scan_dir_lua(path)
        end
      end
    end
  end)()
end

---@param path string
---@param cmd string[]
---@return boolean
function Finder:scan_dir_cmd(path, cmd)
  local function stdout(err, chunk)
    if not self.closed and not err and chunk then
      for name in chunk:gmatch "[^\n]+" do
        local cleaned = name:gsub("^%./", "")
        local fullpath = os_util.join_path(path, cleaned)
        local entry = self.entry_maker { id = 0, count = 0, path = fullpath, score = 0 }
        self.scan_tx.send(entry)
      end
    end
  end

  local function on_exit()
    self.process[path] = { done = true }
    local done_all = true
    for _, p in ipairs(self.paths) do
      if not self.process[p] or not self.process[p].done then
        done_all = false
        break
      end
    end
    if done_all then
      self:close()
      self.scan_tx.send(nil)
    end
  end

  local ok, process
  if vim.system then
    ---@diagnostic disable-next-line: assign-type-mismatch
    ok, process = pcall(vim.system, cmd, {
      cwd = path,
      text = true,
      stdout = stdout,
    }, on_exit)
  else
    -- for Neovim v0.9.x
    ok, process = pcall(function()
      local args = {}
      for i, arg in ipairs(cmd) do
        if i > 1 then
          table.insert(args, arg)
        end
      end
      log.debug { cmd = cmd[1], args = args }
      local job = Job:new {
        cwd = path,
        command = cmd[1],
        args = args,
        on_stdout = stdout,
        on_exit = on_exit,
      }
      job:start()
      return job.handle
    end)
  end
  if ok then
    self.process[path] = {
      obj = process --[[@as VimSystemObj]],
      done = false,
    }
  end
  return ok
end

---@async
---@param path string
---@return nil
function Finder:scan_dir_lua(path)
  local count = 0
  for name in fs.scan_dir(path) do
    if self.closed then
      break
    end
    local fullpath = os_util.join_path(path, name)
    local entry = self.entry_maker { id = 0, count = 0, path = fullpath, score = 0 }
    self.scan_tx.send(entry)
    count = count + 1
    if count % self.config.chunk_size == 0 then
      async.util.sleep(self.config.sleep_interval)
    end
  end
  self.scan_tx.send(nil)
end

---@async
---@param _ string
---@param process_result fun(entry: FrecencyEntry): nil
---@param process_complete fun(): nil
---@return nil
function Finder:find(_, process_result, process_complete)
  if self:process_table(process_result, self.entries) then
    return
  end
  if self.need_scan_db then
    if self:process_channel(process_result, self.entries, self.rx) then
      return
    end
    self.need_scan_db = false
  end
  -- HACK: This is needed for heavy workspaces to show up entries immediately.
  async.util.scheduler()
  if self:process_table(process_result, self.scanned_entries) then
    return
  end
  if self.need_scan_dir then
    if self:process_channel(process_result, self.scanned_entries, self.scan_rx, #self.entries) then
      return
    end
    self.need_scan_dir = false
  end
  process_complete()
end

---@param process_result fun(entry: FrecencyEntry): nil
---@param entries FrecencyEntry[]
---@return boolean?
function Finder.process_table(_, process_result, entries)
  for _, entry in ipairs(entries) do
    if process_result(entry) then
      return true
    end
  end
end

---@async
---@param process_result fun(entry: FrecencyEntry): nil
---@param entries FrecencyEntry[]
---@param rx FrecencyPlenaryAsyncControlChannelRx
---@param start_index? integer
---@return boolean?
function Finder:process_channel(process_result, entries, rx, start_index)
  -- HACK: This is needed for small workspaces that it shows up entries fast.
  async.util.sleep(self.config.sleep_interval)
  local index = #entries > 0 and entries[#entries].index or start_index or 0
  local count = 0
  while true do
    local entry = rx.recv()
    if not entry then
      break
    elseif not self.seen[entry.filename] then
      self.seen[entry.filename] = true
      index = index + 1
      entry.index = index
      table.insert(entries, entry)
      if process_result(entry) then
        return true
      end
    end
    count = count + 1
    if count % self.config.chunk_size == 0 then
      self:reflow_results()
    end
  end
end

---@param workspaces? string[]
---@param epoch? integer
---@return FrecencyFile[]
function Finder:get_results(workspaces, epoch)
  log.debug { workspaces = workspaces or "NONE" }
  timer.track "fetching start"
  local files = self.database:get_entries(workspaces, epoch)
  timer.track "fetching finish"
  for _, file in ipairs(files) do
    file.score = file.ages and recency.calculate(file.count, file.ages) or 0
    file.ages = nil
  end
  timer.track "making results"

  table.sort(files, function(a, b)
    return a.score > b.score or (a.score == b.score and a.path > b.path)
  end)
  timer.track "sorting finish"
  return files
end

function Finder:close()
  self.closed = true
  for _, process in pairs(self.process) do
    if not process.done then
      process.obj:kill(9)
    end
  end
end

---@async
---@return nil
function Finder:reflow_results()
  local picker = self.state:get()
  if not picker then
    return
  end
  async.util.scheduler()

  local function reflow()
    local bufnr = picker.results_bufnr
    local win = picker.results_win
    if not bufnr or not win or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(win) then
      return
    end
    picker:clear_extra_rows(bufnr)
    if picker.sorting_strategy == "descending" then
      local manager = picker.manager
      if not manager then
        return
      end
      local worst_line = picker:get_row(manager:num_results())
      local wininfo = vim.fn.getwininfo(win)[1]
      local bottom = vim.api.nvim_buf_line_count(bufnr)
      if not self.reflowed or worst_line > wininfo.botline then
        self.reflowed = true
        vim.api.nvim_win_set_cursor(win, { bottom, 0 })
      end
    end
  end

  if vim.in_fast_event() then
    reflow()
  else
    vim.schedule(reflow)
  end
end

return Finder
