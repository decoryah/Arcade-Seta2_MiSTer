-- Logs the 68000's writes to the X1-010 and to the sample bank registers with MAME's time, for the sound bench (sim/snd):
--   X1BASE=<hex> (the chip's 0x4000-byte window)  BANKLO=<hex> BANKHI=<hex> (the bank register range)  OUT=<file>  SECS=<n>
-- Lines: "<time in seconds> x <word offset> <data> <mask>" or "<time> b <bank> <data>".  Run with -wavwrite to get MAME's sound.
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local KEEP = {}
_G.X1KEEP = KEEP
local X1 = tonumber(os.getenv("X1BASE") or "b00000", 16)
local BLO = tonumber(os.getenv("BANKLO") or "e00010", 16)
local BHI = tonumber(os.getenv("BANKHI") or "e0001f", 16)
local SECS = tonumber(os.getenv("SECS") or "20")
local o = assert(io.open(os.getenv("OUT") or "x1.log", "w"))
local function now() return mach.time:as_double() end
KEEP.x = sp:install_write_tap(X1, X1 + 0x3fff, "x1", function(off, data, mask)
  o:write(string.format("%.9f x %04x %04x %04x\n", now(), (off - X1) >> 1, data & 0xffff, mask & 0xffff))
end)
KEEP.b = sp:install_write_tap(BLO, BHI, "bank", function(off, data, mask)
  if (mask & 0x00ff) ~= 0 then
    o:write(string.format("%.9f b %d %02x\n", now(), ((off - BLO) >> 1) & 7, data & 0xff))
  end
end)
KEEP.n = emu.add_machine_frame_notifier(function()
  if now() >= SECS then o:close(); mach:exit() end
end)
