-- An INFINITE prime generator as a coroutine, driven lazily on demand.
-- This only works because yield genuinely suspends the while-loop mid-flight
-- and keeps the generator's state (`found`, `n`) alive between resumes.
local function gen_primes()
  local found = {}
  local n = 2
  while true do
    local is_prime = true
    for _, p in ipairs(found) do
      if p * p > n then break end
      if n % p == 0 then is_prime = false break end
    end
    if is_prime then
      found[#found + 1] = n
      coroutine.yield(n)
    end
    n = n + 1
  end
end

local co = coroutine.create(gen_primes)
local out = {}
for i = 1, 15 do
  local _, p = coroutine.resume(co)
  out[i] = p
end
print(table.concat(out, " "))
-- 2 3 5 7 11 13 17 19 23 29 31 37 41 43 47
