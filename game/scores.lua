-- High score table. Every score is kept in scores.txt in the save folder. In the browser build
-- the shared online table from the leaderboard server is shown instead, reached through the page's
-- JavaScript (web/leaderboard.js): requests go out as print lines, answers come back as a file.

local Scores = {}

local TOP_N = 5
local KEEP = 100                -- local entries kept on disk
local TIMEOUT = 8               -- seconds to wait for the server
local REPLY = "leaderboard.txt"

local web = false
local pending                   -- seconds waited for a server reply, nil when idle
local localList = {}            -- { name, score, level }, best first

Scores.top = {}                 -- what the game-over screen shows
Scores.rank = nil               -- rank of the score just submitted
Scores.status = "local"         -- local | loading | online | offline

local function parse(line)
  local name, score, level = line:match("^(%u%u%u) (%d+) (%d+)$")
  if name then return { name = name, score = tonumber(score), level = tonumber(level) } end
end

local function readFile(name)
  if not love.filesystem.getInfo(name) then return nil end
  local ok, s = pcall(love.filesystem.read, name)  -- love.js raises on read errors
  return ok and s or nil
end

local function sortList(list)
  table.sort(list, function(a, b) return a.score > b.score end)
end

local function firstN(list)
  local t = {}
  for i = 1, math.min(TOP_N, #list) do t[i] = list[i] end
  return t
end

local function saveLocal()
  local lines = {}
  for i = 1, math.min(KEEP, #localList) do
    local e = localList[i]
    lines[i] = e.name .. " " .. e.score .. " " .. e.level
  end
  love.filesystem.write("scores.txt", table.concat(lines, "\n") .. "\n")
end

local function request(...)
  love.filesystem.remove(REPLY)
  print(table.concat({ "STARDRIFT_API", love.filesystem.getSaveDirectory(), ... }, "|"))
  pending = 0
  Scores.status = "loading"
end

function Scores.load(isWeb)
  web = isWeb
  localList = {}
  for line in (readFile("scores.txt") or ""):gmatch("[^\n]+") do
    localList[#localList + 1] = parse(line)
  end
  sortList(localList)
  Scores.top = firstN(localList)
end

-- last initials entered, so returning players only need to press confirm
function Scores.lastName()
  local s = readFile("initials.txt")
  return s and s:match("^(%u%u%u)") or "AAA"
end

-- the score is always kept locally; online it is also sent to the server
function Scores.submit(name, score, level)
  love.filesystem.write("initials.txt", name)
  local entry = { name = name, score = score, level = level }
  localList[#localList + 1] = entry
  sortList(localList)
  saveLocal()
  Scores.top = firstN(localList)
  Scores.rank = nil
  for i, e in ipairs(localList) do
    if e == entry then Scores.rank = i end
  end
  if web then request("submit", name, score, level) end
end

-- show the table without adding a score (game over with 0 points)
function Scores.refresh()
  Scores.top = firstN(localList)
  Scores.rank = nil
  if web then request("top") end
end

function Scores.update(dt)
  if not pending then return end
  local s = readFile(REPLY)
  if s then
    pending = nil
    love.filesystem.remove(REPLY)
    local rank = s:match("^ok (%d+)")
    if rank then
      local list = {}
      for line in s:gmatch("[^\n]+") do list[#list + 1] = parse(line) end
      Scores.top = list
      Scores.rank = tonumber(rank) > 0 and tonumber(rank) or nil
      Scores.status = "online"
    else
      Scores.status = "offline"
    end
  else
    pending = pending + dt
    if pending > TIMEOUT then
      pending = nil
      Scores.status = "offline"
    end
  end
end

return Scores
