local _, Helper = ...

-- The minimap fan's geometry (it was the separate addon MinimapFan until ReadyToWork 1.24.0). Its own table,
-- so these names can't clash with the rest of ReadyToWork.
local Fan = {}
Helper.FanLayout = Fan

-- Geometry only: no frames are touched here, so it can be tested on its own.

Fan.PAGE_SIZE = 15
Fan.SLOT_SIZE = 38

local PITCH = 40                  -- distance between neighbouring icon centres
local FIRST_RADIUS = 48           -- launcher centre to the first arc
local RING_GAP = 38               -- distance between arcs
local MAX_SPREAD = math.rad(130)  -- widest opening of the fan
local HALF_ICON = 19
local SCREEN_MARGIN = 4
local MAP_CLEARANCE = 6
local DIRECTION_STEP = math.rad(10)

function Fan.PageRange(total, size, page)
  size = math.max(1, math.min(24, math.floor(tonumber(size) or Fan.PAGE_SIZE)))
  local pages = math.max(1, math.ceil(total / size))
  page = math.max(1, math.min(page, pages))
  local first = (page - 1) * size + 1
  return page, pages, first, math.min(size, total - first + 1)
end

function Fan.Atan2(y, x)
  if x > 0 then return math.atan(y / x) end
  if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
  if y > 0 then return math.pi / 2 end
  if y < 0 then return -math.pi / 2 end
  return 0
end

function Fan.Clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

-- Settles slightly past the target and back, so icons land with a little weight.
function Fan.EaseOutBack(t)
  local overshoot = 1.25
  local u = t - 1
  return 1 + (overshoot + 1) * u * u * u + overshoot * u * u
end

function Fan.EaseOutCubic(t)
  local u = 1 - t
  return 1 - u * u * u
end

-- Angle between neighbours that keeps their centres PITCH apart at a radius.
local function Step(radius)
  return 2 * math.asin(PITCH / (2 * radius))
end

-- How many icons go on which arc. Up to five icons share a single arc that
-- widens as it fills; more than that stack in arcs of three, five, eight...
function Fan.Rings(count)
  local rings = {}
  if count <= 0 then
    return rings
  end
  if count <= 3 then
    rings[1] = { radius = FIRST_RADIUS, count = count }
    return rings
  end
  if count <= 5 then
    local radius = PITCH / (2 * math.sin(MAX_SPREAD / (count - 1) / 2))
    rings[1] = { radius = math.max(FIRST_RADIUS, radius), count = count }
    return rings
  end

  local remaining, radius = count, FIRST_RADIUS
  while remaining > 0 do
    local capacity = math.floor(MAX_SPREAD / Step(radius) + 0.001) + 1
    local take = math.min(capacity, remaining)
    rings[#rings + 1] = { radius = radius, count = take }
    remaining = remaining - take
    radius = radius + RING_GAP
  end
  return rings
end

-- Icon centres relative to the launcher for a fan opening along `axis`.
-- Each arc is centred on the axis and read top-to-bottom or left-to-right.
function Fan.Place(rings, axis)
  local points = {}
  local ascending = math.cos(axis - math.rad(225)) > 0
  for _, ring in ipairs(rings) do
    local step = ring.count > 1 and Step(ring.radius) or 0
    for i = 1, ring.count do
      local offset = (i - (ring.count + 1) / 2) * step
      local angle = axis + (ascending and offset or -offset)
      points[#points + 1] = { math.cos(angle) * ring.radius, math.sin(angle) * ring.radius }
    end
  end
  return points
end

local function Penalty(points, x, y, width, height, mapX, mapY, mapRadius)
  local penalty = 0
  local low = SCREEN_MARGIN + HALF_ICON
  for _, point in ipairs(points) do
    local px, py = x + point[1], y + point[2]
    penalty = penalty + math.max(0, low - px) + math.max(0, px - (width - low))
    penalty = penalty + math.max(0, low - py) + math.max(0, py - (height - low))
    if mapX then
      local dx, dy = px - mapX, py - mapY
      local depth = mapRadius + HALF_ICON + MAP_CLEARANCE - math.sqrt(dx * dx + dy * dy)
      if depth > 0 then
        penalty = penalty + depth
      end
    end
  end
  return penalty
end

-- Lays out `count` icons around a launcher at (x, y) on a width x height
-- screen. The fan opens away from the minimap; if that would leave the screen
-- or cover the minimap it turns, as little as possible, until it fits.
-- Returns the icon centres relative to an origin, that origin, and the bounds
-- of the whole fan relative to the origin.
function Fan.Layout(count, x, y, width, height, mapX, mapY, mapRadius, style)
  local rings = Fan.Rings(count)
  local outward
  if mapX and mapY and (x ~= mapX or y ~= mapY) then
    outward = Fan.Atan2(y - mapY, x - mapX)
  else
    outward = Fan.Atan2(height / 2 - y, width / 2 - x)
    mapX, mapY, mapRadius = nil, nil, nil
  end

  local points, bestScore, bestAxis
  for index = 0, 35 do
    -- 0, +10, -10, +20, -20 ... degrees away from the outward direction.
    local turn = math.ceil(index / 2) * (index % 2 == 1 and 1 or -1) * DIRECTION_STEP
    local axis = outward + turn
    local candidate = {}
    if style=="grid" or style=="line" then
      local columns=style=="grid" and math.ceil(math.sqrt(count)) or 1
      for i=1,count do
        local forward=FIRST_RADIUS+math.floor((i-1)/columns)*PITCH
        local across=((i-1)%columns-(columns-1)/2)*PITCH
        candidate[i]={math.cos(axis)*forward-math.sin(axis)*across,math.sin(axis)*forward+math.cos(axis)*across}
      end
    else candidate=Fan.Place(rings,axis) end
    local score = Penalty(candidate, x, y, width, height, mapX, mapY, mapRadius or 0) * 10
      + math.abs(math.deg(turn))
    if not bestScore or score < bestScore - 0.0001 then
      points, bestScore, bestAxis = candidate, score, axis
      if score == 0 then break end
    end
  end
  points = points or {}

  local left, right, bottom, top = -HALF_ICON, HALF_ICON, -HALF_ICON, HALF_ICON
  for _, point in ipairs(points) do
    left, right = math.min(left, point[1] - HALF_ICON), math.max(right, point[1] + HALF_ICON)
    bottom, top = math.min(bottom, point[2] - HALF_ICON), math.max(top, point[2] + HALF_ICON)
  end

  -- Last resort on a very small screen: slide the whole fan, never single icons.
  local originX = math.max(SCREEN_MARGIN - left, math.min(x, width - SCREEN_MARGIN - right))
  local originY = math.max(SCREEN_MARGIN - bottom, math.min(y, height - SCREEN_MARGIN - top))
  return points, originX, originY, left, right, bottom, top, bestAxis
end

function Fan.LayoutInView(count, view, style)
  return Fan.Layout(count, view.x, view.y, view.width, view.height, view.mapX, view.mapY, view.radius, style)
end
