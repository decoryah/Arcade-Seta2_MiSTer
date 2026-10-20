-- Logs the writes of one value to a CPU address range, with the frame and the PC of the writing instruction (debugging aid).
--   FW_FROM=<hex> FW_TO=<hex>   address range      FW_DATA=<hex>   the value (16-bit, after the mask)
--   FW_FRAMES=<n>               exit after this machine frame
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local scr  = mach.screens[":screen"]
local A0, A1 = tonumber(os.getenv("FW_FROM"), 16), tonumber(os.getenv("FW_TO"), 16)
local DATA = tonumber(os.getenv("FW_DATA"), 16)
local LAST = tonumber(os.getenv("FW_FRAMES") or "60")
local KEEP = {}
_G.FWKEEP = KEEP
KEEP.tap = sp:install_write_tap(A0, A1, "findw", function(off, data, mask)
  if (data & mask & 0xffff) == (DATA & mask) then
    print(string.format("FW frame %d addr %06x data %04x mask %04x pc %06x", scr:frame_number(), off, data & 0xffff, mask & 0xffff,
      cpu.state["PC"].value))
    print(string.format("FW   A0 %08x A1 %08x D0 %08x A6 %08x", cpu.state["A0"].value, cpu.state["A1"].value, cpu.state["D0"].value, cpu.state["A6"].value))
  end
end)
KEEP.n = emu.add_machine_frame_notifier(function()
  if scr:frame_number() >= LAST then mach:exit() end
end)
