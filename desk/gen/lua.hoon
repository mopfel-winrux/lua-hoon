::  +lua 'print(1 + 2)'  — run a Lua source string, print its stdout
::
::    each output line is rendered as a tank leaf; control characters
::    (e.g. the tab `print` inserts between arguments) are shown as
::    spaces so the dojo's tank printer accepts them.
::
/+  lua
:-  %say
|=  [* [src=@t ~] ~]
:-  %tang
%-  flop
%+  turn  (run:lua src)
|=  l=tape
^-  tank
leaf+(turn l |=(c=@tD ?:((lth c 32) ' ' c)))
