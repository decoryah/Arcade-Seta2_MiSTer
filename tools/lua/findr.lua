-- Logs the CPU's reads of an address range, with the frame and the PC (debugging aid).
--   FR_FROM=<hex> FR_TO=<hex>   address range      FR_FRAMES=<n>   exit after this machine frame
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local scr  = mach.screens[":screen"]
local A0, A1 = tonumber(os.getenv("FR_FROM"), 16), tonumber(os.getenv("FR_TO"), 16)
local LAST = tonumber(os.getenv("FR_FRAMES") or "60")
local KEEP = {}
_G.FRKEEP = KEEP
KEEP.tap = sp:install_read_tap(A0, A1, "findr", function(off, data, mask)
  print(string.format("FR frame %d addr %06x data %04x mask %04x pc %06x", scr:frame_number(), off, data & 0xffff, mask & 0xffff,
    cpu.state["PC"].value))
end)
KEEP.n = emu.add_machine_frame_notifier(function()
  if scr:frame_number() >= LAST then mach:exit() end
end)
