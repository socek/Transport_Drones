-- Requesting transport drones into a depot without having to carry them there by hand.
--
-- * The depot window (real depot or ghost) gets a panel with the drone counts and two sliders:
--   drones (a built depot takes them from the player's inventory; a ghost gets them added to its
--   insert plan, so robots deliver them right after building it) and the requested item (from the
--   inventory into a built depot's output; greyed out where it can't apply).
-- * Blueprints store the drone count as a native item request (BlueprintEntity.items), counting
--   both drones already in the depot and drones still requested. A ghost placed from such a
--   blueprint shows the request and the engine handles delivery itself.
--
-- A depot holds at most max_drones drones (drone ingredient amount * overload_multiplier in
-- data/make_request_recipes.lua); requests are capped so the total never goes past that.

local max_drones = 100
local drone_item = "transport-drone"
local frame_name = "transport_drones_drone_request_frame"

-- Depots that keep drones in their crafter_input inventory.
local drone_depots =
{
  ["request-depot"] = true,
  ["buffer-depot"] = true,
  ["fuel-depot"] = true,
  ["mini-request-depot"] = true,
}

local depot_names = {}
for name in pairs (drone_depots) do
  table.insert(depot_names, name)
end

local is_ghost = function(entity)
  return entity.type == "entity-ghost"
end

local get_depot_name = function(entity)
  if is_ghost(entity) then
    return entity.ghost_name
  end
  return entity.name
end

local is_drone_depot = function(entity)
  return entity and entity.valid and drone_depots[get_depot_name(entity)] or false
end

-- Number of transport drones an insert plan list asks for.
local count_planned = function(plans)
  local sum = 0
  for _, plan in pairs (plans or {}) do
    local id = plan.id
    if id and id.name == drone_item then
      local positions = plan.items and plan.items.in_inventory
      for _, position in pairs (positions or {}) do
        sum = sum + (position.count or 1)
      end
    end
  end
  return sum
end

-- Same list with the transport-drone request replaced by `count` (or removed for 0), other
-- requests kept as they were.
local with_drone_plan = function(plans, count)
  local result = {}
  for _, plan in pairs (plans or {}) do
    if not (plan.id and plan.id.name == drone_item) then
      table.insert(result, plan)
    end
  end
  if count > 0 then
    for _, plan in pairs (util.drone_item_request_modules(count)) do
      table.insert(result, plan)
    end
  end
  return result
end

local get_drone_inventory_count = function(entity)
  if is_ghost(entity) then return 0 end
  local inventory = entity.get_inventory(defines.inventory.crafter_input)
  if not inventory then return 0 end
  return inventory.get_item_count{name = drone_item, quality = util.normal_quality}
end

local get_pending_count = function(entity)
  if is_ghost(entity) then
    return count_planned(entity.insert_plan)
  end
  local proxy = entity.item_request_proxy
  if proxy and proxy.valid then
    return count_planned(proxy.insert_plan)
  end
  return 0
end

local lib = {}

-- Drones in the depot plus drones still on order, capped at the depot's limit.
lib.get_total_drone_count = function(entity)
  if not is_drone_depot(entity) then return 0 end
  return math.min(max_drones, get_drone_inventory_count(entity) + get_pending_count(entity))
end

lib.max_drones = max_drones
lib.is_drone_depot = is_drone_depot
lib.with_drone_plan = with_drone_plan

-- Request `amount` more drones for the depot (or its ghost). Returns how many were actually
-- added, or nil plus a locale key if nothing could be requested.
local request_drones = function(entity, amount)
  if not is_drone_depot(entity) then return nil, "drone-request-invalid" end

  if not is_ghost(entity) then
    -- A request/buffer depot only has a drone slot while a request recipe is set.
    local inventory = entity.get_inventory(defines.inventory.crafter_input)
    if not (inventory and #inventory > 0) then
      return nil, "drone-request-no-recipe"
    end
  end

  local in_depot = get_drone_inventory_count(entity)
  local pending = get_pending_count(entity)
  local new_pending = math.min(max_drones - in_depot, pending + amount)
  if new_pending <= pending then
    return nil, "drone-request-full"
  end

  if is_ghost(entity) then
    entity.insert_plan = with_drone_plan(entity.insert_plan, new_pending)
    return new_pending - pending
  end

  local proxy = entity.item_request_proxy
  if proxy and proxy.valid then
    proxy.insert_plan = with_drone_plan(proxy.insert_plan, new_pending)
  else
    proxy = entity.surface.create_entity
    {
      name = "item-request-proxy",
      position = entity.position,
      force = entity.force,
      target = entity,
      modules = util.drone_item_request_modules(new_pending)
    }
    if not proxy then
      return nil, "drone-request-invalid"
    end
  end
  return new_pending - pending
end

-- Setting how many drones / requested items a depot holds, straight from (and back into) a
-- player's (or any) inventory. Every slider picks a target amount, not a delta: moving it up puts
-- things in, moving it down takes them out - limited by what the inventory has and has room for.

-- Lets depot_common hand over its depot lookup (it requires this file, so not the other way).
local get_depot_for_entity = function(entity) return nil end
lib.set_depot_lookup = function(f) get_depot_for_entity = f end

-- Drones out on the road still sit in the depot's inventory as items; those can't be taken out.
local get_active_drone_count = function(entity)
  local depot = get_depot_for_entity(entity)
  if depot and depot.get_active_drone_count then
    return depot:get_active_drone_count()
  end
  return 0
end

-- What a request/buffer depot is set to request, if it's an item (not a fluid, not unset).
local get_requested_item = function(entity)
  if is_ghost(entity) then return end
  local recipe, quality = entity.get_recipe()
  local product = util.get_recipe_product(recipe)
  if not (product and product.type == "item") then return end
  return product.name, (quality and quality.name) or util.normal_quality
end

-- Trim a pending drone request so drones in depot + requested never exceed the limit.
local trim_pending = function(entity)
  local proxy = entity.item_request_proxy
  if not (proxy and proxy.valid) then return end
  local room = max_drones - get_drone_inventory_count(entity)
  local pending = count_planned(proxy.insert_plan)
  if pending > room then
    proxy.insert_plan = with_drone_plan(proxy.insert_plan, math.max(room, 0))
  end
end

local drone_id = {name = drone_item, quality = util.normal_quality}

local has_drone_slot = function(entity)
  local inventory = entity.get_inventory(defines.inventory.crafter_input)
  return inventory and #inventory > 0
end

-- Range the drone slider can cover: returns min, max, current. min == max means "nothing to do".
local get_drone_range = function(entity, source)
  if is_ghost(entity) then
    return 0, max_drones, get_pending_count(entity)
  end
  if not (source and has_drone_slot(entity)) then return 0, 0, 0 end
  local current = get_drone_inventory_count(entity)
  local have = source.get_item_count(drone_id)
  local room = source.get_insertable_count(drone_id)
  local min = math.min(current, math.max(get_active_drone_count(entity), current - room))
  local max = math.max(current, math.min(max_drones, current + have))
  return min, max, current
end

-- A crafter's result slots hold up to the recipe's result amount each (65000 for the request
-- recipes, see data/make_request_recipes.lua) - not plain stack sizes, which is all
-- get_insertable_count knows about (it says 700 plates where 455000 really fit). Measured in game.
local get_item_capacity = function(entity, name)
  local product = util.get_recipe_product(entity.get_recipe())
  local per_slot = (product and product.amount) or prototypes.item[name].stack_size
  return #entity.get_output_inventory() * per_slot
end

-- Range the item slider can cover: returns min, max, current.
local get_item_range = function(entity, source)
  local name, quality = get_requested_item(entity)
  if not (name and source) then return 0, 0, 0 end
  local id = {name = name, quality = quality}
  local current = entity.get_output_inventory().get_item_count(id)
  local have = source.get_item_count(id)
  local room = source.get_insertable_count(id)
  local min = math.max(0, current - room)
  local max = math.max(current, math.min(get_item_capacity(entity, name), current + have))
  return min, max, current
end

-- Move items between `source` and `inventory` so `inventory` holds `target` of `id`, within the
-- given range. Returns the signed amount moved into `inventory`.
local move_to_target = function(inventory, source, id, target, min, max, current)
  target = math.max(min, math.min(max, target))
  if target > current then
    local inserted = inventory.insert{name = id.name, quality = id.quality, count = target - current}
    if inserted > 0 then source.remove{name = id.name, quality = id.quality, count = inserted} end
    return inserted
  elseif target < current then
    local removed = inventory.remove{name = id.name, quality = id.quality, count = current - target}
    if removed > 0 then
      local given = source.insert{name = id.name, quality = id.quality, count = removed}
      if given < removed then
        -- Shouldn't happen (the range already respects the free space), but never delete items.
        inventory.insert{name = id.name, quality = id.quality, count = removed - given}
      end
      return -given
    end
  end
  return 0
end

-- Set the depot's drone count to `target` (from/to `source`), or a ghost's requested drones.
-- Returns the signed change.
local set_drones = function(entity, source, target)
  if not is_drone_depot(entity) then return 0 end
  local min, max, current = get_drone_range(entity, source)
  if is_ghost(entity) then
    target = math.max(min, math.min(max, target))
    entity.insert_plan = with_drone_plan(entity.insert_plan, target)
    return target - current
  end
  if min == max then return 0 end
  local moved = move_to_target(entity.get_inventory(defines.inventory.crafter_input), source, drone_id, target, min, max, current)
  trim_pending(entity)
  return moved
end

-- Set how many of the requested item the depot's output holds (from/to `source`).
local set_item = function(entity, source, target)
  if not is_drone_depot(entity) then return 0 end
  local min, max, current = get_item_range(entity, source)
  if min == max then return 0 end
  local name, quality = get_requested_item(entity)
  return move_to_target(entity.get_output_inventory(), source, {name = name, quality = quality}, target, min, max, current)
end

-- Older "add N" entry points, kept for script/self_test.lua.
local transfer_drones = function(entity, source, count)
  local _, _, current = get_drone_range(entity, source)
  return math.max(0, set_drones(entity, source, current + count))
end

local transfer_item = function(entity, source, count)
  local _, _, current = get_item_range(entity, source)
  return math.max(0, set_item(entity, source, current + count))
end

lib.set_drones = set_drones -- exposed for script/self_test.lua
lib.set_item = set_item
lib.get_drone_range = get_drone_range
lib.get_item_range = get_item_range
lib.transfer_drones = transfer_drones
lib.transfer_item = transfer_item
lib.request_drones = request_drones

local status_caption = function(entity)
  if is_ghost(entity) then
    return {"drone-request-status-ghost", get_pending_count(entity), max_drones}
  end
  return {"drone-request-status", get_drone_inventory_count(entity), get_pending_count(entity), max_drones}
end

local destroy_frame = function(player)
  local frame = player.gui.relative[frame_name]
  if frame then frame.destroy() end
end

-- One "slider + number + Apply" row. key is "drones" or "item".
local transfer_prefix = "transport_drones_transfer_"
local add_transfer_row = function(parent, key)
  local row = parent.add{type = "flow", name = "row_" .. key, direction = "vertical"}
  row.style.top_margin = 8
  row.add{type = "line", direction = "horizontal"}
  local label = row.add{type = "label", name = "row_label"}
  label.style.single_line = false
  label.style.maximal_width = 260
  local controls = row.add{type = "flow", name = "controls", direction = "horizontal"}
  controls.style.vertical_align = "center"
  local slider = controls.add{type = "slider", name = transfer_prefix .. key .. "_slider", minimum_value = 0, maximum_value = 1, value = 0, value_step = 1, discrete_values = true}
  slider.style.width = 130
  local text = controls.add{type = "textfield", name = transfer_prefix .. key .. "_text", text = "0", numeric = true, allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true}
  text.style.width = 60
  controls.add{type = "button", name = transfer_prefix .. key .. "_apply", caption = {"depot-apply-button"}, tooltip = {"depot-apply-tooltip"}}
  return row
end

local get_row_state = function(row)
  return row.tags or {}
end

-- Show `value` on the row and enable Apply only when it would change something.
local set_row_value = function(controls, key, value, state)
  controls[transfer_prefix .. key .. "_slider"].slider_value = value
  local text = controls[transfer_prefix .. key .. "_text"]
  if tonumber(text.text) ~= value then text.text = tostring(value) end
  controls[transfer_prefix .. key .. "_apply"].enabled = state.min ~= state.max and value ~= state.current
end

-- Re-range a row to [min, max] around `current`; min == max greys it out. The slider sits on max
-- by default: when the window opens, after Apply, and whenever it was still on the previous max
-- (so it follows e.g. picking up more drones) - a value the player chose stays put.
local update_row = function(row, key, min, max, current, initial)
  local controls = row.controls
  local slider = controls[transfer_prefix .. key .. "_slider"]
  local previous = get_row_state(row)
  local value
  if initial or slider.slider_value == previous.max then
    value = max
  else
    value = math.max(min, math.min(max, slider.slider_value))
  end
  local usable = min ~= max
  slider.set_slider_minimum_maximum(min, usable and max or min + 1)
  slider.enabled = usable
  controls[transfer_prefix .. key .. "_text"].enabled = usable
  row.row_label.enabled = usable
  local state = {min = min, max = max, current = current}
  row.tags = state
  set_row_value(controls, key, value, state)
end

local get_source = function(player)
  return player.get_main_inventory()
end

local update_frame = function(player, entity, initial)
  local frame = player.gui.relative[frame_name]
  if not frame then return end
  local inner = frame.inner
  inner.status.caption = status_caption(entity)

  local source = get_source(player)

  -- Drones: in/out of a built depot via the inventory, or the requested count on a ghost.
  local drones_row = inner.row_drones
  local min, max, current = get_drone_range(entity, source)
  if is_ghost(entity) then
    drones_row.row_label.caption = {"depot-drones-ghost"}
  else
    drones_row.row_label.caption = {"depot-drones", source and source.get_item_count(drone_id) or 0}
  end
  update_row(drones_row, "drones", min, max, current, initial)

  -- Requested item: always shown, greyed out where there's nothing it could do (ghost, no request
  -- set, fluid request, fuel depot, nothing to move).
  local item_row = inner.row_item
  local name, quality = get_requested_item(entity)
  if name then
    local have = source and source.get_item_count{name = name, quality = quality} or 0
    item_row.row_label.caption = {"depot-item", "[item=" .. name .. ",quality=" .. quality .. "]", have}
  else
    item_row.row_label.caption = {"depot-item-none"}
  end
  min, max, current = get_item_range(entity, source)
  update_row(item_row, "item", min, max, current, initial)
end

local build_frame = function(player, entity)
  destroy_frame(player)

  local frame = player.gui.relative.add
  {
    type = "frame",
    name = frame_name,
    caption = {"drone-request-title"},
    direction = "vertical",
    anchor =
    {
      gui = defines.relative_gui_type.assembling_machine_gui,
      position = defines.relative_gui_position.right,
      names = depot_names,
      ghost_mode = "both"
    }
  }

  local inner = frame.add{type = "frame", name = "inner", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  local label = inner.add{type = "label", name = "status"}
  label.style.single_line = false
  label.style.maximal_width = 260

  add_transfer_row(inner, "drones")
  add_transfer_row(inner, "item")

  update_frame(player, entity, true)
end

local get_opened_depot = function(player)
  local entity = player.opened
  if player.opened_gui_type == defines.gui_type.entity and is_drone_depot(entity) then
    return entity
  end
end

local on_gui_opened = function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local entity = event.entity
  if event.gui_type ~= defines.gui_type.entity or not is_drone_depot(entity) then
    destroy_frame(player)
    return
  end
  build_frame(player, entity)
end

local on_gui_closed = function(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  destroy_frame(player)
end

-- "transport_drones_transfer_<key>_<part>" -> key, part
local parse_transfer_name = function(name)
  if name:sub(1, #transfer_prefix) ~= transfer_prefix then return end
  return name:sub(#transfer_prefix + 1):match("^(%a+)_(%a+)$")
end

local on_gui_click = function(event)
  local element = event.element
  if not (element and element.valid) then return end
  if element.get_mod() ~= "Transport_Drones" then return end

  local key, part = parse_transfer_name(element.name)
  if not (key and part == "apply") then return end

  local player = game.get_player(event.player_index)
  if not player then return end
  local entity = get_opened_depot(player)
  if not entity then return end

  local target = element.parent[transfer_prefix .. key .. "_slider"].slider_value
  local source = get_source(player)
  local changed = 0
  if key == "drones" then
    changed = set_drones(entity, source, target)
  elseif key == "item" then
    changed = set_item(entity, source, target)
  end

  local text
  if key == "drones" and is_ghost(entity) then
    text = {"depot-requested", target}
  elseif changed > 0 then
    text = {"depot-inserted", changed}
  elseif changed < 0 then
    text = {"depot-taken", -changed}
  end
  if text then
    player.create_local_flying_text{text = text, create_at_cursor = true}
  else
    player.create_local_flying_text{text = {"depot-nothing-changed"}, create_at_cursor = true}
    player.play_sound{path = "utility/cannot_build"}
  end
  update_frame(player, entity, true)
end

-- Slider moved -> mirror it into the number field.
local on_gui_value_changed = function(event)
  local element = event.element
  if not (element and element.valid) or element.get_mod() ~= "Transport_Drones" then return end
  local key, part = parse_transfer_name(element.name)
  if not (key and part == "slider") then return end
  set_row_value(element.parent, key, element.slider_value, get_row_state(element.parent.parent))
end

-- Number typed -> clamp it to the row's range and move the slider.
local on_gui_text_changed = function(event)
  local element = event.element
  if not (element and element.valid) or element.get_mod() ~= "Transport_Drones" then return end
  local key, part = parse_transfer_name(element.name)
  if not (key and part == "text") then return end
  local state = get_row_state(element.parent.parent)
  local value = math.max(state.min or 0, math.min(tonumber(element.text) or 0, state.max or 0))
  local controls = element.parent
  controls[transfer_prefix .. key .. "_slider"].slider_value = value
  controls[transfer_prefix .. key .. "_apply"].enabled = state.min ~= state.max and value ~= state.current
end

-- Keep the counts live while the window is open (robots delivering, inventory changing).
local on_tick = function(event)
  if event.tick % 30 ~= 0 then return end
  for _, player in pairs (game.connected_players) do
    if player.gui.relative[frame_name] then
      local entity = get_opened_depot(player)
      if entity then
        update_frame(player, entity)
      end
    end
  end
end

lib.events =
{
  [defines.events.on_tick] = on_tick,
  [defines.events.on_gui_opened] = on_gui_opened,
  [defines.events.on_gui_closed] = on_gui_closed,
  [defines.events.on_gui_click] = on_gui_click,
  [defines.events.on_gui_value_changed] = on_gui_value_changed,
  [defines.events.on_gui_text_changed] = on_gui_text_changed,
}

return lib
