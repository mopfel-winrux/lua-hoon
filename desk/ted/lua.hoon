::  /ted/lua: run a Lua program as a thread.  The program runs as a resumable
::  coroutine; when it calls an effect builtin (sys.wait / sys.flog / ...) it
::  yields, this strand performs the effect and resumes it with the result.
::  Pure programs never yield and just return their stdout.
/-  spider
/+  strandio, lua
=,  strand=strand:spider
^-  thread:spider
|=  arg=vase
=/  m  (strand ,vase)
^-  form:m
=+  !<([~ src=@t] arg)
=/  cs  (thread-init:lua src)
=/  coid=@ud   coid.cs
=/  s=store:lua  s.cs
=/  in=(list value:lua)  ~
|-  ^-  form:m
=/  st   (thread-step:lua coid in s)
=/  res  -.st
=.  s    +.st
?-  -.res
    %done
  =/  ret=@t  ?~(vals.res 'nil' (vcord:lua i.vals.res))
  (pure:m !>(`wall`(snoc out.res (weld "=> " (trip ret)))))
::
    %yield
  ?:  =(tag.res 'wait')
    =/  ms=@  (vnum:lua ?~(args.res [%nil ~] i.args.res))
    ;<  ~  bind:m  (sleep:strandio `@dr`(mul ms (div ~s1 1.000)))
    $(in ~)
  ?:  =(tag.res 'flog')
    =/  msg=@t  (vcord:lua ?~(args.res [%nil ~] i.args.res))
    ;<  ~  bind:m  (flog-text:strandio (trip msg))
    $(in ~)
  ?:  =(tag.res 'now')
    ;<  t=@da  bind:m  get-time:strandio
    $(in ~[`value:lua`[%i (sun:si `@`t)]])
  $(in ~)
==
