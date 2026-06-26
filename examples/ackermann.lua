-- The Ackermann-Péter function: trivial to write, explosively recursive.
-- A(3,n) is computed entirely through nested recursive calls (no loops),
-- so it's a clean stress test of function-call + return overhead.
local function ack(m, n)
  if m == 0 then return n + 1 end
  if n == 0 then return ack(m - 1, 1) end
  return ack(m - 1, ack(m, n - 1))
end

for n = 0, 4 do
  print("A(3," .. n .. ") = " .. ack(3, n))
end
-- A(3,4) = 125, reached via 10307 calls to ack.
