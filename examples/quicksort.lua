-- Recursive quicksort over a table, using closures, ipairs and # length.
local function quicksort(t)
  if #t <= 1 then return t end
  local pivot = t[1]
  local less, more = {}, {}
  for i = 2, #t do
    local x = t[i]
    if x < pivot then less[#less + 1] = x else more[#more + 1] = x end
  end
  local sorted = quicksort(less)
  sorted[#sorted + 1] = pivot
  for _, v in ipairs(quicksort(more)) do sorted[#sorted + 1] = v end
  return sorted
end

print(table.concat(quicksort({5, 2, 8, 1, 9, 3, 7, 4, 6, 0}), ","))
-- 0,1,2,3,4,5,6,7,8,9
