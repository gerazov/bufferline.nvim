local lazy = require("bufferline.lazy")
--- @module "bufferline.utils"
local utils = lazy.require("bufferline.utils")
--- @module "bufferline.constants"
local padding = lazy.require("bufferline.constants").padding
--- @module "bufferline.models"
local models = lazy.require("bufferline.models")
--- @module "bufferline.ui"
local ui = lazy.require("bufferline.ui")

local fn = vim.fn

----------------------------------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------------------------------

--- @class GroupState
--- @field manual_groupings table<string, string>
--- @field user_groups table<string, Group>
--- @field components_by_group table<string,number>[][]

--- @class Separators
--- @field sep_start Segment[]
--- @field sep_end Segment[]

---@alias GroupSeparator fun(name: string, group:Group, hls: BufferlineHLGroup, count_item: string?): Separators
---@alias GroupSeparators table<string, GroupSeparator>
---@alias grouper fun(b: Buffer): boolean

---@class Group
---@field public id number used for identifying the group in the tabline
---@field public name string 'formatted name of the group'
---@field public display_name string original name including special characters
---@field public matcher grouper
---@field public separator GroupSeparators
---@field public priority number
---@field public highlight table<string, string>
---@field public icon string
---@field public hidden boolean
---@field public with fun(Group, Group)
---@field auto_close boolean when leaving the group automatically close it

----------------------------------------------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------------------------------------------

local PINNED_ID = "pinned"
local PINNED_NAME = "pinned"
local UNGROUPED_NAME = "ungrouped"
local UNGROUPED_ID = "ungrouped"
local PINNED_KEY = "BufferlinePinnedBuffers"

local api = vim.api
local fmt = string.format

local M = {}

----------------------------------------------------------------------------------------------------
-- UTILS
----------------------------------------------------------------------------------------------------

--- Remove illegal characters from a group name name
---@param name string
local function format_name(name)
  return name:gsub("[^%w]+", "_")
end

----------------------------------------------------------------------------------------------------
-- SEPARATORS
----------------------------------------------------------------------------------------------------
local separator = {}

local function space_end(hl_groups)
  return { { highlight = hl_groups.fill.hl, text = padding } }
end

---@param group Group,
---@param hls  table<string, table<string, string>>
---@param count string
---@return string, number
function separator.pill(group, hls, count)
  local bg_hl = hls.fill.hl
  local name, display_name = group.name, group.display_name
  local sep_grp, label_grp = hls[fmt("%s_separator", name)], hls[fmt("%s_label", name)]
  local sep_hl = sep_grp and sep_grp.hl or hls.group_separator.hl
  local label_hl = label_grp and label_grp.hl or hls.group_label.hl
  local left, right = "█", "█"
  local indicator = {
    { text = padding, highlight = bg_hl },
    { text = left, highlight = sep_hl },
    { text = display_name .. count, highlight = label_hl },
    { text = right, highlight = sep_hl },
    { text = padding, highlight = bg_hl },
  }
  return { sep_start = indicator, sep_end = space_end(hls) }
end

---@param group Group,
---@param hls  table<string, table<string, string>>
---@param count string
---@return string, number
---@type GroupSeparator
function separator.tab(group, hls, count)
  local hl = hls.fill.hl
  local indicator_hl = hls.buffer.hl
  local indicator = {
    { higlight = hl, text = padding },
    { highlight = indicator_hl, text = padding .. group.name .. count .. padding },
    { highlight = hl, text = padding },
  }
  return { sep_start = indicator, sep_end = space_end(hls) }
end

---@type GroupSeparator
function separator.none()
  return { sep_start = {}, sep_end = {} }
end

----------------------------------------------------------------------------------------------------
-- BUILTIN GROUPS
----------------------------------------------------------------------------------------------------
local builtin = {}

--- @type Group
local Group = {}

---@param o Group
---@param index number?
---@return Group
function Group:new(o, index)
  o = o or { priority = index }
  self.__index = self
  local name = format_name(o.name)
  o = vim.tbl_extend("force", o, {
    id = o.id or name,
    hidden = o.hidden == nil and false or o.hidden,
    name = name,
    display_name = o.name,
    priority = o.priority or index,
  })
  return setmetatable(o, self)
end

function Group:with(o)
  for key, value in pairs(o) do
    self[key] = value
  end
  return self
end

builtin.ungrouped = Group:new({
  id = UNGROUPED_ID,
  name = UNGROUPED_NAME,
  separator = {
    style = separator.none,
  },
})

builtin.pinned = Group:new({
  id = PINNED_ID,
  name = PINNED_NAME,
  icon = "📌",
  priority = 1,
  separator = {
    style = separator.none,
  },
})

----------------------------------------------------------------------------------------------------
-- STATE
----------------------------------------------------------------------------------------------------

--- @type GroupState
local state = {
  -- A table of buffers mapped to a specific group by a user
  manual_groupings = {},
  user_groups = {},
  --- Represents a list of maps of type `{id = buf_id, index = position in list}`
  --- so that rather than storing the components we store their positions
  --- with an easy way to look them up later.
  --- e.g. `[[group 1, {id = 12, index = 1}, {id = 10, index 2}], [group 2, {id = 5, index = 3}]]`
  components_by_group = {},
}

--- Store a list of pinned buffer as a string of ids e.g. "12,10,5"
--- in a vim.g global variable that can be persisted across vim sessions
local function persist_pinned_buffers()
  local pinned = {}
  for buf, group in pairs(state.manual_groupings) do
    if group == PINNED_ID then
      table.insert(pinned, api.nvim_buf_get_name(buf))
    end
  end
  if #pinned == 0 then
    return
  end
  vim.g[PINNED_KEY] = table.concat(pinned, ",")
end

---@param buffer Buffer
---@return number
local function get_manual_group(buffer)
  return state.manual_groupings[buffer.id]
end

--- Wrapper to abstract interacting directly with manual groups as the access mechanism
-- can vary i.e. buffer id or path and this should be changed in a centralised way.
---@param id string
---@param group_id number?
local function set_manual_group(id, group_id)
  state.manual_groupings[id] = group_id
  if group_id == PINNED_ID then
    persist_pinned_buffers()
  end
end

---Group buffers based on user criteria
---buffers only carry a copy of the group ID which is then used to retrieve the correct group
---@param buffer Buffer
function M.set_id(buffer)
  if vim.tbl_isempty(state.user_groups) then
    return
  end
  local manual_group = get_manual_group(buffer)
  if manual_group then
    return manual_group
  end
  for id, group in pairs(state.user_groups) do
    if type(group.matcher) == "function" and group.matcher(buffer) then
      return id
    end
  end
  return UNGROUPED_ID
end

---@param id number
---@return Group
function M.get_by_id(id)
  return state.user_groups[id]
end

local function generate_sublists(size)
  local list = {}
  for i = 1, size do
    list[i] = {}
  end
  return list
end

---Add group styling to the buffer component
---@param ctx RenderContext
---@return Segment?
function M.component(ctx)
  local element = ctx.tab
  local hls = ctx.current_highlights
  local group = state.user_groups[element.group]
  if not group then
    return
  end
  local group_hl = hls[group.name]
  local hl = group_hl or hls.buffer.hl
  if not group.icon then
    return nil
  end
  local extends = { { id = ui.components.id.name } }
  if group_hl then
    extends[#extends + 1] = { id = ui.components.id.duplicates }
  end
  return {
    text = group.icon,
    highlight = hl,
    attr = { extends = extends },
  }
end

---Add highlight groups for a group
---@param group Group
---@param hls BufferlineHighlights
local function set_group_highlights(group, hls)
  local hl = group.highlight
  local name = group.name
  if not hl or type(hl) ~= "table" then
    return
  end
  hls[fmt("%s_separator", name)] = {
    guifg = hl.guifg or hl.guisp or hls.group_separator.guifg,
    guibg = hls.fill.guibg,
  }
  hls[fmt("%s_label", name)] = {
    guifg = hls.fill.guibg,
    guibg = hl.guifg or hl.guisp or hls.group_separator.guifg,
  }
  hls[fmt("%s_selected", name)] = vim.tbl_extend("keep", hl, hls.buffer_selected)
  hls[fmt("%s_visible", name)] = vim.tbl_extend("keep", hl, hls.buffer_visible)
  hls[name] = vim.tbl_extend("keep", hl, hls.buffer)
end

---@param highlights BufferlineHighlights
function M.reset_highlights(highlights)
  for _, group in pairs(state.user_groups) do
    set_group_highlights(group, highlights)
  end
end

--- Pull pinned buffers saved in a vim.g global variable and restore them
--- to the manual_groupings table.
local function restore_pinned_buffers()
  local pinned = vim.g[PINNED_KEY]
  if not pinned then
    return
  end
  local manual_groupings = vim.split(pinned, ",") or {}
  for _, path in ipairs(manual_groupings) do
    local buf_id = fn.bufnr(path)
    if buf_id ~= -1 then
      set_manual_group(buf_id, PINNED_ID)
    end
  end
  ui.refresh()
end

--- NOTE: this function mutates the user's configuration.
--- Add group highlights to the user highlights table
---@param config BufferlineConfig
function M.setup(config)
  if not config then
    return
  end

  local groups = config.options.groups.items or {}

  -- NOTE: if the user has already set the pinned builtin themselves
  -- then we want each group to have a priority based on it's position in the list
  -- otherwise we want to shift the priorities of their groups by 1 to accommodate the pinned group
  local has_set_pinned = not vim.tbl_isempty(vim.tbl_filter(function(group)
    return group.id == PINNED_ID
  end, groups))

  for index, current in ipairs(groups) do
    local priority = has_set_pinned and index or index + 1
    local group = Group:new(current, priority)
    state.user_groups[group.id] = group
  end
  -- We only set the builtin groups after we know what the user has configured
  if not state.user_groups[PINNED_ID] then
    state.user_groups[PINNED_ID] = builtin.pinned
  end
  if not state.user_groups[UNGROUPED_ID] then
    state.user_groups[UNGROUPED_ID] = builtin.ungrouped:with({
      priority = vim.tbl_count(state.user_groups) + 1,
    })
  end
  for _, group in pairs(state.user_groups) do
    set_group_highlights(group, config.highlights)
  end

  -- Restore pinned buffer from the previous session
  api.nvim_create_autocmd("SessionLoadPost", { once = true, callback = restore_pinned_buffers })
end

--- Add the current highlight for a specific buffer
--- NOTE: this function mutates the current highlights.
---@param buffer Buffer
---@param highlights table<string, table<string, string>>
---@param current_hl table<string, string>
function M.set_current_hl(buffer, highlights, current_hl)
  local group = state.user_groups[buffer.group]
  if not group or not group.name or not group.highlight then
    return
  end
  local name = group.name
  local hl_name = buffer:current() and fmt("%s_selected", name)
    or buffer:visible() and fmt("%s_visible", name)
    or name
  if highlights[hl_name] then
    current_hl[name] = highlights[hl_name].hl
  else
    utils.log.debug(fmt("%s group highlight not found", name))
  end
end

---Execute a command on each buffer of a group
---@param group_name string
---@param callback fun(b: Buffer)
function M.command(group_name, callback)
  local group = utils.find(state.components_by_group, function(list)
    return list.name == group_name
  end)
  utils.for_each(group, callback)
end

---@generic T
---@param attr string
---@return fun(arg: T): Group
local function group_by(attr)
  return function(value)
    for _, grp in pairs(state.user_groups) do
      if grp[attr] == value then
        return grp
      end
    end
  end
end

local group_by_name = group_by("name")
local group_by_priority = group_by("priority")

---@param buffer Buffer
function M.is_pinned(buffer)
  return get_manual_group(buffer) == PINNED_ID
end

--- Add a buffer to a group manually
---@param group_name string
---@param buffer Buffer
function M.add_to_group(group_name, buffer)
  local group = group_by_name(group_name)
  if group then
    set_manual_group(buffer.id, group.id)
  end
end

---@param group_name string
---@param buffer Buffer
function M.remove_from_group(group_name, buffer)
  local group = group_by_name(group_name)
  if group then
    local id = get_manual_group(buffer)
    set_manual_group(buffer.id, id ~= group.id and id or nil)
  end
end

---@param id string
---@param value boolean
function M.set_hidden(id, value)
  assert(id, "You must pass in a group ID to set its state")
  local group = state.user_groups[id]
  if group then
    group.hidden = value
  end
end

---@param priority number
---@param name string?
function M.toggle_hidden(priority, name)
  local group = priority and group_by_priority(priority) or group_by_name(name)
  if group then
    group.hidden = not group.hidden
  end
end

---Get the names for all bufferline groups
---@param include_empty boolean?
---@return string[]
function M.names(include_empty)
  if not state.user_groups then
    return {}
  end
  local names = {}
  for _, group in pairs(state.components_by_group) do
    if include_empty or (group and #group > 0) then
      table.insert(names, group.name)
    end
  end
  return names
end

--- Draw the separator start component for a group
---@param group Group
---@param hls BufferlineHighlights
---@param count number
---@return Separators
local function create_indicator(group, hls, count)
  local count_item = group.hidden and fmt("(%s)", count) or ""
  local seps = group.separator.style(group, hls, count_item)
  if seps.sep_start then
    table.insert(
      seps.sep_start,
      ui.make_clickable("handle_group_click", group.priority, { attr = { global = true } })
    )
  end
  return seps
end

---Create the visual indicators bookending buffer groups
---@param group_id number
---@param components Component[]
---@return Component
---@return Component
local function get_group_marker(group_id, components)
  local group = state.user_groups[group_id]
  if not group then
    return
  end
  local GroupView = models.GroupView
  local hl_groups = require("bufferline.config").get("highlights")

  group.separator = group.separator or {}
  --- NOTE: the default buffer group style is the pill
  group.separator.style = group.separator.style or separator.pill
  if not group.separator.style then
    return
  end

  local seps = create_indicator(group, hl_groups, #components)
  local s_start, s_end = seps.sep_start, seps.sep_end
  local group_start, group_end
  local s_start_length = ui.get_component_size(s_start)
  local s_end_length = ui.get_component_size(s_end)
  if s_start_length > 0 then
    group_start = GroupView:new({
      type = "group_start",
      length = s_start_length,
      component = function()
        return s_start
      end,
    })
  end
  if s_end_length > 0 then
    group_end = GroupView:new({
      type = "group_end",
      length = s_end_length,
      component = function()
        return s_end
      end,
    })
  end
  return group_start, group_end
end

--- The aim is to have buffers easily accessible by key as well as a list of sorted and prioritized
--- buffers for things like navigation. This function takes advantage of lua's ability
--- to sort string keys as well as numerical keys in a table, this way each sublist has
--- not only the group information but contains it's buffers
---@param components Component[]
---@return Component[]
local function sort_by_groups(components)
  local sorted = {}
  local clustered = generate_sublists(vim.tbl_count(state.user_groups))
  for index, tab in ipairs(components) do
    local buf = tab:as_element()
    if buf then
      local group = state.user_groups[buf.group]
      local sublist = clustered[group.priority]
      if not sublist.name then
        sublist.id = group.id
        sublist.name = group.name
        sublist.priorty = group.priority
        sublist.hidden = group.hidden
        sublist.display_name = group.display_name
      end
      table.insert(sublist, { id = buf.id, index = index })
      table.insert(sorted, buf)
    end
  end
  return sorted, clustered
end

-- FIXME:
-- 1. this function does a lot of looping that can maybe be consolidated
---@param components Component[]
---@param sorter fun(list: Component[]):Component[]
---@return Component[]
function M.render(components, sorter)
  components, state.components_by_group = sort_by_groups(components)
  if vim.tbl_isempty(state.components_by_group) then
    return components
  end
  local result = {}
  for _, sublist in ipairs(state.components_by_group) do
    local buf_group_id = sublist.id
    local buf_group = state.user_groups[buf_group_id]
    --- convert our components by group which is essentially and index of tab positions and ids
    --- to the actual tab by pulling the full value out of the tab map
    local items = utils.map(function(map)
      local t = components[map.index]
      --- filter out tab views that are hidden
      t.hidden = buf_group and buf_group.hidden
      return t
    end, sublist)
    --- Sort *each* group, TODO: in the future each group should be able to have it's own sorter
    items = sorter(items)

    if #sublist > 0 then
      local group_start, group_end = get_group_marker(buf_group_id, sublist)
      if group_start then
        table.insert(items, 1, group_start)
        items[#items + 1] = group_end
      end
    end
    --- NOTE: there is no easy way to flatten a list of lists of non-scalar values like these
    --- lists of objects since each object needs to be checked that it is in fact an object
    --- not a list
    vim.list_extend(result, items)
  end
  return result
end

M.builtin = builtin
M.separator = separator

if utils.is_test() then
  M.state = state
  M.sort_by_groups = sort_by_groups
  M.get_manual_group = get_manual_group
  M.set_manual_group = set_manual_group
end

return M
