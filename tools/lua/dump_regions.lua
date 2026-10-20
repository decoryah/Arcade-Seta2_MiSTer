-- Writes every ROM region of the running set as MAME loaded it (raw bytes), to check tools/seta2_rom.py's images against.
--   REGDIR=<dir>   output directory (default: current); files <region>.bin
local regs = manager.machine.memory.regions
local dir  = os.getenv("REGDIR") or "."
for tag, r in pairs(regs) do
  -- only the driver's own regions (":maincpu", ":video", ":x1snd", ":eeprom"...), not the devices' internal ones
  if tag:match("^:[%w_]+$") then
    local name = tag:sub(2)
    local f = assert(io.open(dir .. "/" .. name .. ".bin", "wb"))
    local n = r.size
    local CH = 65536
    for base = 0, n - 1, CH do
      local t = {}
      local last = math.min(CH, n - base)
      for i = 0, last - 1 do t[i + 1] = string.char(r:read_u8(base + i)) end
      f:write(table.concat(t))
    end
    f:close()
    print(string.format("REGION %s size=%d", tag, n))
  end
end
print("REGIONS_DUMPED")
manager.machine:exit()
