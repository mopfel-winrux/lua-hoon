-- A Lua program meant to run as an Urbit THREAD via /ted/lua.hoon.
--
-- The `sys` table performs real strand effects. Each call suspends this
-- program (it runs as one coroutine on the resumable evaluator) and hands an
-- effect request to a Hoon strand, which performs it and resumes us with the
-- result:
--   sys.wait(ms) -- sleep `ms` milliseconds on the behn timer vane
--   sys.flog(s)  -- print a line to the dojo, live
--   sys.now()    -- read the current time (@da) back into Lua
--
-- Run it (single line) from the dojo:
--   -lua 'sys.flog("hi") sys.wait(1000) return "done at "..sys.now()'

sys.flog("counting down...")
for i = 3, 1, -1 do
  sys.flog(i .. "...")
  sys.wait(1000)          -- really sleeps one second between lines
end
sys.flog("liftoff! t=" .. sys.now())
return "launched"
