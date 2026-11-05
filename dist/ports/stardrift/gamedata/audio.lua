-- Procedural audio: every sound and the music loop are synthesized at startup,
-- so the port ships no audio files.

local Audio = {}

local RATE = 22050
local sounds = {}      -- name -> { sources = {...}, next = 1 }
local music
local musicOn = true

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function midi(m) return 440 * 2 ^ ((m - 69) / 12) end

local function square(p) return (p % 1) < 0.5 and 1 or -1 end
local function tri(p) return 4 * math.abs(p % 1 - 0.5) - 1 end
local function noise() return love.math.random() * 2 - 1 end

-- fill a SoundData by calling fn(t, u) per sample, u = 0..1 progress
local function render(dur, fn)
  local n = math.floor(dur * RATE)
  local sd = love.sound.newSoundData(n, RATE, 16, 1)
  for i = 0, n - 1 do
    local t = i / RATE
    sd:setSample(i, clamp(fn(t, t / dur), -1, 1))
  end
  return sd
end

-- pitch sweep from f0 to f1 with a decaying envelope
local function sweep(f0, f1, dur, wave, vol)
  local phase = 0
  return render(dur, function(_, u)
    phase = phase + (f0 + (f1 - f0) * u) / RATE
    return wave(phase) * vol * (1 - u) ^ 1.5
  end)
end

-- low-passed noise burst; lower k = deeper rumble
local function boom(dur, k, vol)
  local y = 0
  return render(dur, function(_, u)
    y = y + (noise() - y) * k
    return y * vol * (1 - u) ^ 2
  end)
end

-- quick note sequence, each note with its own short decay
local function arp(notes, step, wave, vol)
  local phase = 0
  return render(#notes * step, function(t)
    local i = math.min(#notes, math.floor(t / step) + 1)
    local within = (t - (i - 1) * step) / step
    phase = phase + midi(notes[i]) / RATE
    return wave(phase) * vol * (1 - within * 0.7)
  end)
end

local function add(name, sd, poolSize, volume)
  local base = love.audio.newSource(sd, "static")
  base:setVolume(volume or 1)
  local s = { sources = { base }, next = 1 }
  for _ = 2, poolSize or 3 do s.sources[#s.sources + 1] = base:clone() end
  sounds[name] = s
end

-- 64-step loop: bass + arpeggio lead + hats over Am - F - C - G
local function makeMusic()
  local stepDur = 0.14
  local chords = {
    { root = 45, tones = { 69, 72, 76 } },
    { root = 41, tones = { 65, 69, 72 } },
    { root = 48, tones = { 72, 76, 79 } },
    { root = 43, tones = { 67, 71, 74 } },
  }
  local bassPat = { 0, 0, 12, 0, 7, 0, 12, 7 }
  local leadPats = { { 1, 0, 2, 0, 3, 2, 0, 1 }, { 3, 0, 2, 1, 0, 2, 3, 0 } }
  local bassPh, leadPh, hat = 0, 0, 0
  return render(64 * stepDur, function(t)
    local step = math.floor(t / stepDur)                -- 0..63
    local within = (t - step * stepDur) / stepDur
    local chord = chords[math.floor(step / 8) % 4 + 1]
    local half = math.floor(step / 32) + 1
    local s8 = step % 8 + 1

    bassPh = bassPh + midi(chord.root + bassPat[s8]) / RATE
    local out = tri(bassPh) * 0.35 * (1 - within * 0.5)

    local li = leadPats[half][s8]
    if li > 0 then
      leadPh = leadPh + midi(chord.tones[li]) / RATE
      out = out + square(leadPh) * 0.08 * math.exp(-within * 4)
    end

    if step % 2 == 1 then
      hat = hat + (noise() - hat) * 0.9
      out = out + hat * 0.06 * math.exp(-within * 18)
    end
    return out
  end)
end

function Audio.load()
  add("blaster", sweep(900, 400, 0.08, square, 0.25), 4)
  add("spread", sweep(600, 250, 0.12, square, 0.25), 3)
  add("rapid", sweep(1300, 900, 0.04, square, 0.15), 6)
  add("homing", sweep(300, 700, 0.16, tri, 0.4), 3)
  add("enemyShot", sweep(420, 180, 0.12, square, 0.18), 6)
  add("boomSmall", boom(0.18, 0.5, 0.6), 4)
  add("boom", boom(0.45, 0.25, 0.9), 3)
  add("hurt", sweep(240, 50, 0.45, square, 0.35), 2)
  add("deflect", sweep(1400, 500, 0.1, tri, 0.4), 3)
  add("star", arp({ 81, 85, 88 }, 0.045, square, 0.18), 3)
  add("pickup", arp({ 72, 76, 79, 84, 88 }, 0.05, tri, 0.45), 2)
  add("appear", sweep(500, 1200, 0.25, tri, 0.25), 2)
  add("dash", sweep(200, 900, 0.12, tri, 0.3), 2)
  add("levelup", arp({ 69, 72, 76, 81, 76, 81, 88 }, 0.08, square, 0.2), 1)
  add("gameover", arp({ 69, 65, 62, 57 }, 0.18, square, 0.2), 1)

  music = love.audio.newSource(makeMusic(), "static")
  music:setLooping(true)
  music:setVolume(0.45)
end

-- play a pooled copy so overlapping sounds don't cut each other off
function Audio.play(name, pitchVariance)
  local s = sounds[name]
  if not s then return end
  local src = s.sources[s.next]
  s.next = s.next % #s.sources + 1
  src:stop()
  src:setPitch(1 + (love.math.random() - 0.5) * (pitchVariance or 0.1))
  src:play()
end

function Audio.startMusic()
  if musicOn then music:play() end
end

function Audio.toggleMusic()
  musicOn = not musicOn
  if musicOn then music:play() else music:pause() end
end

return Audio
