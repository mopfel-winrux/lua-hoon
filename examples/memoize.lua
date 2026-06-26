-- A higher-order memoize: wrap any function in a closure that caches results
-- in a private table. Turns naive exponential fib into linear time.
local function memoize(f)
  local cache = {}
  return function(n)
    if cache[n] == nil then cache[n] = f(n) end
    return cache[n]
  end
end

local fib
fib = memoize(function(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)   -- recurses through the memoized version
end)

print(fib(50))
-- 12586269025
