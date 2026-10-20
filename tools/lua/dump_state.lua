-- Freezes frames of the seta2.cpp games and writes everything the reference renderer (tools/seta2_ref.py) needs, together with
-- the exact pixels MAME drew from that state (screen:pixels()).
--
--   DUMPFRAMES=<f,f,f...>  machine frames to capture (also ranges "a-b/s")
--   DUMPDIR=<dir>          output directory
--   VBASE=<hex>            CPU address of the video chip's sprite RAM (its palette is at +0x40000, its registers at +0x60000)
--                          (penbros: sprite RAM b00000, palette b40000, registers b60000: the same offsets)
--   SCHEDULE=play|none     scripted inputs: coin / start / random joystick and buttons (default none)
--   SEED=<n>, COIN_FRAME=<n>, START_FRAME=<n>, PLAY_FRAME=<n>   (defaults 12345, 200, 260, 330)
--   PRESS="<frame>,<what>;..."  single presses (below), with or without --play
--   EVLOG=<file>           log of the events the hardware model needs: video register writes, TMP68301 register writes,
--                          with frame, screen line and dot ("frame vpos hpos addr data mask")
--
-- For every captured frame <N> (the notifier runs at the start of the vertical blank, just before MAME draws the frame):
--   f<N>.spr    sprite RAM, 0x40000 bytes: 0x20000 words, each little-endian (as read_range packs them)
--   f<N>.pal    palette RAM, 0x10000 bytes: 0x8000 words, little-endian
--   f<N>.vr     video registers, 0x40 bytes: 0x20 words, little-endian
--   f<N>.lst    the display list (sprite RAM 0x3000-0x3fff) as it was at the last write of a non-zero value to register
--               0x24 or 0x26 (the copy MAME makes there), 0x800 words little-endian; absent if no such write happened yet
--   f<N>.txt    frame, the frame / line / dot of that write, the screen size
--   f<N>.rgb    the frame MAME drew from exactly this state, width x height x 3 bytes (read one notifier later)
--   f<N>.pal1   the palette one notifier later (MAME turns pens into colours when the pixels are read)
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local KEEP = {}
_G.DUMPKEEP = KEEP

local DIR   = os.getenv("DUMPDIR") or "."
local VBASE = tonumber(os.getenv("VBASE") or "c00000", 16)
local PBASE = VBASE + 0x40000
local RBASE = VBASE + 0x60000

local function absframe()
  return scr:frame_number()
end
local f = absframe()

-- The raster position in MAME's model of these boards: 0x200 x 0x100 (seta2's set_size), vblank begins after the last visible
-- line (screen.height).  screen:vpos() / hpos() do not exist in MAME 0.289's Lua; worked out the same way as the owner's
-- Snow Bros / Heavy Unit captures.
local T_FRAME = scr.frame_period
local T_SCAN  = T_FRAME / 256
local VIS_H   = scr.height
local function raster_now()
  local tv = scr:time_until_vblank_start():as_double()
  local t = (VIS_H * T_SCAN - tv) % T_FRAME
  local l = t / T_SCAN + 1e-9
  local v = math.floor(l)
  return v, math.floor((l - v) * 512)
end
-- an error inside a tap callback is swallowed by MAME and the tap goes quiet, so report the first few
local tap_err = 0
local function guarded(fn)
  return function(off, data, mask)
    local ok, e = pcall(fn, off, data, mask)
    if not ok and tap_err < 5 then tap_err = tap_err + 1; print("[seta2] tap error: " .. tostring(e)) end
  end
end

local evlog
if os.getenv("EVLOG") then evlog = assert(io.open(os.getenv("EVLOG"), "w")) end

-- the display list at the last list copy (register 0x26, or 0x24 as funcube3 / staraudi use)
local lst, lst_when = nil, "none"
KEEP.t1 = sp:install_write_tap(RBASE, RBASE + 0x3f, "vregs", guarded(function(off, data, mask)
  local r = off - RBASE
  local v, h = raster_now()
  if (r & 0x3e) == 0x26 or (r & 0x3e) == 0x24 then
    if (data & mask) ~= 0 then
      lst = sp:read_range(VBASE + 0x3000, VBASE + 0x3fff, 16, 2)
      lst_when = string.format("%d %d %d", f, v, h)
    end
  end
  if evlog then evlog:write(string.format("%d %d %d v %06x %04x %04x\n", f, v, h, off, data & 0xffff, mask & 0xffff)) end
end))
-- WLOG=<file> WLOGFROM=<f> WLOGTO=<f>: every write to the video chip's window (sprite RAM, palette, registers) in those frames,
-- "f v h offset data mask" (offset from VBASE), for tools/seta2_replay.py
local wlog
local WFROM, WTO = tonumber(os.getenv("WLOGFROM") or "-1"), tonumber(os.getenv("WLOGTO") or "-1")
if os.getenv("WLOG") then
  wlog = assert(io.open(os.getenv("WLOG"), "w"))
  KEEP.t3 = sp:install_write_tap(VBASE, VBASE + 0x7ffff, "vwin", guarded(function(off, data, mask)
    if f >= WFROM and f <= WTO then
      local v, h = raster_now()
      wlog:write(string.format("%d %d %d %05x %04x %04x\n", f, v, h, off - VBASE, data & 0xffff, mask & 0xffff))
    end
  end))
end
if evlog then
  KEEP.t2 = sp:install_write_tap(0xfffc00, 0xffffff, "tmp68301", guarded(function(off, data, mask)
    local v, h = raster_now()
    evlog:write(string.format("%d %d %d t %06x %04x %04x\n", f, v, h, off, data & 0xffff, mask & 0xffff))
  end))
end

-- frame list
local FRAMES = {}
local LAST = 0
for item in string.gmatch(os.getenv("DUMPFRAMES") or "300", "[^,]+") do
  local a, b, s = string.match(item, "^(%d+)%-(%d+)/(%d+)$")
  if a then
    for n = tonumber(a), tonumber(b), tonumber(s) do FRAMES[n] = true; if n > LAST then LAST = n end end
  else
    local n = tonumber(item); FRAMES[n] = true; if n > LAST then LAST = n end
  end
end

local function wbin(path, s)
  local o = assert(io.open(path, "wb")); o:write(s); o:close()
end

-- screen:pixels() is 32-bit ARGB, little-endian (bytes B, G, R, A)
local pending
local function dump_pixels(path)
  local px = scr:pixels()
  local out = {}
  local n = #px // 4
  for i = 0, n - 1 do
    local b, g, r = px:byte(i * 4 + 1, i * 4 + 3)
    out[i + 1] = string.char(r, g, b)
  end
  wbin(path, table.concat(out))
end

local function dump()
  local pre = string.format("%s/f%05d", DIR, f)
  wbin(pre .. ".spr", sp:read_range(VBASE, VBASE + 0x3ffff, 16, 2))
  wbin(pre .. ".pal", sp:read_range(PBASE, PBASE + 0xffff, 16, 2))
  wbin(pre .. ".vr",  sp:read_range(RBASE, RBASE + 0x3f, 16, 2))
  if lst then wbin(pre .. ".lst", lst) end
  local o = assert(io.open(pre .. ".txt", "w"))
  o:write(string.format("frame %d\nlistcopy %s\nscreen %d %d\n", f, lst_when, scr.width, scr.height))
  o:close()
  pending = pre
end

-- scripted inputs: find the fields by name in whatever port holds them
local function find_field(fname)
  for pname, p in pairs(mach.ioport.ports) do
    for name, fld in pairs(p.fields) do
      if name == fname then return fld end
    end
  end
  return nil
end
local coin, start = find_field("Coin 1"), find_field("1 Player Start")
local up, dn, lf, rt = find_field("P1 Up"), find_field("P1 Down"), find_field("P1 Left"), find_field("P1 Right")
local btn = { find_field("P1 Button 1"), find_field("P1 Button 2"), find_field("P1 Button 3"), find_field("P1 Button 4") }
local SCHED       = os.getenv("SCHEDULE") or "none"
local COIN_FRAME  = tonumber(os.getenv("COIN_FRAME") or "200")
local START_FRAME = tonumber(os.getenv("START_FRAME") or "260")
local PLAY_FRAME  = tonumber(os.getenv("PLAY_FRAME") or "330")
local rng = tonumber(os.getenv("SEED") or "12345")
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local dir = 0
-- PRESS="<frame>,<what>;...": each <what> (1..4 buttons, U D L R, S start, C coin) held for 6 frames from <frame> (any schedule)
local PRESS = {}
for item in string.gmatch(os.getenv("PRESS") or "", "[^;]+") do
  local pf, what = item:match("(%d+),(%w+)")
  if pf then PRESS[#PRESS + 1] = { tonumber(pf), what } end
end
local function setv(fld, on) if fld then fld:set_value(on and 1 or 0) end end

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = absframe()
  if pending then
    dump_pixels(pending .. ".rgb")
    wbin(pending .. ".pal1", sp:read_range(PBASE, PBASE + 0xffff, 16, 2))
    print("DUMPED " .. pending)
    io.stdout:flush()
    pending = nil
  end
  if SCHED == "play" then
    setv(coin,  (f >= COIN_FRAME) and ((f - COIN_FRAME) % 1800 < 6))
    setv(start, (f >= START_FRAME) and ((f - START_FRAME) % 1800 < 6))
    if f >= PLAY_FRAME then
      if f % 10 == 0 then dir = rnd(5) end
      setv(up, dir == 1); setv(dn, dir == 2); setv(lf, dir == 3); setv(rt, dir == 4)
      setv(btn[1], f % 23 < 5); setv(btn[2], f % 37 < 4); setv(btn[3], f % 53 < 3); setv(btn[4], f % 71 < 3)
    end
  end
  if #PRESS > 0 then
    local h = {}
    for _, pr in ipairs(PRESS) do if f >= pr[1] and f < pr[1] + 6 then h[pr[2]] = true end end
    setv(coin, h.C); setv(start, h.S); setv(up, h.U); setv(dn, h.D); setv(lf, h.L); setv(rt, h.R)
    for k = 1, 4 do setv(btn[k], h[tostring(k)]) end
  end
  if FRAMES[f] then dump() end
  if f >= LAST + 1 and not pending then
    if evlog then evlog:close() end
    if wlog then wlog:close() end
    mach:exit()
  end
end)
