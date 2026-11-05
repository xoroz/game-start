function love.conf(t)
  t.identity = "stardrift"          -- save folder name
  t.version = "11.5"
  t.window.title = "Star Drift"
  t.window.width = 640
  t.window.height = 480
  t.window.resizable = true
  t.window.vsync = 1
  t.modules.physics = false         -- not needed, saves memory on handheld
  t.modules.video = false
end
