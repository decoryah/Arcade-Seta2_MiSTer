-- Which RAM the game really uses: per 1 KB block of the given ranges, the CPU's reads and writes (counts), so the core can
-- decide what needs block RAM.  Plays the scripted inputs of dump_state.lua (coin 200, start 260, random from 330).
--   RANGES=<lo-hi,lo-hi,...> (hex CPU addresses)   FRAMES=<n>   OUT=<file>
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local KEEP = {}
_G.RAMKEEP = KEEP
local OUT = os.getenv("OUT") or "ramuse.txt"
local LAST = tonumber(os.getenv("FRAMES") or "3600")
local rd, wr, first = {}, {}, {}
local f = 0
for item in string.gmatch(os.getenv("RANGES") or "", "[^,]+") do
  local lo, hi = string.match(item, "^(%x+)%-(%x+)$")
  lo, hi = tonumber(lo, 16), tonumber(hi, 16)
  KEEP[#KEEP + 1] = sp:install_read_tap(lo, hi, "r" .. lo, function(off, data, mask)
    local b = off >> 10; rd[b] = (rd[b] or 0) + 1; return data
  end)
  KEEP[#KEEP + 1] = sp:install_write_tap(lo, hi, "w" .. lo, function(off, data, mask)
    local b = off >> 10; wr[b] = (wr[b] or 0) + 1
    if first[b] == nil then first[b] = f end
  end)
end
local function find_field(fname)
  for pname, p in pairs(mach.ioport.ports) do
    for name, fld in pairs(p.fields) do if name == fname then return fld end end
  end
end
local coin, start = find_field("Coin 1"), find_field("1 Player Start")
local up, dn, lf, rt = find_field("P1 Up"), find_field("P1 Down"), find_field("P1 Left"), find_field("P1 Right")
local b1, b2, b3 = find_field("P1 Button 1"), find_field("P1 Button 2"), find_field("P1 Button 3")
local rng, dir = 12345, 0
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local function setv(fld, on) if fld then fld:set_value(on and 1 or 0) end end
KEEP.n = emu.add_machine_frame_notifier(function()
  f = scr:frame_number()
  setv(coin, f >= 200 and (f - 200) % 1800 < 6); setv(start, f >= 260 and (f - 260) % 1800 < 6)
  if f >= 330 then
    if f % 10 == 0 then dir = rnd(5) end
    setv(up, dir == 1); setv(dn, dir == 2); setv(lf, dir == 3); setv(rt, dir == 4)
    setv(b1, f % 23 < 5); setv(b2, f % 37 < 4); setv(b3, f % 53 < 3)
  end
  if f >= LAST then
    local o = assert(io.open(OUT, "w"))
    local keys = {}
    for b, _ in pairs(rd) do keys[b] = true end
    for b, _ in pairs(wr) do keys[b] = true end
    local list = {}
    for b, _ in pairs(keys) do list[#list + 1] = b end
    table.sort(list)
    for _, b in ipairs(list) do
      o:write(string.format("%06x %9d %9d %d\n", b << 10, rd[b] or 0, wr[b] or 0, first[b] or -1))
    end
    o:close()
    mach:exit()
  end
end)
