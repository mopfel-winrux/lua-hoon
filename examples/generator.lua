-- coroutine generator (finite sequences)
local co = coroutine.create(function()
  for i = 1, 5 do coroutine.yield(i * i) end
end)

while coroutine.status(co) ~= "dead" do
  local ok, v = coroutine.resume(co)
  if v ~= nil then print(v) end   -- 1  4  9  16  25
end
