-- basic features
print("hello, " .. "urbit")

-- closures with mutable upvalues
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local next = counter()
print(next(), next(), next())   -- 1  2  3

-- recursion
local function fact(n)
  if n < 2 then return 1 end
  return n * fact(n - 1)
end
print("5! =", fact(5))           -- 5! = 120

-- tables, generic for, stdlib
local t = {}
for i = 1, 5 do t[i] = i * i end
print("#t =", #t)                -- #t = 5
print(table.concat(t, ", "))     -- 1, 4, 9, 16, 25

-- varargs
local function sum(...)
  local s = 0
  for _, v in ipairs({...}) do s = s + v end
  return s
end
print("sum =", sum(1, 2, 3, 4))  -- sum = 10
