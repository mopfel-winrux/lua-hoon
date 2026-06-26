-- OOP via metatables
local Animal = {}
Animal.__index = Animal

function Animal.new(name, sound)
  return setmetatable({name = name, sound = sound}, Animal)
end
function Animal:speak()
  return self.name .. " says " .. self.sound
end

local dog = Animal.new("Rex", "woof")
print(dog:speak())              -- Rex says woof

-- operator overloading
local Vec = {}
Vec.__index = Vec
Vec.__add = function(a, b) return setmetatable({a[1]+b[1], a[2]+b[2]}, Vec) end
Vec.__tostring = function(v) return "(" .. v[1] .. ", " .. v[2] .. ")" end
local v = setmetatable({1, 2}, Vec) + setmetatable({3, 4}, Vec)
print(tostring(v))              -- (4, 6)
