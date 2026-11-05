-- Star Drift: steer a small ship, shoot rocks and enemies, collect stars to clear levels.
-- 1 or 2 players (co-op). Renders to a fixed 640x480 canvas, scaled to fit any screen.
--
-- Controls            Gamepad               Keyboard P1            Keyboard P2
--   move              d-pad / left stick    WASD                   arrows
--   fire (hold)       A or X                Space / F              Right Ctrl / .
--   dash              B                     Left Shift / G         /
--   switch gun        L1 / R1 / Y           Q / E                  ,
--   start / pause     Start                 Enter
--   music on/off      Y while paused        M
--   back / quit       Select                Esc
--   fullscreen                              F11
-- In 1-player mode every gamepad and both keyboard sets (plus Z / X / Tab) drive P1.
-- In 2-player mode gamepad 1 is P1 and gamepad 2 is P2.

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
local score, best, level, starsGot, spawnTimer, enemyTimer, levelTime, shake
local banner, bannerText, bannerSub
local pads = {}
local entry  -- initials on the entry screen: { letters = { byte, byte, byte }, pos = 1..3 }

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

local function loadBest()
  -- love.js raises an error for a missing file instead of returning nil
  if not love.filesystem.getInfo("best.txt") then return 0 end
  local ok, s = pcall(love.filesystem.read, "best.txt")
  return ok and tonumber(s) or 0
end

local function saveBest()
  love.filesystem.write("best.txt", tostring(best))
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
           dash = 0, dashCd = 0, cool = 0, gun = 1, lives = 3, hurt = 0, shield = 0,
           thrust = 0, alive = true }
end

---------------------------------------------------------------- guns

local function bullet(p, angle, speed, dmg, color, homing)
  bullets[#bullets + 1] = {
    x = p.x + math.cos(p.angle) * 12, y = p.y + math.sin(p.angle) * 12,
    vx = math.cos(angle) * speed, vy = math.sin(angle) * speed,
    life = 1.4, dmg = dmg, color = color, homing = homing,
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

-- homing missiles chase whatever rock or enemy is closest
local function nearestTarget(b)
  local best_, bestD = nil, math.huge
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

local function killEnemy(i)
  local e = enemies[i]
  table.remove(enemies, i)
  burst(e.x, e.y, ENEMIES[e.kind].color, 28, 200)
  score = score + ENEMIES[e.kind].pts
  shake = math.max(shake, 0.15)
  Audio.play("boom")
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
      Audio.play("enemyShot")
    end
  end
end

---------------------------------------------------------------- input

local KEYS = {
  { up = { "w" }, down = { "s" }, left = { "a" }, right = { "d" },
    fire = { "space", "f" }, dash = { "lshift", "g" }, prev = { "q" }, next = { "e" } },
  { up = { "up" }, down = { "down" }, left = { "left" }, right = { "right" },
    fire = { "rctrl", "." }, dash = { "/", "ralt" }, next = { "," } },
  -- extra keys that only apply in 1-player mode
  solo = { fire = { "z" }, dash = { "x" }, next = { "tab" } },
}

local function keysetsFor(p)
  if numPlayers == 1 then return { KEYS[1], KEYS[2], KEYS.solo } end
  return { KEYS[p.id] }
end

local function padsFor(p)
  if numPlayers == 1 then return pads end
  return { pads[p.id] }
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
  if TEST then dx, dy = math.cos(testTime * 1.3 + p.id * 2), math.sin(testTime * (0.7 + p.id * 0.2)) end
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 1 then dx, dy = dx / len, dy / len end
  return dx, dy
end

local function fireHeld(p)
  if TEST then return true end
  local list = padsFor(p)
  return keyDown(keysetsFor(p), "fire") or padDown(list, "a") or padDown(list, "x")
end

---------------------------------------------------------------- pickups

local function spawnPickup(kind)
  local a = love.math.random() * math.pi * 2
  pickups[#pickups + 1] = {
    kind = kind, x = love.math.random(60, W - 60), y = love.math.random(90, H - 60),
    vx = math.cos(a) * 70, vy = math.sin(a) * 70, t = 5,
  }
  Audio.play("appear", 0)
end

local function collectPickup(pk, p)
  if pk.kind == "life" then
    p.lives = math.min(5, p.lives + 1)
    burst(pk.x, pk.y, { 1, 0.4, 0.6 }, 20, 150)
  else
    p.shield = 8
    burst(pk.x, pk.y, { 0.4, 0.9, 1 }, 20, 150)
  end
  Audio.play("pickup", 0)
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
  [2] = "DRONES SHOOT BACK!",
  [3] = "GRAB SHIELDS WHEN THEY APPEAR",
  [4] = "NEW ENEMY: SPINNERS",
  [5] = "STARS ARE ON THE MOVE\nEXTRA LIVES ON ODD LEVELS - BE QUICK",
  [6] = "NEW ENEMY: HUNTERS",
}

local function startLevel(n)
  level = n
  starsGot, levelTime = 0, 0
  rocks, bullets, enemies, ebullets, pickups = {}, {}, {}, {}, {}
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

  -- shields from level 3, extra lives on odd levels from 5; each shows up once at a random time
  pickupPlan = {}
  if n >= 3 then pickupPlan[#pickupPlan + 1] = { kind = "shield", at = love.math.random(8, 20) } end
  if n >= 5 and n % 2 == 1 then pickupPlan[#pickupPlan + 1] = { kind = "life", at = love.math.random(6, 18) } end

  for _, s in ipairs(stars) do placeStar(s) end
  if n > 1 then Audio.play("levelup", 0) end
end

local function newGame()
  players = {}
  for i = 1, numPlayers do players[i] = newPlayer(i) end
  stars, particles = {}, {}
  score, shake, level = 0, 0, 1
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
  local speed = 60 + level * 15 + love.math.random() * 50
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
    Scores.refresh()
    state = "over"
  end
end

local function submitEntry()
  Scores.submit(string.char(unpack(entry.letters)), score, level)
  state = "over"
end

local function damagePlayer(p)
  if p.shield > 0 then
    burst(p.x, p.y, { 0.4, 0.9, 1 }, 10, 120)
    Audio.play("deflect")
    return
  end
  burst(p.x, p.y, { 1, 0.5, 0.3 }, 40, 220)
  shake = 0.4
  p.lives = p.lives - 1
  p.hurt = 2
  Audio.play("hurt", 0)
  if p.lives <= 0 then
    p.alive = false
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
  if dx ~= 0 or dy ~= 0 then p.angle = math.atan2(dy, dx) end
  p.thrust = math.sqrt(dx * dx + dy * dy)
  p.dash = math.max(0, p.dash - dt)
  p.dashCd = math.max(0, p.dashCd - dt)
  p.hurt = math.max(0, p.hurt - dt)
  p.cool = math.max(0, p.cool - dt)
  p.shield = math.max(0, p.shield - dt)

  if fireHeld(p) and p.cool <= 0 then
    local g = GUNS[p.gun]
    g.fire(p, p.angle, g.color)
    p.cool = g.rate
    Audio.play(g.sfx)
  end
end

-- returns true if the bullet hit something
local function bulletHits(b)
  for j = #rocks, 1, -1 do
    local r = rocks[j]
    if dist2(r, b) < r.r * r.r then
      r.hp = r.hp - b.dmg
      r.flash = 0.08
      if r.hp <= 0 then destroyRock(j) end
      return true
    end
  end
  for j = #enemies, 1, -1 do
    local e = enemies[j]
    if dist2(e, b) < (e.r + 2) ^ 2 then
      e.hp = e.hp - b.dmg
      e.flash = 0.08
      if e.hp <= 0 then killEnemy(j) end
      return true
    end
  end
  return false
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
  startLevel(level + 1)
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

  -- no spawns while the level banner shows; spawns speed up each level
  if banner > 0 then
    banner = banner - dt
  else
    spawnTimer = spawnTimer - dt
    if spawnTimer <= 0 then
      spawnRock()
      spawnTimer = math.max(0.3, 1.3 - level * 0.12) * (0.7 + love.math.random() * 0.6) / (1 + (numPlayers - 1) * 0.3)
    end
    if level >= 2 then
      enemyTimer = enemyTimer - dt
      if enemyTimer <= 0 then
        if #enemies < math.min(numPlayers + math.floor(level / 2), 7) then spawnEnemy() end
        enemyTimer = math.max(2.5, 8 - level * 0.5) * (0.7 + love.math.random() * 0.6)
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
        if e.hp <= 0 then killEnemy(i) end
        damagePlayer(p)
        if state ~= "play" then return end
      end
    end
  end

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

local function drawPickup(pk)
  -- blink during the last 1.5 seconds
  if pk.t < 1.5 and math.floor(pk.t * 8) % 2 == 0 then return end
  local pulse = 1 + math.sin(pk.t * 8) * 0.12
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
  local status = {}
  if p.shield > 0 then status[#status + 1] = "SHIELD " .. math.ceil(p.shield) end
  if p.dashCd <= 0 then status[#status + 1] = "DASH" end
  love.graphics.setColor(0.5, 0.85, 1)
  line(table.concat(status, "  "), H - 46)
end

local function drawHud()
  love.graphics.setFont(fontSmall)
  love.graphics.setColor(1, 1, 1)
  love.graphics.printf("LV " .. level .. "    " .. score, 0, 6, W, "center")
  love.graphics.setColor(1, 1, 1, 0.5)
  love.graphics.setFont(fontTiny)
  love.graphics.printf("BEST " .. best, 0, 40, W - 12, "right")

  -- level progress bar
  local frac = starsGot / starsNeeded()
  love.graphics.setColor(1, 1, 1, 0.15)
  love.graphics.rectangle("fill", 12, 30, W - 24, 3)
  love.graphics.setColor(1, 0.85, 0.2)
  love.graphics.rectangle("fill", 12, 30, (W - 24) * frac, 3)

  for _, p in ipairs(players) do drawPlayerHud(p) end
end

local function drawWorld()
  love.graphics.clear(0.04, 0.04, 0.09)
  for _, b in ipairs(bgstars) do
    love.graphics.setColor(1, 1, 1, b.speed / 60)
    love.graphics.rectangle("fill", b.x, b.y, 1, 1)
  end

  if state == "title" or state == "select" then return end

  for _, s in ipairs(stars) do drawStar(s) end
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

  for _, b in ipairs(bullets) do
    love.graphics.setColor(b.color)
    love.graphics.circle("fill", b.x, b.y, b.homing and 3.5 or 2.5)
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

  love.graphics.setColor(1, 1, 1, 0.8)
  local p2hint = #pads >= 2 and "P2 uses gamepad 2" or "P2: plug in a 2nd gamepad, or arrows + . (fire) / (dash) , (gun)"
  centered("Collect stars to clear levels. Shoot (A)  Dash (B)  Gun (L/R)\n" .. p2hint, 300, fontTiny)
  centered("UP/DOWN choose   START continue", 350, fontSmall)
  love.graphics.setColor(1, 1, 1, 0.5)
  centered("Best: " .. best, 385, fontSmall)
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
  centered(Scores.status == "online" and "WORLD TOP 5" or "TOP 5", 140, fontSmall)
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
  if TEST_SCORES then  -- keep test scores out of the real save folder
    love.filesystem.setIdentity("stardrift-test")
    love.filesystem.remove("scores.txt")
  end
  best = loadBest()
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
function love.joystickremoved() refreshPads() end

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
      players[2].shield = 8
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
    Scores.refresh()
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
    elseif a == "start" or a == "confirm" then
      numPlayers = menuSel
      for _, pk in ipairs(picks) do pk.ready = false end
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
    if a == "start" then state = "play"
    elseif a == "back" then state = "title"
    elseif a == "next" then Audio.toggleMusic() end
  elseif state == "play" and p then
    if a == "start" or a == "back" then state = "pause"
    elseif a == "dash" then tryDash(p)
    elseif a == "next" then switchGun(p, 1)
    elseif a == "prev" then switchGun(p, -1) end
  end
end

local GLOBAL_KEYS = { ["return"] = "start", escape = "back", backspace = "back", m = "music" }
local ENTRY_KEYS = {
  up = "up", down = "down", left = "left", right = "right", ["return"] = "start", kpenter = "start",
  backspace = "dash", escape = "back",
}
local MENU_KEYS = { up = "up", w = "up", down = "down", s = "down", space = "confirm", z = "confirm" }

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
      for _, field in ipairs({ "dash", "prev", "next", "fire", "left", "right" }) do
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
  start = "start", back = "back", a = "confirm", x = "confirm", b = "dash",
  leftshoulder = "prev", rightshoulder = "next", y = "next", dpup = "up", dpdown = "down",
  dpleft = "left", dpright = "right",
}

function love.gamepadpressed(j, button)
  local a = PAD_ACTIONS[button]
  if not a then return end
  -- which player owns this pad
  local id = 1
  if numPlayers == 2 then
    for i, pj in ipairs(pads) do
      if pj == j then id = i end
    end
  end
  action(a, id)
end
