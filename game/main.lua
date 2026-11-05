-- Star Drift: steer a small ship, shoot rocks and enemies, collect stars to clear levels.
-- 1 or 2 players (co-op). Renders to a fixed 640x480 canvas, scaled to fit any screen.
--
-- Controls            Gamepad               Keyboard P1            Keyboard P2
--   move              d-pad / left stick    WASD                   arrows
--   fire (hold)       A or right trigger    Space / F              Right Ctrl / .
--   aim + fire        right stick
--   dash              B or left trigger     Left Shift / G         /
--   super bomb        X                     C                      '
--   super missile     Y                     R                      ;
--   switch gun        L1 / R1               Q / E                  ,
--   start / pause     Start                 Enter
--   music on/off      Y while paused        M
--   back / quit       Select                Esc
--   fullscreen                              F11
-- In 1-player mode every gamepad and both keyboard sets (plus Z / X / Tab) drive P1.
-- The title screen picks EASY / NORMAL / HARD (left/right); each has its own high score table.
-- Every 3rd level is followed by a boss stage.
-- In 2-player mode each gamepad joins by pressing A on the ship select screen (first = P1).
-- Menus also follow the left stick. Unplugging a player's gamepad pauses the game.

local Audio = require("audio")
local Scores = require("scores")

local W, H = 640, 480
local HANDHELD = os.getenv("STARDRIFT_HANDHELD") == "1"
local WEB = love.system.getOS() == "Web"   -- love.js browser build
-- dev only: STARDRIFT_TEST=1 auto-plays 2 players muted, saves screenshot.png to the save folder, then quits
local TEST = os.getenv("STARDRIFT_TEST") == "1"
-- dev only: STARDRIFT_TEST=select drives the ship select screen, saves select.png, then quits
local TEST_SELECT = os.getenv("STARDRIFT_TEST") == "select"
-- dev only: STARDRIFT_TEST=scores ends a game, enters initials, saves scores.png, then quits
local TEST_SCORES = os.getenv("STARDRIFT_TEST") == "scores"
-- dev only: STARDRIFT_TEST=boss fights boss 1 with bomb + missile, saves boss.png, kills it, then quits
local TEST_BOSS = os.getenv("STARDRIFT_TEST") == "boss"
local TESTING = TEST or TEST_SELECT or TEST_SCORES or TEST_BOSS   -- real gamepads are ignored while testing
local AUTOPLAY = TEST or TEST_BOSS                                 -- ships fly and fire on their own
local testTime, testShot, testSpawned = 0, false, false

local canvas, scale, offx, offy
local fontBig, fontSmall, fontTiny
local state = "title"   -- title | select | play | pause | entry | over
local numPlayers, menuSel = 1, 1
-- ship choice per player id (index into SHIPS); kept between games
local picks = { { ship = 1, ready = false }, { ship = 2, ready = false } }
local startDelay  -- short pause after everyone is ready on the select screen
local players, rocks, stars, bullets, particles, bgstars
local enemies, ebullets, pickups, pickupPlan
local boss    -- the boss on boss stages (after every 3rd level), nil otherwise
local flash   -- white screen flash from a super bomb, seconds left
local score, best, level, starsGot, spawnTimer, enemyTimer, levelTime, shake
local banner, bannerText, bannerSub
local pads = {}
local padOwner, playerPad = {}, {}  -- 2-player: joystick -> player id, player id -> joystick
local stickState = {}               -- joystick -> { dir, t } for left-stick menu navigation
local pauseNote                     -- extra line on the pause screen
local rumble                        -- controller vibration, defined in the input section
local dropItem                      -- random item from a destroyed enemy, defined in the pickups section
local entry  -- initials on the entry screen: { letters = { byte, byte, byte }, pos = 1..3 }

-- shot = enemy bullet speed, cool = enemy fire delay, spawn = rock/enemy spawn delay, rock = rock speed,
-- boss = boss health, drop = chance an enemy drops an item
local DIFFICULTIES = {
  { key = "easy",   name = "EASY",   color = { 0.4, 1, 0.5 },  lives = 5, bombs = 2,
    shot = 0.75, cool = 1.4,  spawn = 1.35, rock = 0.85, boss = 0.7, drop = 0.14 },
  { key = "normal", name = "NORMAL", color = { 1, 0.85, 0.3 }, lives = 3, bombs = 1,
    shot = 1,    cool = 1,    spawn = 1,    rock = 1,    boss = 1,   drop = 0.09 },
  { key = "hard",   name = "HARD",   color = { 1, 0.35, 0.35 }, lives = 2, bombs = 0,
    shot = 1.25, cool = 0.75, spawn = 0.75, rock = 1.15, boss = 1.4, drop = 0.06 },
}
local diffSel = 2
local diff = DIFFICULTIES[diffSel]

-- star shape is concave, so pre-split it into triangles once
local starTris
do
  local pts = {}
  for i = 0, 9 do
    local a = i / 10 * math.pi * 2
    local rr = (i % 2 == 0) and 9 or 4
    pts[#pts + 1] = math.cos(a) * rr
    pts[#pts + 1] = math.sin(a) * rr
  end
  starTris = love.math.triangulate(pts)
end

---------------------------------------------------------------- helpers

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end
local function onScreen(o) return o.x > 0 and o.x < W and o.y > 0 and o.y < H end

-- one best score per difficulty; NORMAL keeps the original best.txt
local function bestFile() return diff.key == "normal" and "best.txt" or ("best-" .. diff.key .. ".txt") end

-- love.js raises an error for a missing file instead of returning nil
local function readSave(name)
  if not love.filesystem.getInfo(name) then return nil end
  local ok, s = pcall(love.filesystem.read, name)
  return ok and s or nil
end

local function loadBest() return tonumber(readSave(bestFile())) or 0 end
local function saveBest() love.filesystem.write(bestFile(), tostring(best)) end

local function setDifficulty(i)
  diffSel = (i - 1) % #DIFFICULTIES + 1
  diff = DIFFICULTIES[diffSel]
  best = loadBest()
end

local function burst(x, y, color, n, speed)
  for _ = 1, n do
    local a = love.math.random() * math.pi * 2
    local s = speed * (0.3 + love.math.random() * 0.7)
    particles[#particles + 1] = {
      x = x, y = y, vx = math.cos(a) * s, vy = math.sin(a) * s,
      life = 0.4 + love.math.random() * 0.4, color = color,
    }
  end
end

-- a random point just outside one of the screen edges
local function edgePoint()
  local side = love.math.random(4)
  if side == 1 then return -30, love.math.random(H)
  elseif side == 2 then return W + 30, love.math.random(H)
  elseif side == 3 then return love.math.random(W), -30
  else return love.math.random(W), H + 30 end
end

-- move inside the play area, bouncing off the edges
local function drift(o, dt, margin)
  o.x, o.y = o.x + o.vx * dt, o.y + o.vy * dt
  if o.x < margin or o.x > W - margin then o.vx = -o.vx; o.x = clamp(o.x, margin, W - margin) end
  if o.y < margin + 30 or o.y > H - margin then o.vy = -o.vy; o.y = clamp(o.y, margin + 30, H - margin) end
end

-- The canvas keeps 640x480 logical units but is rendered with dpiscale = k, so shapes and
-- text are drawn at (roughly) the real screen resolution and stay sharp at any window size.
local renderScale
local function resize(w, h)
  scale = math.min(w / W, h / H)
  local k = HANDHELD and 1 or math.max(1, math.ceil(scale))  -- keep the handheld GPU at 1x
  if k ~= renderScale then
    renderScale = k
    canvas = love.graphics.newCanvas(W, H, { dpiscale = k })
    canvas:setFilter("linear", "linear")
    fontBig = love.graphics.newFont(36, "normal", k)
    fontSmall = love.graphics.newFont(16, "normal", k)
    fontTiny = love.graphics.newFont(11, "normal", k)
  end
  offx = math.floor((w - W * scale) / 2)
  offy = math.floor((h - H * scale) / 2)
end

---------------------------------------------------------------- players

local function alivePlayers()
  local list = {}
  for _, p in ipairs(players) do
    if p.alive then list[#list + 1] = p end
  end
  return list
end

local function nearestPlayer(o)
  local best_, bestD = nil, math.huge
  for _, p in ipairs(players) do
    if p.alive then
      local d = dist2(p, o)
      if d < bestD then best_, bestD = p, d end
    end
  end
  return best_ or players[1]
end

-- dashing and post-hit blinking let things pass straight through
local function vulnerable(p) return p.alive and p.dash <= 0 and p.hurt <= 0 end

local function newPlayer(id)
  local x = numPlayers == 1 and W / 2 or (id == 1 and W / 2 - 50 or W / 2 + 50)
  return { id = id, ship = picks[id].ship, x = x, y = H / 2 + 40, vx = 0, vy = 0, r = 9, angle = -math.pi / 2,
           dash = 0, dashCd = 0, cool = 0, gun = 1, lives = diff.lives, hurt = 0, shield = 0,
           bombs = diff.bombs, missiles = 0,
           thrust = 0, alive = true }
end

---------------------------------------------------------------- guns

local function bullet(p, angle, speed, dmg, color, homing)
  bullets[#bullets + 1] = {
    x = p.x + math.cos(p.angle) * 12, y = p.y + math.sin(p.angle) * 12,
    vx = math.cos(angle) * speed, vy = math.sin(angle) * speed,
    life = 1.4, dmg = dmg, color = color, homing = homing, owner = p,
  }
end

-- Each gun unlocks on the level matching its index
local GUNS = {
  { name = "BLASTER", rate = 0.18, color = { 0.5, 0.9, 1 }, sfx = "blaster",
    fire = function(p, a, c) bullet(p, a, 460, 1, c) end },
  { name = "SPREAD", rate = 0.32, color = { 0.6, 1, 0.5 }, sfx = "spread",
    fire = function(p, a, c) for i = -2, 2 do bullet(p, a + i * 0.16, 400, 1, c) end end },
  { name = "RAPID", rate = 0.06, color = { 1, 0.95, 0.4 }, sfx = "rapid",
    fire = function(p, a, c) bullet(p, a + (love.math.random() - 0.5) * 0.18, 520, 0.5, c) end },
  { name = "HOMING", rate = 0.4, color = { 1, 0.45, 0.8 }, sfx = "homing",
    fire = function(p, a, c) bullet(p, a - 0.5, 260, 2, c, true); bullet(p, a + 0.5, 260, 2, c, true) end },
}

local function unlockedGuns() return math.min(#GUNS, level) end

local function switchGun(p, dir)
  local n = unlockedGuns()
  p.gun = (p.gun - 1 + dir) % n + 1
end

-- homing missiles chase whatever rock, enemy or boss is closest
local function nearestTarget(b)
  local best_, bestD = nil, math.huge
  if boss and not boss.dying then best_, bestD = boss, dist2(boss, b) end
  for _, list in ipairs({ rocks, enemies }) do
    for _, o in ipairs(list) do
      local d = dist2(o, b)
      if d < bestD then best_, bestD = o, d end
    end
  end
  return best_
end

---------------------------------------------------------------- enemies

local ENEMY_COLOR = { 1, 0.3, 0.4 }

-- lvl = first level the enemy type appears on
local ENEMIES = {
  drone   = { lvl = 2, r = 11, hp = 3, pts = 30, color = { 1, 0.35, 0.35 } },
  spinner = { lvl = 4, r = 14, hp = 6, pts = 50, color = { 1, 0.6, 0.2 } },
  hunter  = { lvl = 6, r = 10, hp = 4, pts = 60, color = { 0.8, 0.45, 1 } },
}
local ENEMY_ORDER = { "drone", "spinner", "hunter" }

local function enemyShot(e, angle, speed)
  speed = speed * diff.shot
  ebullets[#ebullets + 1] = { x = e.x, y = e.y, vx = math.cos(angle) * speed, vy = math.sin(angle) * speed, life = 4 }
end

local function aimAt(e)
  local p = nearestPlayer(e)
  return math.atan2(p.y - e.y, p.x - e.x)
end

local function spawnEnemy(kind)
  if not kind then
    local avail = {}
    for _, k in ipairs(ENEMY_ORDER) do
      if ENEMIES[k].lvl <= level then avail[#avail + 1] = k end
    end
    kind = avail[love.math.random(#avail)]
  end
  local def = ENEMIES[kind]
  local e = { kind = kind, r = def.r, hp = def.hp, t = 0, flash = 0, vx = 0, vy = 0 }
  if kind == "hunter" then
    e.dir = love.math.random() < 0.5 and 1 or -1
    e.x = e.dir == 1 and -20 or W + 20
    e.baseY = love.math.random(90, H - 90)
    e.y = e.baseY
    e.cool = 1
  else
    e.x, e.y = edgePoint()
    e.cool = 1.5 + love.math.random()
    if kind == "spinner" then
      e.tx, e.ty = love.math.random(80, W - 80), love.math.random(90, H - 80)
    end
  end
  enemies[#enemies + 1] = e
end

-- by = the player who made the kill, if any
local function killEnemy(i, by)
  local e = enemies[i]
  table.remove(enemies, i)
  burst(e.x, e.y, ENEMIES[e.kind].color, 28, 200)
  score = score + ENEMIES[e.kind].pts
  shake = math.max(shake, 0.15)
  Audio.play("boom")
  if by then
    rumble(by, 0.35, 0.12)
    if love.math.random() < diff.drop then dropItem(e.x, e.y) end
  end
end

local function updateEnemy(e, dt)
  e.t = e.t + dt
  e.flash = math.max(0, e.flash - dt)
  if e.kind == "drone" then
    -- lazily steer toward the nearest player
    local a = aimAt(e)
    local sp = 55 + level * 4
    e.vx = e.vx + (math.cos(a) * sp - e.vx) * dt * 1.5
    e.vy = e.vy + (math.sin(a) * sp - e.vy) * dt * 1.5
    e.x, e.y = e.x + e.vx * dt, e.y + e.vy * dt
  elseif e.kind == "spinner" then
    -- glide to a spot, hover, pick a new spot every few seconds
    e.x = e.x + (e.tx - e.x) * dt * 1.2
    e.y = e.y + (e.ty - e.y) * dt * 1.2
    if e.t % 10 < dt then e.tx, e.ty = love.math.random(80, W - 80), love.math.random(90, H - 80) end
  elseif e.kind == "hunter" then
    e.x = e.x + e.dir * 130 * dt
    e.y = e.baseY + math.sin(e.t * 3) * 60
  end

  if onScreen(e) then
    e.cool = e.cool - dt
    if e.cool <= 0 then
      if e.kind == "drone" then
        enemyShot(e, aimAt(e), 150)
        e.cool = 2.2 - math.min(1, level * 0.08)
      elseif e.kind == "spinner" then
        for k = 0, 7 do enemyShot(e, e.t + k * math.pi / 4, 110) end
        e.cool = 2.6
      elseif e.kind == "hunter" then
        local a = aimAt(e)
        for k = -1, 1 do enemyShot(e, a + k * 0.2, 170) end
        e.cool = 1.4
      end
      e.cool = e.cool * diff.cool
      Audio.play("enemyShot")
    end
  end
end

---------------------------------------------------------------- input

local KEYS = {
  { up = { "w" }, down = { "s" }, left = { "a" }, right = { "d" },
    fire = { "space", "f" }, dash = { "lshift", "g" }, prev = { "q" }, next = { "e" },
    bomb = { "c" }, missile = { "r" } },
  { up = { "up" }, down = { "down" }, left = { "left" }, right = { "right" },
    fire = { "rctrl", "." }, dash = { "/", "ralt" }, next = { "," }, bomb = { "'" }, missile = { ";" } },
  -- extra keys that only apply in 1-player mode
  solo = { fire = { "z" }, dash = { "x" }, next = { "tab" } },
}

local function keysetsFor(p)
  if numPlayers == 1 then return { KEYS[1], KEYS[2], KEYS.solo } end
  return { KEYS[p.id] }
end

local function padsFor(p)
  if numPlayers == 1 then return pads end
  return { playerPad[p.id] }
end

-- strongest value of a gamepad axis across a list of pads
local function padAxis(list, name)
  local v = 0
  for _, j in ipairs(list) do
    if j:isGamepad() then
      local a = j:getGamepadAxis(name)
      if math.abs(a) > math.abs(v) then v = a end
    end
  end
  return v
end

function rumble(p, strength, dur)
  for _, j in ipairs(padsFor(p)) do
    if j:isVibrationSupported() then j:setVibration(strength, strength, dur) end
  end
end

local function stopRumble()
  for _, j in ipairs(pads) do j:setVibration() end
end

-- which player a pad drives; in 2-player mode an unclaimed pad joins the first free slot.
-- Returns nil for a pad with no free slot, and joined = true on the press that claimed one.
local function padPlayer(j)
  if numPlayers == 1 or state == "title" then return 1 end
  if padOwner[j] then return padOwner[j] end
  for id = 1, numPlayers do
    if not playerPad[id] then
      padOwner[j], playerPad[id] = id, j
      return id, true
    end
  end
end

-- right stick direction for twin-stick aiming, or nil when centred
local function aimAxis(p)
  if AUTOPLAY then return nil end
  local list = padsFor(p)
  local x, y = padAxis(list, "rightx"), padAxis(list, "righty")
  if x * x + y * y < 0.35 ^ 2 then return nil end
  return x, y
end

local function keyDown(sets, field)
  for _, set in ipairs(sets) do
    if set[field] then
      for _, k in ipairs(set[field]) do
        if love.keyboard.isDown(k) then return true end
      end
    end
  end
  return false
end

local function padDown(list, button)
  for _, j in ipairs(list) do
    if j:isGamepad() and j:isGamepadDown(button) then return true end
  end
  return false
end

local function axis(p)
  local dx, dy = 0, 0
  local sets, list = keysetsFor(p), padsFor(p)
  if keyDown(sets, "left") or padDown(list, "dpleft") then dx = dx - 1 end
  if keyDown(sets, "right") or padDown(list, "dpright") then dx = dx + 1 end
  if keyDown(sets, "up") or padDown(list, "dpup") then dy = dy - 1 end
  if keyDown(sets, "down") or padDown(list, "dpdown") then dy = dy + 1 end
  for _, j in ipairs(list) do
    if j:isGamepad() then
      local sx, sy = j:getGamepadAxis("leftx"), j:getGamepadAxis("lefty")
      if math.abs(sx) > 0.25 then dx = dx + sx end
      if math.abs(sy) > 0.25 then dy = dy + sy end
    end
  end
  if AUTOPLAY then dx, dy = math.cos(testTime * 1.3 + p.id * 2), math.sin(testTime * (0.7 + p.id * 0.2)) end
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 1 then dx, dy = dx / len, dy / len end
  return dx, dy
end

local function fireHeld(p)
  if AUTOPLAY then return true end
  local list = padsFor(p)
  return keyDown(keysetsFor(p), "fire") or padDown(list, "a") or padAxis(list, "triggerright") > 0.4
end

---------------------------------------------------------------- pickups

-- life: +1 life   shield: 8 s bubble   missile: +2 super missiles   bomb: +1 super bomb
local PICKUP_COLORS = {
  life = { 1, 0.4, 0.6 }, shield = { 0.4, 0.9, 1 }, missile = { 1, 0.6, 0.2 }, bomb = { 1, 0.3, 0.25 },
}

-- appears at x, y (or a random spot) and drifts around for 7 seconds
local function spawnPickup(kind, x, y)
  local a = love.math.random() * math.pi * 2
  pickups[#pickups + 1] = {
    kind = kind, x = clamp(x or love.math.random(60, W - 60), 30, W - 30),
    y = clamp(y or love.math.random(90, H - 60), 60, H - 30),
    vx = math.cos(a) * 70, vy = math.sin(a) * 70, t = 7,
  }
  Audio.play("appear", 0)
end

-- weighted: missiles most often, lives least
function dropItem(x, y)
  local r = love.math.random(100)
  local kind = r <= 40 and "missile" or r <= 60 and "bomb" or r <= 85 and "shield" or "life"
  spawnPickup(kind, x, y)
end

local function collectPickup(pk, p)
  if pk.kind == "life" then
    p.lives = math.min(5, p.lives + 1)
  elseif pk.kind == "shield" then
    p.shield = 8
  elseif pk.kind == "missile" then
    p.missiles = math.min(9, p.missiles + 2)
  else
    p.bombs = math.min(3, p.bombs + 1)
  end
  burst(pk.x, pk.y, PICKUP_COLORS[pk.kind], 20, 150)
  Audio.play("pickup", 0)
  rumble(p, 0.3, 0.15)
end

---------------------------------------------------------------- game

local function starsNeeded() return 3 + level * 2 + (numPlayers - 1) * 2 end

-- from level 5 on, stars drift around and get quicker each level
local function placeStar(s)
  s.x, s.y = love.math.random(30, W - 30), love.math.random(60, H - 30)
  s.vx, s.vy = 0, 0
  if level >= 5 then
    local a = love.math.random() * math.pi * 2
    local sp = math.min(110, 30 + (level - 5) * 10)
    s.vx, s.vy = math.cos(a) * sp, math.sin(a) * sp
  end
end

local LEVEL_NEWS = {
  [1] = "X: SUPER BOMB    Y: SUPER MISSILE",
  [2] = "DRONES SHOOT BACK!\nGRAB SHIELDS AND MISSILES WHEN THEY APPEAR",
  [3] = "A BOSS WAITS AT THE END OF THIS LEVEL",
  [4] = "NEW ENEMY: SPINNERS",
  [5] = "STARS ARE ON THE MOVE\nEXTRA LIVES ON ODD LEVELS - BE QUICK",
  [6] = "NEW ENEMY: HUNTERS",
}

local function startLevel(n)
  level = n
  starsGot, levelTime = 0, 0
  rocks, bullets, enemies, ebullets = {}, {}, {}, {}  -- pickups stay, so boss drops survive
  boss = nil
  spawnTimer, enemyTimer = 1.5, 4
  banner = 2.5
  bannerText = "LEVEL " .. n
  local sub = {}
  if n > 1 and n <= #GUNS then
    for _, p in ipairs(players) do p.gun = n end
    sub[#sub + 1] = "NEW GUN: " .. GUNS[n].name
  end
  -- a downed co-op partner rejoins with one life
  for _, p in ipairs(players) do
    if not p.alive then
      p.alive, p.lives, p.hurt = true, 1, 2
      p.x, p.y, p.vx, p.vy = W / 2, H / 2, 0, 0
      sub[#sub + 1] = "P" .. p.id .. " IS BACK!"
    end
  end
  if LEVEL_NEWS[n] then sub[#sub + 1] = LEVEL_NEWS[n] end
  bannerSub = table.concat(sub, "\n")

  -- each shows up once at a random time: shields and missiles from level 2, bombs on even levels
  -- from 4, extra lives on odd levels from 5 (from 3 on EASY). Enemies also drop items now and then.
  pickupPlan = {}
  local function plan(kind) pickupPlan[#pickupPlan + 1] = { kind = kind, at = love.math.random(6, 20) } end
  if n >= 2 then plan("shield"); plan("missile") end
  if n >= 4 and n % 2 == 0 then plan("bomb") end
  if n >= (diff.key == "easy" and 3 or 5) and n % 2 == 1 then plan("life") end

  for _, s in ipairs(stars) do placeStar(s) end
  if n > 1 then
    Audio.play("levelup", 0)
    for _, p in ipairs(players) do rumble(p, 0.4, 0.25) end
  end
end

local function newGame()
  players = {}
  for i = 1, numPlayers do players[i] = newPlayer(i) end
  stars, particles = {}, {}
  score, shake, level, flash = 0, 0, 1, 0
  pickups, boss = {}, nil
  for _ = 1, 3 do stars[#stars + 1] = { t = love.math.random() * 6 } end
  startLevel(1)
end

local function makeRock(x, y, r, vx, vy)
  local pts = {}
  for i = 1, 8 do
    local ang = i / 8 * math.pi * 2
    local rr = r * (0.75 + love.math.random() * 0.35)
    pts[#pts + 1] = math.cos(ang) * rr
    pts[#pts + 1] = math.sin(ang) * rr
  end
  rocks[#rocks + 1] = { x = x, y = y, vx = vx, vy = vy, r = r, hp = math.ceil(r / 8), flash = 0,
                        rot = 0, spin = (love.math.random() - 0.5) * 3, pts = pts }
end

local function spawnRock()
  -- enter from a random edge, aimed roughly at a random living player
  local x, y = edgePoint()
  local alive = alivePlayers()
  local p = alive[love.math.random(#alive)]
  local a = math.atan2(p.y - y, p.x - x) + (love.math.random() - 0.5) * 0.8
  local speed = (60 + level * 15 + love.math.random() * 50) * diff.rock
  makeRock(x, y, love.math.random(10, 24), math.cos(a) * speed, math.sin(a) * speed)
end

local function destroyRock(i)
  local r = rocks[i]
  table.remove(rocks, i)
  burst(r.x, r.y, { 0.7, 0.65, 0.75 }, 14, 150)
  score = score + 5
  Audio.play("boomSmall")
  if r.r >= 16 then
    -- big rocks split into two smaller ones flying apart
    local a = math.atan2(r.vy, r.vx)
    local sp = math.sqrt(r.vx * r.vx + r.vy * r.vy) * 1.2
    for _, off in ipairs({ -0.7, 0.7 }) do
      makeRock(r.x, r.y, r.r * 0.6, math.cos(a + off) * sp, math.sin(a + off) * sp)
    end
  end
end

local function tryDash(p)
  if p.alive and p.dashCd <= 0 then
    p.dash = 0.15
    p.dashCd = 0.8
    burst(p.x, p.y, { 0.5, 0.8, 1 }, 12, 120)
    Audio.play("dash")
    rumble(p, 0.25, 0.08)
  end
end

-- ask for initials when there is a score to keep, otherwise straight to the score table
local function gameOver()
  if score > best then best = score; saveBest() end
  Audio.play("gameover", 0)
  if score > 0 then
    entry = { letters = { Scores.lastName():byte(1, 3) }, pos = 1 }
    state = "entry"
  else
    Scores.refresh(diff.key)
    state = "over"
  end
end

local function submitEntry()
  Scores.submit(string.char(unpack(entry.letters)), score, level, diff.key)
  state = "over"
end

local function damagePlayer(p)
  if p.shield > 0 then
    burst(p.x, p.y, { 0.4, 0.9, 1 }, 10, 120)
    Audio.play("deflect")
    rumble(p, 0.2, 0.08)
    return
  end
  burst(p.x, p.y, { 1, 0.5, 0.3 }, 40, 220)
  shake = 0.4
  p.lives = p.lives - 1
  p.hurt = 2
  Audio.play("hurt", 0)
  rumble(p, 0.7, 0.3)
  if p.lives <= 0 then
    p.alive = false
    rumble(p, 1, 0.6)
    burst(p.x, p.y, { 1, 0.8, 0.4 }, 60, 260)
    if #alivePlayers() == 0 then gameOver() end
  end
end

local function updatePlayer(p, dt)
  if not p.alive then return end
  local dx, dy = axis(p)
  local accel = p.dash > 0 and 2600 or 900
  p.vx = p.vx + dx * accel * dt
  p.vy = p.vy + dy * accel * dt
  local damp = math.exp(-4 * dt)
  p.vx, p.vy = p.vx * damp, p.vy * damp
  p.x = clamp(p.x + p.vx * dt, p.r, W - p.r)
  p.y = clamp(p.y + p.vy * dt, p.r, H - p.r)
  -- the right stick aims (and fires); otherwise the ship faces where it moves
  local ax, ay = aimAxis(p)
  if ax then p.angle = math.atan2(ay, ax)
  elseif dx ~= 0 or dy ~= 0 then p.angle = math.atan2(dy, dx) end
  p.thrust = math.sqrt(dx * dx + dy * dy)
  p.dash = math.max(0, p.dash - dt)
  p.dashCd = math.max(0, p.dashCd - dt)
  p.hurt = math.max(0, p.hurt - dt)
  p.cool = math.max(0, p.cool - dt)
  p.shield = math.max(0, p.shield - dt)

  -- left trigger dashes on each pull
  local lt = padAxis(padsFor(p), "triggerleft") > 0.5
  if lt and not p.ltHeld then tryDash(p) end
  p.ltHeld = lt

  if (ax or fireHeld(p)) and p.cool <= 0 then
    local g = GUNS[p.gun]
    g.fire(p, p.angle, g.color)
    p.cool = g.rate
    Audio.play(g.sfx)
  end
end

---------------------------------------------------------------- boss
-- After every 3rd level a boss flies in. It sways along the top and cycles through attacks:
-- an aimed fan, a ring, a spiral stream and (from boss 2) summoning drones. Below half health it
-- gets angry: faster and shorter pauses. Beating it moves on to the next level.

local BOSS_COLORS = { { 0.9, 0.3, 0.5 }, { 1, 0.55, 0.15 }, { 0.55, 0.4, 1 } }

local function startBoss()
  local tier = math.floor(level / 3)
  local hp = (100 + 80 * tier) * diff.boss * (1 + 0.5 * (numPlayers - 1))
  boss = { x = W / 2, y = -60, r = 38, hp = hp, maxHp = hp, tier = tier, t = 0, flash = 0,
           cool = 1.5, attack = 0, color = BOSS_COLORS[(tier - 1) % #BOSS_COLORS + 1] }
  rocks, bullets, enemies, ebullets = {}, {}, {}, {}
  banner, bannerText, bannerSub = 2.5, "WARNING", "BOSS " .. tier .. " APPROACHING"
  levelTime = 0
  pickupPlan = { { kind = "missile", at = 8 }, { kind = "shield", at = 18 } }
  Audio.play("alarm", 0)
end

local function hitBoss(dmg, by)
  local b = boss
  b.hp = b.hp - dmg
  b.flash = 0.06
  if b.hp > 0 then return end
  -- defeated: explode for a while, leave a life and a bomb behind, then on to the next level
  b.hp, b.dying = 0, 2.2
  ebullets = {}
  score = score + 1000 * b.tier
  shake = 0.8
  burst(b.x, b.y, b.color, 80, 320)
  Audio.play("bomb", 0)
  spawnPickup("life", b.x - 30, b.y + 40)
  spawnPickup("bomb", b.x + 30, b.y + 40)
  for _, p in ipairs(players) do rumble(p, 1, 0.8) end
end

local function bossAttack(b, enraged)
  local avail = { "fan", "ring", "spiral" }
  if b.tier >= 2 and #enemies < 4 then avail[#avail + 1] = "summon" end
  b.attack = b.attack % #avail + 1
  local kind = avail[b.attack]
  if kind == "fan" then
    local a, n = aimAt(b), 4 + b.tier
    for k = 0, n - 1 do enemyShot(b, a + (k - (n - 1) / 2) * 0.17, 170) end
  elseif kind == "ring" then
    local n = 12 + 4 * b.tier
    for k = 0, n - 1 do enemyShot(b, b.t + k * math.pi * 2 / n, 120) end
  elseif kind == "spiral" then
    b.spiral, b.shotT = enraged and 3 or 2.2, 0
  else
    for _, dx in ipairs({ -45, 45 }) do
      spawnEnemy("drone")
      local e = enemies[#enemies]
      e.x, e.y = b.x + dx, b.y + 30
    end
  end
  Audio.play("enemyShot")
end

local function updateBoss(dt)
  local b = boss
  b.t = b.t + dt
  b.flash = math.max(0, b.flash - dt)
  if b.dying then
    b.dying = b.dying - dt
    if love.math.random() < 0.3 then
      burst(b.x + love.math.random(-45, 45), b.y + love.math.random(-30, 30), b.color, 14, 180)
      Audio.play("boomSmall")
    end
    if b.dying <= 0 then
      score = score + 100 * level
      startLevel(level + 1)
    end
    return
  end
  -- fly in from the top, then sway side to side
  if b.y < 110 then b.y = b.y + 70 * dt; return end
  local enraged = b.hp < b.maxHp / 2
  b.x = W / 2 + math.sin(b.t * (enraged and 0.9 or 0.6)) * 200
  b.y = 110 + math.sin(b.t * 1.3) * 20
  if b.spiral then
    b.spiral = b.spiral - dt
    b.shotT = b.shotT - dt
    if b.shotT <= 0 then
      b.shotT = 0.08
      local arms = b.tier >= 3 and 3 or 2
      for k = 0, arms - 1 do enemyShot(b, b.t * 4 + k * math.pi * 2 / arms, 140) end
    end
    if b.spiral <= 0 then b.spiral = nil end
  else
    b.cool = b.cool - dt
    if b.cool <= 0 then
      bossAttack(b, enraged)
      b.cool = (enraged and 1.3 or 2) * diff.cool
    end
  end
end

---------------------------------------------------------------- specials

local function fireMissile(p)
  if not p.alive then return end
  if p.missiles <= 0 then Audio.play("deflect", 0); return end
  p.missiles = p.missiles - 1
  bullets[#bullets + 1] = {
    x = p.x + math.cos(p.angle) * 12, y = p.y + math.sin(p.angle) * 12,
    vx = math.cos(p.angle) * 280, vy = math.sin(p.angle) * 280,
    life = 3, dmg = 30, color = { 1, 0.6, 0.2 }, homing = true, super = true, owner = p,
  }
  Audio.play("missile", 0)
  rumble(p, 0.3, 0.1)
end

-- wipes out every rock, enemy and enemy bullet on screen and takes a chunk off a boss
local function superBomb(p)
  if not p.alive then return end
  if p.bombs <= 0 then Audio.play("deflect", 0); return end
  p.bombs = p.bombs - 1
  flash, shake = 0.5, 0.6
  for _, r in ipairs(rocks) do
    burst(r.x, r.y, { 0.7, 0.65, 0.75 }, 10, 150)
    score = score + 5
  end
  rocks = {}
  for j = #enemies, 1, -1 do killEnemy(j, p) end
  for _, b in ipairs(ebullets) do burst(b.x, b.y, { 1, 0.3, 0.4 }, 3, 60) end
  ebullets = {}
  if boss and not boss.dying then hitBoss(boss.maxHp * 0.15, p) end
  Audio.play("bomb", 0)
  rumble(p, 1, 0.5)
end

-- a super missile blows up everything near where it hits
local function explode(b)
  burst(b.x, b.y, { 1, 0.6, 0.2 }, 50, 260)
  burst(b.x, b.y, { 1, 1, 0.6 }, 20, 120)
  shake = math.max(shake, 0.35)
  Audio.play("boom")
  local r2 = 90 * 90
  for j = #rocks, 1, -1 do
    if dist2(rocks[j], b) < r2 then destroyRock(j) end
  end
  for j = #enemies, 1, -1 do
    local e = enemies[j]
    if dist2(e, b) < r2 then
      e.hp = e.hp - 10
      e.flash = 0.08
      if e.hp <= 0 then killEnemy(j, b.owner) end
    end
  end
end

-- returns true if the bullet hit something
local function bulletHits(b)
  local hit = false
  if boss and not boss.dying and dist2(boss, b) < boss.r * boss.r then
    hitBoss(b.dmg, b.owner)
    hit = true
  end
  for j = #rocks, 1, -1 do
    if hit then break end
    local r = rocks[j]
    if dist2(r, b) < r.r * r.r then
      r.hp = r.hp - b.dmg
      r.flash = 0.08
      if r.hp <= 0 then destroyRock(j) end
      hit = true
    end
  end
  for j = #enemies, 1, -1 do
    if hit then break end
    local e = enemies[j]
    if dist2(e, b) < (e.r + 2) ^ 2 then
      e.hp = e.hp - b.dmg
      e.flash = 0.08
      if e.hp <= 0 then killEnemy(j, b.owner) end
      hit = true
    end
  end
  if hit and b.super then explode(b) end
  return hit
end

local function updateBullets(dt)
  for i = #bullets, 1, -1 do
    local b = bullets[i]
    if b.homing then
      local t = nearestTarget(b)
      if t then
        -- steer toward the target at a capped turn rate
        local cur = math.atan2(b.vy, b.vx)
        local want = math.atan2(t.y - b.y, t.x - b.x)
        local diff = (want - cur + math.pi) % (math.pi * 2) - math.pi
        local a = cur + clamp(diff, -5 * dt, 5 * dt)
        local sp = math.sqrt(b.vx * b.vx + b.vy * b.vy)
        b.vx, b.vy = math.cos(a) * sp, math.sin(a) * sp
      end
    end
    b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
    b.life = b.life - dt
    local dead = b.life <= 0 or b.x < -10 or b.x > W + 10 or b.y < -10 or b.y > H + 10
    if dead or bulletHits(b) then table.remove(bullets, i) end
  end

  for i = #ebullets, 1, -1 do
    local b = ebullets[i]
    b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
    b.life = b.life - dt
    if b.life <= 0 or b.x < -10 or b.x > W + 10 or b.y < -10 or b.y > H + 10 then
      table.remove(ebullets, i)
    else
      for _, p in ipairs(players) do
        if vulnerable(p) and dist2(b, p) < (p.r * 0.8 + 3) ^ 2 then
          table.remove(ebullets, i)
          damagePlayer(p)
          break
        end
      end
      if state ~= "play" then return end
    end
  end
end

local function levelComplete()
  for j = #rocks, 1, -1 do destroyRock(j) end      -- startLevel clears the leftover fragments
  for j = #enemies, 1, -1 do killEnemy(j) end
  score = score + 100 * level
  if level % 3 == 0 then startBoss() else startLevel(level + 1) end
end

-- first living, vulnerable player touching o (within extra radius), or nil
local function touchingPlayer(o, radius)
  for _, p in ipairs(players) do
    if vulnerable(p) and dist2(o, p) < (radius + p.r) ^ 2 then return p end
  end
end

local function updatePlay(dt)
  levelTime = levelTime + dt
  for _, p in ipairs(players) do updatePlayer(p, dt) end
  updateBullets(dt)
  if state ~= "play" then return end

  flash = math.max(0, flash - dt)
  if boss then
    updateBoss(dt)
    if not boss then return end  -- beaten: the next level has started
    local p = not boss.dying and touchingPlayer(boss, boss.r * 0.8)
    if p then
      damagePlayer(p)
      if state ~= "play" then return end
    end
  end

  -- no spawns while the banner shows or during a boss fight; spawns speed up each level
  if banner > 0 then
    banner = banner - dt
  elseif not boss then
    spawnTimer = spawnTimer - dt
    if spawnTimer <= 0 then
      spawnRock()
      spawnTimer = math.max(0.3, 1.3 - level * 0.12) * (0.7 + love.math.random() * 0.6) / (1 + (numPlayers - 1) * 0.3)
                   * diff.spawn
    end
    if level >= 2 then
      enemyTimer = enemyTimer - dt
      if enemyTimer <= 0 then
        if #enemies < math.min(numPlayers + math.floor(level / 2), 7) then spawnEnemy() end
        enemyTimer = math.max(2.5, 8 - level * 0.5) * (0.7 + love.math.random() * 0.6) * diff.spawn
      end
    end
  end

  for i = #pickupPlan, 1, -1 do
    if levelTime >= pickupPlan[i].at then
      spawnPickup(pickupPlan[i].kind)
      table.remove(pickupPlan, i)
    end
  end

  for i = #pickups, 1, -1 do
    local pk = pickups[i]
    drift(pk, dt, 20)
    pk.t = pk.t - dt
    local p
    for _, q in ipairs(players) do
      if q.alive and dist2(pk, q) < (q.r + 12) ^ 2 then p = q; break end
    end
    if p then
      collectPickup(pk, p)
      table.remove(pickups, i)
    elseif pk.t <= 0 then
      table.remove(pickups, i)
    end
  end

  for i = #rocks, 1, -1 do
    local r = rocks[i]
    r.x, r.y = r.x + r.vx * dt, r.y + r.vy * dt
    r.rot = r.rot + r.spin * dt
    r.flash = math.max(0, r.flash - dt)
    if r.x < -60 or r.x > W + 60 or r.y < -60 or r.y > H + 60 then
      table.remove(rocks, i)
    else
      local p = touchingPlayer(r, r.r * 0.85)
      if p then
        destroyRock(i)
        damagePlayer(p)
        if state ~= "play" then return end
      end
    end
  end

  for i = #enemies, 1, -1 do
    local e = enemies[i]
    updateEnemy(e, dt)
    if e.kind == "hunter" and e.t > 2 and (e.x < -40 or e.x > W + 40) then
      table.remove(enemies, i)
    else
      local p = touchingPlayer(e, e.r)
      if p then
        e.hp = e.hp - 3
        e.flash = 0.08
        if e.hp <= 0 then killEnemy(i, p) end
        damagePlayer(p)
        if state ~= "play" then return end
      end
    end
  end

  if boss then return end  -- no stars to collect during a boss fight
  for _, s in ipairs(stars) do
    s.t = s.t + dt
    if s.vx ~= 0 or s.vy ~= 0 then drift(s, dt, 20) end
    for _, p in ipairs(players) do
      if p.alive and dist2(s, p) < (p.r + 10) ^ 2 then
        score = score + 25
        starsGot = starsGot + 1
        burst(s.x, s.y, { 1, 0.9, 0.3 }, 16, 140)
        Audio.play("star", 0)
        placeStar(s)
        if starsGot >= starsNeeded() then
          levelComplete()
          return
        end
        break
      end
    end
  end
end

local function updateParticles(dt)
  for i = #particles, 1, -1 do
    local p = particles[i]
    p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
    p.life = p.life - dt
    if p.life <= 0 then table.remove(particles, i) end
  end
  for _, b in ipairs(bgstars) do
    b.y = b.y + b.speed * dt
    if b.y > H then b.y, b.x = 0, love.math.random(W) end
  end
  shake = math.max(0, shake - dt)
end

---------------------------------------------------------------- ship art
-- Ships are drawn nose-along-+x. All fill polygons are convex. Players pick one on the select screen.

local SHIPS = {
  -- "Falcon": sleek white/cyan arrow, swept wings, single blue engine
  {
    name = "FALCON", desc = "Sleek interceptor", tint = { 0.4, 0.85, 1 },
    parts = {
      { color = { 0.15, 0.55, 1 }, pts = { 2, -3, -8, -12, -11, -11, -6, -3 } },
      { color = { 0.15, 0.55, 1 }, pts = { 2, 3, -6, 3, -11, 11, -8, 12 } },
      { color = { 0.9, 0.97, 1 }, pts = { 14, 0, 4, -4, -6, -5, -10, -2, -10, 2, -6, 5, 4, 4 } },
    },
    cockpit = { x = 3, y = 0, rx = 3.5, ry = 2, color = { 0.05, 0.25, 0.6 } },
    engines = { { x = -10, y = 0, w = 2.5 } },
    flame = { { 0.3, 0.8, 1 }, { 0.9, 1, 1 } },
  },
  -- "Phoenix": orange arrow with wide crimson delta wings, gold stripes, twin tail fins and engines
  {
    name = "PHOENIX", desc = "Delta-wing striker", tint = { 1, 0.55, 0.2 },
    parts = {
      { color = { 0.5, 0.08, 0.1 }, pts = { -5, -3, -14, -9, -12, -3 } },
      { color = { 0.5, 0.08, 0.1 }, pts = { -5, 3, -12, 3, -14, 9 } },
      { color = { 0.85, 0.15, 0.2 }, pts = { 8, -2, -10, -14, -12, -12, -10, -2 } },
      { color = { 0.85, 0.15, 0.2 }, pts = { 8, 2, -10, 2, -12, 12, -10, 14 } },
      { color = { 1, 0.85, 0.3 }, pts = { 0, -4, -6, -9, -8, -9, -2, -4 } },
      { color = { 1, 0.85, 0.3 }, pts = { 0, 4, -2, 4, -8, 9, -6, 9 } },
      { color = { 1, 0.55, 0.2 }, pts = { 16, 0, 6, -3, -8, -4, -11, -2, -11, 2, -8, 4, 6, 3 } },
    },
    cockpit = { x = 4, y = 0, rx = 4, ry = 1.8, color = { 0.3, 0.05, 0.05 } },
    engines = { { x = -10, y = -6, w = 2 }, { x = -10, y = 6, w = 2 } },
    flame = { { 1, 0.4, 0.1 }, { 1, 0.9, 0.4 } },
  },
  -- "Viper": silver needle with forward-swept green wings
  {
    name = "VIPER", desc = "Forward-swept racer", tint = { 0.4, 1, 0.5 },
    parts = {
      { color = { 0.3, 0.9, 0.4 }, pts = { -2, -2, 4, -12, 1, -13, -8, -3 } },
      { color = { 0.3, 0.9, 0.4 }, pts = { -2, 2, -8, 3, 1, 13, 4, 12 } },
      { color = { 0.8, 0.85, 0.85 }, pts = { 15, 0, 5, -2.5, -9, -3, -11, 0, -9, 3, 5, 2.5 } },
    },
    cockpit = { x = 5, y = 0, rx = 3.5, ry = 1.5, color = { 0.1, 0.4, 0.15 } },
    engines = { { x = -11, y = 0, w = 2 } },
    flame = { { 0.3, 1, 0.4 }, { 0.85, 1, 0.85 } },
  },
  -- "Nova": purple diamond hull between two swept pods, twin engines
  {
    name = "NOVA", desc = "Twin-pod cruiser", tint = { 0.75, 0.5, 1 },
    parts = {
      { color = { 0.55, 0.25, 0.9 }, pts = { 2, -6, -4, -12, -10, -11, -6, -5 } },
      { color = { 0.55, 0.25, 0.9 }, pts = { 2, 6, -6, 5, -10, 11, -4, 12 } },
      { color = { 0.85, 0.65, 1 }, pts = { 13, 0, 0, -5, -10, 0, 0, 5 } },
    },
    cockpit = { x = 2, y = 0, rx = 3, ry = 2, color = { 0.2, 0, 0.3 } },
    engines = { { x = -9, y = -8.5, w = 2 }, { x = -9, y = 8.5, w = 2 } },
    flame = { { 0.8, 0.3, 1 }, { 1, 0.8, 1 } },
  },
  -- "Hornet": stubby yellow hull with black stripes and dark stub wings
  {
    name = "HORNET", desc = "Armored stinger", tint = { 1, 0.85, 0.2 },
    parts = {
      { color = { 0.35, 0.35, 0.38 }, pts = { -2, -6, -8, -12, -10, -11, -8, -6 } },
      { color = { 0.35, 0.35, 0.38 }, pts = { -2, 6, -8, 6, -10, 11, -8, 12 } },
      { color = { 1, 0.85, 0.1 }, pts = { 12, 0, 6, -6, -8, -7, -11, 0, -8, 7, 6, 6 } },
      { color = { 0.12, 0.12, 0.12 }, pts = { 0, -6.2, -3, -6.4, -3, 6.4, 0, 6.2 } },
      { color = { 0.12, 0.12, 0.12 }, pts = { -5, -6.5, -7, -6.6, -7, 6.6, -5, 6.5 } },
    },
    cockpit = { x = 6, y = 0, rx = 3, ry = 2.5, color = { 0.1, 0.1, 0.15 } },
    engines = { { x = -11, y = 0, w = 3 } },
    flame = { { 1, 0.75, 0.1 }, { 1, 1, 0.8 } },
  },
}

local function drawShip(id, x, y, angle, s, thrust, alpha)
  local ship = SHIPS[id]
  alpha = alpha or 1
  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.rotate(angle)
  love.graphics.scale(s or 1)

  -- flickering engine flames, longer when thrusting
  if thrust then
    local len = 3 + thrust * 6 + love.math.random() * 3
    for _, en in ipairs(ship.engines) do
      love.graphics.setColor(ship.flame[1][1], ship.flame[1][2], ship.flame[1][3], 0.8 * alpha)
      love.graphics.polygon("fill", en.x, en.y - en.w, en.x, en.y + en.w, en.x - len, en.y)
      love.graphics.setColor(ship.flame[2][1], ship.flame[2][2], ship.flame[2][3], alpha)
      love.graphics.polygon("fill", en.x, en.y - en.w * 0.5, en.x, en.y + en.w * 0.5, en.x - len * 0.5, en.y)
    end
  end

  love.graphics.setLineWidth(1)
  for _, part in ipairs(ship.parts) do
    local c = part.color
    love.graphics.setColor(c[1], c[2], c[3], alpha)
    love.graphics.polygon("fill", part.pts)
    love.graphics.setColor(c[1] * 0.45, c[2] * 0.45, c[3] * 0.45, alpha)
    love.graphics.polygon("line", part.pts)
  end
  local ck = ship.cockpit
  love.graphics.setColor(ck.color[1], ck.color[2], ck.color[3], alpha)
  love.graphics.ellipse("fill", ck.x, ck.y, ck.rx, ck.ry)
  love.graphics.setColor(1, 1, 1, 0.7 * alpha)
  love.graphics.circle("fill", ck.x + 1, ck.y - 0.8, 0.9)
  love.graphics.pop()
end

---------------------------------------------------------------- drawing

local function drawStar(s)
  local pulse = 1 + math.sin(s.t * 5) * 0.2
  love.graphics.push()
  love.graphics.translate(s.x, s.y)
  love.graphics.rotate(s.t)
  love.graphics.scale(pulse)
  love.graphics.setColor(1, 0.85, 0.2)
  for _, tri in ipairs(starTris) do love.graphics.polygon("fill", tri) end
  love.graphics.pop()
end

local function drawHeart(x, y, s)
  love.graphics.circle("fill", x - 4 * s, y - 2 * s, 4.5 * s)
  love.graphics.circle("fill", x + 4 * s, y - 2 * s, 4.5 * s)
  love.graphics.polygon("fill", x - 8.4 * s, y - 0.5 * s, x + 8.4 * s, y - 0.5 * s, x, y + 9 * s)
end

local function drawEnemy(e)
  local c = ENEMIES[e.kind].color
  if e.flash > 0 then love.graphics.setColor(1, 1, 1) else love.graphics.setColor(c) end
  love.graphics.push()
  love.graphics.translate(e.x, e.y)
  if e.kind == "drone" then
    love.graphics.rotate(aimAt(e))
    love.graphics.polygon("fill", 12, 0, 0, -10, -10, 0, 0, 10)
    love.graphics.setColor(0.1, 0.05, 0.1)
    love.graphics.circle("fill", 3, 0, 3)
  elseif e.kind == "spinner" then
    love.graphics.rotate(e.t * 2)
    local pts = {}
    for k = 0, 5 do
      pts[#pts + 1] = math.cos(k * math.pi / 3) * 15
      pts[#pts + 1] = math.sin(k * math.pi / 3) * 15
    end
    love.graphics.setLineWidth(3)
    love.graphics.polygon("line", pts)
    love.graphics.circle("fill", 0, 0, 6)
  elseif e.kind == "hunter" then
    love.graphics.rotate(e.dir == 1 and 0 or math.pi)
    love.graphics.polygon("fill", 14, 0, -10, -10, -4, 0, -10, 10)
    love.graphics.polygon("fill", -2, -4, -14, -12, -8, -2)
    love.graphics.polygon("fill", -2, 4, -14, 12, -8, 2)
  end
  love.graphics.pop()
end

local function drawBoss(b)
  local enraged = b.hp < b.maxHp / 2
  local c = b.flash > 0 and { 1, 1, 1 } or b.color
  love.graphics.push()
  love.graphics.translate(b.x, b.y)
  -- wings
  love.graphics.setColor(c[1] * 0.55, c[2] * 0.55, c[3] * 0.55)
  love.graphics.polygon("fill", -20, -10, -62, -26, -72, 8, -30, 18)
  love.graphics.polygon("fill", 20, -10, 30, 18, 72, 8, 62, -26)
  -- cannons
  love.graphics.setColor(0.3, 0.3, 0.35)
  love.graphics.rectangle("fill", -30, 18, 8, 16)
  love.graphics.rectangle("fill", 22, 18, 8, 16)
  -- hull
  local pts = {}
  for k = 0, 5 do
    pts[#pts + 1] = math.cos(k * math.pi / 3 + math.pi / 6) * 34
    pts[#pts + 1] = math.sin(k * math.pi / 3 + math.pi / 6) * 30
  end
  love.graphics.setColor(c)
  love.graphics.polygon("fill", pts)
  love.graphics.setColor(c[1] * 0.4, c[2] * 0.4, c[3] * 0.4)
  love.graphics.setLineWidth(3)
  love.graphics.polygon("line", pts)
  -- glowing core, red and pulsing faster when angry
  local pulse = math.sin(b.t * (enraged and 14 or 6))
  love.graphics.setColor(1, enraged and 0.2 or 0.85, 0.3, 0.35)
  love.graphics.circle("fill", 0, 0, 16 + pulse * 3)
  love.graphics.setColor(1, enraged and 0.3 or 0.95, 0.4)
  love.graphics.circle("fill", 0, 0, 9 + pulse * 2)
  love.graphics.pop()
end

local function drawPickup(pk)
  -- blink during the last 1.5 seconds
  if pk.t < 1.5 and math.floor(pk.t * 8) % 2 == 0 then return end
  local pulse = 1 + math.sin(pk.t * 8) * 0.12
  local c = PICKUP_COLORS[pk.kind]
  if pk.kind == "missile" or pk.kind == "bomb" then
    love.graphics.setColor(c[1], c[2], c[3], 0.3)
    love.graphics.circle("fill", pk.x, pk.y, 13 * pulse)
    love.graphics.setColor(c)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", pk.x, pk.y, 13 * pulse)
    if pk.kind == "missile" then
      love.graphics.polygon("fill", pk.x, pk.y - 9, pk.x + 3, pk.y - 4, pk.x + 3, pk.y + 5, pk.x - 3, pk.y + 5, pk.x - 3, pk.y - 4)
      love.graphics.polygon("fill", pk.x - 3, pk.y + 1, pk.x - 7, pk.y + 7, pk.x - 3, pk.y + 5)
      love.graphics.polygon("fill", pk.x + 3, pk.y + 1, pk.x + 3, pk.y + 5, pk.x + 7, pk.y + 7)
    else
      love.graphics.circle("fill", pk.x, pk.y + 2, 6)
      love.graphics.setColor(1, 0.9, 0.5)
      love.graphics.line(pk.x + 3, pk.y - 3, pk.x + 6, pk.y - 8)
      love.graphics.circle("fill", pk.x + 6, pk.y - 8, 1.5 + pulse)
    end
    return
  end
  if pk.kind == "life" then
    love.graphics.setColor(1, 0.4, 0.6, 0.35)
    love.graphics.circle("line", pk.x, pk.y, 15 * pulse)
    love.graphics.setColor(1, 0.4, 0.6)
    drawHeart(pk.x, pk.y - 1, pulse)
  else
    love.graphics.setColor(0.4, 0.9, 1, 0.35)
    love.graphics.circle("fill", pk.x, pk.y, 13 * pulse)
    love.graphics.setColor(0.4, 0.9, 1)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", pk.x, pk.y, 13 * pulse)
    love.graphics.polygon("fill", pk.x - 6, pk.y - 6, pk.x + 6, pk.y - 6, pk.x + 6, pk.y + 1, pk.x, pk.y + 7, pk.x - 6, pk.y + 1)
  end
end

local function drawPlayer(p)
  if not p.alive then return end
  -- blink while invulnerable after a hit
  if p.hurt > 0 and math.floor(p.hurt * 10) % 2 == 1 then return end
  drawShip(p.ship, p.x, p.y, p.angle, 1, p.thrust)
  if p.dash > 0 then
    love.graphics.setColor(1, 1, 1, 0.5)
    love.graphics.circle("line", p.x, p.y, 14)
  end
  -- shield bubble, flickers when about to run out
  if p.shield > 0 and (p.shield > 2 or math.floor(p.shield * 8) % 2 == 0) then
    love.graphics.setColor(0.4, 0.9, 1, 0.25)
    love.graphics.circle("fill", p.x, p.y, 19)
    love.graphics.setColor(0.4, 0.9, 1, 0.8)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", p.x, p.y, 19 + math.sin(love.timer.getTime() * 10))
  end
  if numPlayers == 2 then
    love.graphics.setFont(fontTiny)
    love.graphics.setColor(SHIPS[p.ship].tint)
    love.graphics.printf("P" .. p.id, p.x - 20, p.y - 28, 40, "center")
  end
end

local function centered(text, y, font)
  love.graphics.setFont(font)
  love.graphics.printf(text, 0, y, W, "center")
end

-- corner panel for one player: lives on top, gun/shield/dash at the bottom
local function drawPlayerHud(p)
  local right = p.id == 2
  local tint = SHIPS[p.ship].tint
  local function line(text, y)
    if right then love.graphics.printf(text, 0, y, W - 12, "right")
    else love.graphics.print(text, 12, y) end
  end

  love.graphics.setFont(fontSmall)
  if numPlayers == 2 then
    love.graphics.setColor(tint)
    line("P" .. p.id, 6)
  end
  local x0 = numPlayers == 2 and 44 or 20
  for i = 1, p.lives do
    local x = right and (W - x0 - (i - 1) * 23) or (x0 + (i - 1) * 23)
    drawShip(p.ship, x, 16, -math.pi / 2, 0.7)
  end

  if not p.alive then
    love.graphics.setColor(1, 1, 1, 0.6)
    line("DOWN - back next level", H - 26)
    return
  end
  local g = GUNS[p.gun]
  love.graphics.setColor(g.color)
  line(g.name .. (unlockedGuns() > 1 and "  (L/R)" or ""), H - 26)
  love.graphics.setColor(1, 0.65, 0.3)
  line("MISSILE x" .. p.missiles .. "  BOMB x" .. p.bombs, H - 66)
  local status = {}
  if p.shield > 0 then status[#status + 1] = "SHIELD " .. math.ceil(p.shield) end
  if p.dashCd <= 0 then status[#status + 1] = "DASH" end
  love.graphics.setColor(0.5, 0.85, 1)
  line(table.concat(status, "  "), H - 46)
end

local function drawHud()
  love.graphics.setFont(fontSmall)
  love.graphics.setColor(1, 1, 1)
  love.graphics.printf((boss and ("BOSS " .. boss.tier) or ("LV " .. level)) .. "    " .. score, 0, 6, W, "center")
  love.graphics.setColor(diff.color[1], diff.color[2], diff.color[3], 0.6)
  love.graphics.setFont(fontTiny)
  love.graphics.printf(diff.name .. "   BEST " .. best, 0, 40, W - 12, "right")

  -- level progress bar, or the boss's health
  local frac = boss and boss.hp / boss.maxHp or starsGot / starsNeeded()
  love.graphics.setColor(1, 1, 1, 0.15)
  love.graphics.rectangle("fill", 12, 30, W - 24, boss and 5 or 3)
  if boss then love.graphics.setColor(1, 0.25, 0.3) else love.graphics.setColor(1, 0.85, 0.2) end
  love.graphics.rectangle("fill", 12, 30, (W - 24) * frac, boss and 5 or 3)

  for _, p in ipairs(players) do drawPlayerHud(p) end
end

local function drawWorld()
  love.graphics.clear(0.04, 0.04, 0.09)
  for _, b in ipairs(bgstars) do
    love.graphics.setColor(1, 1, 1, b.speed / 60)
    love.graphics.rectangle("fill", b.x, b.y, 1, 1)
  end

  if state == "title" or state == "select" then return end

  if not boss then
    for _, s in ipairs(stars) do drawStar(s) end
  end
  for _, pk in ipairs(pickups) do drawPickup(pk) end

  love.graphics.setLineWidth(2)
  for _, r in ipairs(rocks) do
    if r.flash > 0 then love.graphics.setColor(1, 1, 1) else love.graphics.setColor(0.55, 0.5, 0.6) end
    love.graphics.push()
    love.graphics.translate(r.x, r.y)
    love.graphics.rotate(r.rot)
    love.graphics.polygon("line", r.pts)
    love.graphics.pop()
  end

  for _, e in ipairs(enemies) do drawEnemy(e) end
  if boss then drawBoss(boss) end

  for _, b in ipairs(bullets) do
    love.graphics.setColor(b.color)
    love.graphics.circle("fill", b.x, b.y, b.super and 5 or b.homing and 3.5 or 2.5)
  end

  for _, b in ipairs(ebullets) do
    love.graphics.setColor(ENEMY_COLOR)
    love.graphics.circle("fill", b.x, b.y, 4)
    love.graphics.setColor(1, 0.9, 0.9)
    love.graphics.circle("fill", b.x, b.y, 1.8)
  end

  for _, p in ipairs(particles) do
    love.graphics.setColor(p.color[1], p.color[2], p.color[3], p.life * 2)
    love.graphics.rectangle("fill", p.x - 1.5, p.y - 1.5, 3, 3)
  end

  if state == "play" or state == "pause" then
    for _, p in ipairs(players) do drawPlayer(p) end
  end

  drawHud()
  if flash > 0 then
    love.graphics.setColor(1, 1, 1, flash * 1.6)
    love.graphics.rectangle("fill", 0, 0, W, H)
  end
end

local function drawTitle()
  local t = love.timer.getTime()
  centered("STAR DRIFT", 70, fontBig)
  -- the whole fleet showing off
  for k = 1, #SHIPS do
    local x = W / 2 + (k - (#SHIPS + 1) / 2) * 70
    drawShip(k, x, 150 + math.sin(t * 2 + k) * 4, -math.pi / 2, 2, 0.6)
  end

  for i, label in ipairs({ "1 PLAYER", "2 PLAYERS" }) do
    local y = 230 + (i - 1) * 28
    if menuSel == i then
      love.graphics.setColor(1, 0.85, 0.3)
      centered("> " .. label .. " <", y, fontSmall)
    else
      love.graphics.setColor(1, 1, 1, 0.6)
      centered(label, y, fontSmall)
    end
  end

  local dc = diff.color
  love.graphics.setColor(dc)
  centered("DIFFICULTY   <  " .. diff.name .. "  >", 290, fontSmall)

  love.graphics.setColor(1, 1, 1, 0.8)
  local p2hint = #pads >= 2 and "2 players: each presses A on the ship select screen to join"
                or "P2: plug in a 2nd gamepad, or arrows + . (fire) / (dash) , (gun)"
  centered("Shoot (A/RT)  Aim (right stick)  Dash (B/LT)  Bomb (X)  Missile (Y)  Gun (L/R)\n" .. p2hint, 325, fontTiny)
  centered("UP/DOWN choose   LEFT/RIGHT difficulty   START continue", 370, fontSmall)
  love.graphics.setColor(1, 1, 1, 0.5)
  centered("Best (" .. diff.name .. "): " .. best, 400, fontSmall)
end

local function shipTaken(id, ship)
  for other = 1, numPlayers do
    if other ~= id and picks[other].ready and picks[other].ship == ship then return true end
  end
  return false
end

-- one panel per player: big preview, name, the fleet as icons, and ready state
local function drawSelectPanel(id, cx)
  local pk = picks[id]
  local ship = SHIPS[pk.ship]
  local t = love.timer.getTime()
  local taken = not pk.ready and shipTaken(id, pk.ship)

  love.graphics.setColor(ship.tint[1], ship.tint[2], ship.tint[3], pk.ready and 0.9 or 0.35)
  love.graphics.setLineWidth(pk.ready and 3 or 1)
  love.graphics.rectangle("line", cx - 130, 92, 260, 300, 10)

  love.graphics.setColor(1, 1, 1, 0.8)
  love.graphics.setFont(fontSmall)
  love.graphics.printf("PLAYER " .. id, cx - 130, 100, 260, "center")
  if numPlayers == 2 and #pads > 0 then
    love.graphics.setFont(fontTiny)
    if playerPad[id] then
      love.graphics.setColor(0.4, 1, 0.5, 0.8)
      love.graphics.printf("CONTROLLER CONNECTED", cx - 130, 122, 260, "center")
    else
      love.graphics.setColor(1, 0.85, 0.3, 0.6 + 0.4 * math.abs(math.sin(t * 3)))
      love.graphics.printf("PRESS A ON A CONTROLLER TO JOIN", cx - 130, 122, 260, "center")
    end
  end

  drawShip(pk.ship, cx, 190 + math.sin(t * 2.5) * 5, -math.pi / 2, 3.5, 0.8, taken and 0.35 or 1)

  love.graphics.setColor(ship.tint)
  love.graphics.setFont(fontSmall)
  local name = pk.ready and ship.name or ("<  " .. ship.name .. "  >")
  love.graphics.printf(name, cx - 130, 262, 260, "center")
  love.graphics.setColor(1, 1, 1, 0.6)
  love.graphics.setFont(fontTiny)
  love.graphics.printf(ship.desc, cx - 130, 284, 260, "center")

  for k = 1, #SHIPS do
    local x = cx + (k - (#SHIPS + 1) / 2) * 44
    if k == pk.ship then
      love.graphics.setColor(1, 1, 1, 0.5)
      love.graphics.setLineWidth(1)
      love.graphics.circle("line", x, 322, 17)
    end
    local alpha = (k == pk.ship) and 1 or 0.4
    if shipTaken(id, k) then alpha = 0.12 end
    drawShip(k, x, 322, -math.pi / 2, 1, nil, alpha)
  end

  love.graphics.setFont(fontSmall)
  if pk.ready then
    love.graphics.setColor(0.4, 1, 0.5)
    love.graphics.printf("READY!", cx - 130, 356, 260, "center")
  elseif taken then
    love.graphics.setColor(1, 0.35, 0.35)
    love.graphics.printf("TAKEN - pick another", cx - 130, 356, 260, "center")
  else
    love.graphics.setColor(1, 1, 1, 0.6)
    love.graphics.printf("A to confirm", cx - 130, 356, 260, "center")
  end
end

local function drawSelect()
  love.graphics.setColor(1, 1, 1)
  centered("CHOOSE YOUR SHIP", 36, fontBig)
  if numPlayers == 1 then
    drawSelectPanel(1, W / 2)
  else
    drawSelectPanel(1, W / 4 + 10)
    drawSelectPanel(2, W * 3 / 4 - 10)
  end
  love.graphics.setColor(1, 1, 1, 0.7)
  local keys = numPlayers == 2 and "\nKeyboard  P1: A/D + Space    P2: arrows + ." or "\nKeyboard: arrows + Space"
  centered("LEFT/RIGHT choose   A confirm   B change   SELECT back" .. keys, 410, fontTiny)
end

local function dim()
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", 0, 0, W, H)
  love.graphics.setColor(1, 1, 1)
end

local function drawEntry()
  dim()
  centered("GAME OVER", 100, fontBig)
  centered("Level " .. level .. "    Score " .. score, 160, fontSmall)
  love.graphics.setColor(1, 0.85, 0.3)
  centered("ENTER YOUR INITIALS", 205, fontSmall)
  love.graphics.setFont(fontBig)
  for i, b in ipairs(entry.letters) do
    local x = W / 2 + (i - 2) * 56
    local cur = i == entry.pos
    if cur then
      local blink = math.floor(love.timer.getTime() * 3) % 2 == 0
      love.graphics.setColor(1, 0.85, 0.3, blink and 1 or 0.6)
      love.graphics.polygon("fill", x - 7, 250, x + 7, 250, x, 241)
      love.graphics.polygon("fill", x - 7, 304, x + 7, 304, x, 313)
      love.graphics.rectangle("fill", x - 18, 297, 36, 3)
    else
      love.graphics.setColor(1, 1, 1, 0.8)
    end
    love.graphics.printf(string.char(b), x - 30, 253, 60, "center")
  end
  love.graphics.setColor(1, 1, 1, 0.7)
  centered("UP/DOWN letter   LEFT/RIGHT move   A next   START save\nKeyboard: type letters, Enter to save   SELECT skip", 345, fontTiny)
end

local function drawScoreTable()
  dim()
  centered("GAME OVER", 50, fontBig)
  centered("Level " .. level .. "    Score " .. score, 100, fontSmall)
  love.graphics.setColor(1, 0.85, 0.3)
  centered((Scores.status == "online" and "WORLD TOP 5" or "TOP 5") .. " - " .. diff.name, 140, fontSmall)
  love.graphics.setFont(fontSmall)
  for i = 1, 5 do
    local e, y = Scores.top[i], 172 + (i - 1) * 28
    if i == Scores.rank then
      love.graphics.setColor(1, 0.85, 0.3, 0.2)
      love.graphics.rectangle("fill", W / 2 - 150, y - 3, 300, 24, 4)
      love.graphics.setColor(1, 0.85, 0.3)
    else
      love.graphics.setColor(1, 1, 1, e and 0.9 or 0.3)
    end
    love.graphics.print(i .. ".", W / 2 - 140, y)
    love.graphics.print(e and e.name or "---", W / 2 - 100, y)
    love.graphics.printf(e and tostring(e.score) or "", W / 2 - 60, y, 110, "right")
    love.graphics.printf(e and ("LV " .. e.level) or "", W / 2 + 60, y, 80, "right")
  end
  love.graphics.setColor(1, 1, 1, 0.7)
  local note = ""
  if Scores.rank and Scores.rank > 5 then note = "You placed #" .. Scores.rank end
  if Scores.status == "loading" then note = "Loading scores..."
  elseif Scores.status == "offline" then note = "Offline - showing scores saved on this device" end
  centered(note, 320, fontTiny)
  love.graphics.setColor(1, 1, 1)
  centered("START retry   SELECT title screen", 370, fontSmall)
end

local function drawOverlay()
  love.graphics.setColor(1, 1, 1)
  if state == "title" then
    drawTitle()
  elseif state == "select" then
    drawSelect()
  elseif state == "pause" then
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, W, H)
    love.graphics.setColor(1, 1, 1)
    centered("PAUSED", 170, fontBig)
    if pauseNote then
      love.graphics.setColor(1, 0.5, 0.4)
      centered(pauseNote, 215, fontTiny)
      love.graphics.setColor(1, 1, 1)
    end
    centered("START resume   SELECT title screen\nY / M music on/off", 250, fontSmall)
  elseif state == "entry" then
    drawEntry()
  elseif state == "over" then
    drawScoreTable()
  elseif state == "play" and banner > 0 then
    local a = math.min(1, banner)
    love.graphics.setColor(1, 1, 1, a)
    centered(bannerText, 150, fontBig)
    love.graphics.setColor(1, 0.85, 0.4, a)
    centered(bannerSub, 205, fontSmall)
  end
end

---------------------------------------------------------------- love callbacks

local function refreshPads() pads = love.joystick.getJoysticks() end
local action  -- input handler, defined below the callbacks

function love.load()
  love.graphics.setDefaultFilter("nearest", "nearest")
  if HANDHELD then love.window.setFullscreen(true) end
  love.mouse.setVisible(not HANDHELD)
  if not HANDHELD and not WEB and not TEST and not TEST_SELECT then love.window.maximize() end
  resize(love.graphics.getDimensions())
  if TESTING then  -- keep test scores out of the real save folder
    love.filesystem.setIdentity("stardrift-test")
    love.filesystem.remove("scores.txt")
  end
  for i, d in ipairs(DIFFICULTIES) do
    if d.key == readSave("difficulty.txt") then diffSel = i end
  end
  if TESTING then diffSel = 2 end
  setDifficulty(diffSel)
  Scores.load(WEB)
  bgstars = {}
  for _ = 1, 80 do
    bgstars[#bgstars + 1] = { x = love.math.random(W), y = love.math.random(H), speed = love.math.random(10, 60) }
  end
  refreshPads()
  Audio.load()
  if TEST then love.audio.setVolume(0); numPlayers = 2 end
  Audio.startMusic()
  newGame()
  if TEST_SELECT then
    love.audio.setVolume(0)
    menuSel = 2
    action("confirm", 1)          -- title -> select screen in 2-player mode
    action("right", 1)            -- P1 moves to VIPER (3) ...
    action("right", 1)
    action("confirm", 1)          -- ... and locks it in
    action("right", 2)            -- P2 also moves onto VIPER, which is now taken
  end
  if TEST_BOSS then
    love.audio.setVolume(0)
    numPlayers = 2
    newGame()
    state, level = "play", 3
    startBoss()
  end
  if TEST_SCORES then
    love.audio.setVolume(0)
    state, score, level = "play", 1234, 3
    gameOver()
    entry.letters = { 65, 65, 65 }  -- AAA
    action("up", 1)               -- B
    action("right", 1)
    action("down", 1)             -- Z
    action("confirm", 1)
    action("confirm", 1)          -- last slot: saves "BZA"
  end
end

function love.resize(w, h) resize(w, h) end

function love.joystickadded() refreshPads() end

function love.joystickremoved(j)
  refreshPads()
  stickState[j] = nil
  local id = padOwner[j]
  if id then padOwner[j], playerPad[id] = nil, nil end
  if state == "play" and (id or numPlayers == 1) then
    state = "pause"
    pauseNote = id and ("P" .. id .. " CONTROLLER DISCONNECTED - reconnect it and press A to rejoin")
                or "CONTROLLER DISCONNECTED"
  end
end

-- the left stick sends up/down/left/right in menus, repeating while held
local function stickMenus(dt)
  if TESTING then return end
  for _, j in ipairs(pads) do
    if j:isGamepad() then
      local x, y = j:getGamepadAxis("leftx"), j:getGamepadAxis("lefty")
      local dir
      if math.abs(x) > 0.6 and math.abs(x) > math.abs(y) then dir = x > 0 and "right" or "left"
      elseif math.abs(y) > 0.6 then dir = y > 0 and "down" or "up" end
      local s = stickState[j] or {}
      stickState[j] = s
      local fire = false
      if dir ~= s.dir then
        s.dir, s.t, fire = dir, 0.4, dir ~= nil
      elseif dir then
        s.t = s.t - dt
        if s.t <= 0 then s.t, fire = 0.15, true end
      end
      local id = (numPlayers == 1 or state == "title") and 1 or padOwner[j]
      if fire and id then action(dir, id) end
    end
  end
end

function love.update(dt)
  dt = math.min(dt, 1 / 20)  -- avoid huge jumps on frame hitches
  if TEST then
    testTime = testTime + dt
    if state == "title" then newGame(); state = "play" end
    if level == 1 and testTime > 1 then startLevel(7) end  -- jump ahead so everything is unlocked
    if testTime > 3.6 and not testSpawned then
      testSpawned = true
      for _, k in ipairs(ENEMY_ORDER) do spawnEnemy(k) end
      spawnPickup("shield")
      spawnPickup("missile")
      spawnPickup("bomb")
      players[2].shield = 8
      players[1].missiles = 2
      fireMissile(players[1])
    end
    if love.math.random() < 0.02 then switchGun(players[love.math.random(2)], 1) end
    if testTime > 4.4 and not testShot then
      testShot = true
      love.graphics.captureScreenshot("screenshot.png")
    elseif testTime > 12 then
      local lives = {}
      for _, p in ipairs(players) do lives[#lives + 1] = p.id .. ":" .. p.lives .. (p.alive and "" or "(down)") end
      print("TEST state=" .. state .. " level=" .. level .. " score=" .. score .. " lives=" .. table.concat(lives, ",") ..
            " enemies=" .. #enemies .. " ebullets=" .. #ebullets)
      love.event.quit()
    end
  end
  if TEST_SELECT then
    testTime = testTime + dt
    if testTime > 0.5 and not testShot then
      testShot = true
      action("confirm", 2)         -- must be refused: VIPER is taken by P1
      print("TEST P2 on taken ship ready=" .. tostring(picks[2].ready))
      love.graphics.captureScreenshot("select.png")
    elseif testTime > 1 and not testSpawned then
      testSpawned = true
      action("right", 2)           -- NOVA
      action("confirm", 2)
    elseif testTime > 2.5 then
      print("TEST state=" .. state .. " P1 ship=" .. SHIPS[players[1].ship].name ..
            " P2 ship=" .. SHIPS[players[2].ship].name)
      love.event.quit()
    end
  end
  if TEST_BOSS then
    testTime = testTime + dt
    for _, p in ipairs(players) do p.hurt = 1 end  -- invulnerable, so the fight is deterministic
    if testTime > 3.5 and not testSpawned then
      testSpawned = true
      local hp = boss.hp
      players[1].missiles = 1
      fireMissile(players[1])
      superBomb(players[2])
      print("TEST bomb took " .. math.floor(hp - boss.hp) .. " of " .. math.floor(boss.maxHp) .. " boss hp")
    elseif testTime > 5 and not testShot then
      testShot = true
      love.graphics.captureScreenshot("boss.png")
    elseif testTime > 6 and boss and not boss.dying then
      hitBoss(boss.hp, players[1])
      print("TEST boss defeated, score=" .. score)
    elseif testTime > 10 then
      print("TEST state=" .. state .. " level=" .. level .. " boss=" .. tostring(boss) .. " pickups=" .. #pickups)
      love.event.quit()
    end
  end
  if TEST_SCORES then
    testTime = testTime + dt
    if testTime > 0.5 and not testShot then
      testShot = true
      love.graphics.captureScreenshot("scores.png")
    elseif testTime > 1 then
      local top = {}
      for _, e in ipairs(Scores.top) do top[#top + 1] = e.name .. "=" .. e.score end
      print("TEST state=" .. state .. " rank=" .. tostring(Scores.rank) .. " status=" .. Scores.status ..
            " top=" .. table.concat(top, ","))
      love.event.quit()
    end
  end
  Scores.update(dt)
  if state ~= "play" then stickMenus(dt) end
  if state == "select" and startDelay then
    startDelay = startDelay - dt
    if startDelay <= 0 then
      startDelay = nil
      newGame()
      state = "play"
    end
  end
  if state == "play" then updatePlay(dt) end
  if state ~= "pause" then updateParticles(dt) end
end

function love.draw()
  love.graphics.setCanvas(canvas)
  love.graphics.push()
  if shake > 0 then
    love.graphics.translate((love.math.random() - 0.5) * 10 * shake, (love.math.random() - 0.5) * 10 * shake)
  end
  drawWorld()
  love.graphics.pop()
  drawOverlay()
  love.graphics.setCanvas()

  love.graphics.clear(0, 0, 0)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(canvas, offx, offy, 0, scale, scale)
end

local function entryAction(a)
  local e = entry
  if a == "up" or a == "down" then
    local b = e.letters[e.pos] - 65 + (a == "up" and 1 or -1)
    e.letters[e.pos] = b % 26 + 65
  elseif a == "left" or a == "prev" or a == "dash" then
    e.pos = math.max(1, e.pos - 1)
  elseif a == "right" or a == "next" then
    e.pos = math.min(3, e.pos + 1)
  elseif a == "confirm" then
    if e.pos < 3 then e.pos = e.pos + 1 else submitEntry() end
  elseif a == "start" then
    submitEntry()
  elseif a == "back" then
    Scores.refresh(diff.key)
    state = "over"
  end
end

local function selectAction(a, id)
  if a == "back" then state = "title"; startDelay = nil; return end
  local pk = picks[id]
  if id > numPlayers then return end
  if not pk.ready then
    local dir = (a == "left" or a == "prev") and -1 or (a == "right" or a == "next") and 1 or 0
    if dir ~= 0 then
      pk.ship = (pk.ship - 1 + dir) % #SHIPS + 1
      Audio.play("blaster", 0)
    elseif a == "confirm" or a == "start" then
      if shipTaken(id, pk.ship) then
        Audio.play("deflect", 0)
      else
        pk.ready = true
        Audio.play("pickup", 0)
        local all = true
        for i = 1, numPlayers do all = all and picks[i].ready end
        if all then startDelay = 0.7 end
      end
    end
  elseif a == "dash" then
    pk.ready = false
    startDelay = nil
  end
end

-- shared action handler for keyboard and gamepad; id = acting player number
function action(a, id)
  local p = players[id]
  if a == "music" then Audio.toggleMusic(); return end
  if state == "title" then
    if a == "up" or a == "down" then
      menuSel = menuSel == 1 and 2 or 1
    elseif a == "left" or a == "right" then
      setDifficulty(diffSel + (a == "right" and 1 or -1))
      love.filesystem.write("difficulty.txt", diff.key)
      Audio.play("blaster", 0)
    elseif a == "start" or a == "confirm" then
      numPlayers = menuSel
      for _, pk in ipairs(picks) do pk.ready = false end
      padOwner, playerPad = {}, {}  -- 2-player: pads join again on the select screen
      state = "select"
    elseif a == "back" and not WEB then   -- quitting in a browser only leaves a frozen canvas
      love.event.quit()
    end
  elseif state == "select" then
    selectAction(a, id)
  elseif state == "entry" then
    entryAction(a)
  elseif state == "over" then
    if a == "start" or a == "confirm" then newGame(); state = "play"
    elseif a == "back" then state = "title" end
  elseif state == "pause" then
    if a == "start" then state = "play"; pauseNote = nil
    elseif a == "back" then state = "title"; pauseNote = nil
    elseif a == "next" or a == "missile" then Audio.toggleMusic() end
  elseif state == "play" and p then
    if a == "start" or a == "back" then state = "pause"; stopRumble()
    elseif a == "dash" then tryDash(p)
    elseif a == "bomb" then superBomb(p)
    elseif a == "missile" then fireMissile(p)
    elseif a == "next" then switchGun(p, 1)
    elseif a == "prev" then switchGun(p, -1) end
  end
end

local GLOBAL_KEYS = { ["return"] = "start", escape = "back", backspace = "back", m = "music" }
local ENTRY_KEYS = {
  up = "up", down = "down", left = "left", right = "right", ["return"] = "start", kpenter = "start",
  backspace = "dash", escape = "back",
}
local MENU_KEYS = {
  up = "up", w = "up", down = "down", s = "down", left = "left", a = "left", right = "right", d = "right",
  space = "confirm", z = "confirm",
}

function love.keypressed(k)
  if k == "f11" then
    love.window.setFullscreen(not love.window.getFullscreen())
    return resize(love.graphics.getDimensions())
  end
  -- letters arrive through love.textinput while typing initials
  if state == "entry" then
    if ENTRY_KEYS[k] then action(ENTRY_KEYS[k], 1) end
    return
  end
  if GLOBAL_KEYS[k] then return action(GLOBAL_KEYS[k], 1) end
  if state == "title" and MENU_KEYS[k] then return action(MENU_KEYS[k], 1) end
  -- per-player keys: find which player's key set owns this key
  for id = 1, numPlayers do
    for _, set in ipairs(keysetsFor({ id = id })) do
      for _, field in ipairs({ "dash", "prev", "next", "fire", "left", "right", "bomb", "missile" }) do
        for _, key in ipairs(set[field] or {}) do
          if key == k then return action(field == "fire" and "confirm" or field, id) end
        end
      end
    end
  end
end

function love.textinput(t)
  if state ~= "entry" or not t:match("^%a$") then return end
  entry.letters[entry.pos] = t:upper():byte()
  entry.pos = math.min(3, entry.pos + 1)
end

local PAD_ACTIONS = {
  start = "start", back = "back", a = "confirm", x = "bomb", y = "missile", b = "dash",
  leftshoulder = "prev", rightshoulder = "next", dpup = "up", dpdown = "down",
  dpleft = "left", dpright = "right",
}

function love.gamepadpressed(j, button)
  local a = PAD_ACTIONS[button]
  if not a or TESTING then return end
  local id, joined = padPlayer(j)
  if not id then return end  -- a 3rd pad in 2-player mode
  if joined then
    Audio.play("pickup", 0)
    j:setVibration(0.4, 0.4, 0.15)
    if state == "select" or state == "pause" then return end  -- the joining press does nothing else
  end
  action(a, id)
end
