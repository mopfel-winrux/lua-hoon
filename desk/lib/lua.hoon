::  lua.hoon — a pragmatic-core Lua 5.4 interpreter in Hoon
::
::    a hand-written lexer + recursive-descent parser + tree-walking
::    interpreter.  numbers are int (@sd) or float (@rd) per Lua 5.4.
::    tables and variables are mutable via a shared store keyed by id;
::    closures capture lexical scope so upvalues work.
::
::    public arm:  (run src=@t) -> (list tape)   :: stdout lines
::
|%
::                                                ::  ::  types
+$  number  $%([%i p=@sd] [%f p=@rd])
+$  token
  $%  [%name p=@t]
      [%kw p=@t]
      [%num n=number]
      [%str p=@t]
      [%op p=@t]
      [%eof ~]
  ==
::    NOTE: recursive child positions use `*` (untyped noun) instead of a
::    direct self-reference, because this kernel's compiler crashes
::    (dig:over) on ?-/?= over a directly-recursive $%.  arms clam these
::    nouns back to the typed mold with `;;` before pattern-matching.
+$  tfield
  $%  [%pos v=*]
      [%key k=* v=*]
      [%name n=@t v=*]
  ==
+$  expr
  $%  [%nil ~]
      [%true ~]
      [%false ~]
      [%int p=@sd]
      [%flt p=@rd]
      [%str p=@t]
      [%vararg ~]
      [%name p=@t]
      [%paren e=*]
      [%index t=* k=*]
      [%call f=* args=(list *)]
      [%method o=* m=@t args=(list *)]
      [%func params=(list @t) vararg=? body=*]
      [%table fields=(list *)]
      [%binop op=@t l=* r=*]
      [%unop op=@t e=*]
  ==
+$  stmt
  $%  [%local names=(list @t) exprs=(list *)]
      [%localfunc name=@t f=*]
      [%assign targets=(list *) exprs=(list *)]
      [%call e=*]
      [%do body=*]
      [%while c=* body=*]
      [%repeat body=* c=*]
      [%if clauses=(list [c=* b=*]) els=(unit *)]
      [%numfor v=@t from=* to=* step=(unit *) body=*]
      [%genfor names=(list @t) exprs=(list *) body=*]
      [%return exprs=(list *)]
      [%break ~]
  ==
+$  block  (list *)
::
+$  value
  $%  [%nil ~]
      [%b p=?]
      [%i p=@sd]
      [%f p=@rd]
      [%s p=@t]
      [%t id=@ud]
      [%c id=@ud]
      [%fn p=@tas]
  ==
+$  vkey  $%([%i p=@sd] [%f p=@rd] [%s p=@t] [%b p=?])
+$  ltable  (map vkey value)
+$  closure  [params=(list @t) vararg=? body=(list stmt) env=scope]
+$  frame  (map @t @ud)
+$  scope  (list frame)
+$  flow   $%([%norm ~] [%brk ~] [%ret vs=(list value)])
+$  store
  $:  cells=(map @ud value)
      tabs=(map @ud ltable)
      funs=(map @ud closure)
      glob=(map @t value)
      next=@ud
      out=(list tape)
  ==
::                                                ::  ::  char predicates
++  dig  |=(c=@ &((gte c '0') (lte c '9')))
++  hek
  |=  c=@
  ?|  (dig c)
      &((gte c 'a') (lte c 'f'))
      &((gte c 'A') (lte c 'F'))
  ==
++  alf
  |=  c=@
  ?|  &((gte c 'a') (lte c 'z'))
      &((gte c 'A') (lte c 'Z'))
      =(c '_')
  ==
++  aln  |=(c=@ |((alf c) (dig c)))
++  up-char  |=(c=@ ?:(&((gte c 'a') (lte c 'z')) (sub c 32) c))
++  low-char  |=(c=@ ?:(&((gte c 'A') (lte c 'Z')) (add c 32) c))
::                                                ::  ::  numeric helpers
++  i2f
  |=  i=@sd
  ^-  @rd
  ?:  (syn:si i)  (sun:rd (abs:si i))
  (sub:rd .~0 (sun:rd (abs:si i)))
++  toflt
  |=  v=value
  ^-  @rd
  ?:  ?=(%i -.v)  (i2f p.v)
  ?>(?=(%f -.v) p.v)
++  rlte  |=([a=@rd b=@rd] !(lth:rd b a))
++  rgte  |=([a=@rd b=@rd] !(lth:rd a b))
++  sle  |=([a=@sd b=@sd] !=(--1 (cmp:si a b)))
++  sge  |=([a=@sd b=@sd] !=(-1 (cmp:si a b)))
++  powten
  |=  n=@ud
  ^-  @rd
  ?:  =(n 0)  .~1
  (mul:rd .~10 (powten (dec n)))
++  base-val
  |=  [b=@ t=tape]
  ^-  @
  (roll t |=([c=@ a=@] (add (mul a b) (dval c))))
++  dval
  |=  c=@
  ^-  @
  ?:  (dig c)  (sub c '0')
  ?:  &((gte c 'a') (lte c 'f'))  (add 10 (sub c 'a'))
  (add 10 (sub c 'A'))
++  ffloor
  |=  x=@rd
  ^-  @rd
  =/  u  (toi:rd x)
  ?~  u  x
  =/  t  (i2f u.u)
  ?:  (rlte t x)  t
  (sub:rd t .~1)
++  powrd
  |=  [x=@rd y=@rd]
  ^-  @rd
  =/  u  (toi:rd y)
  ?~  u  ~|(%frac-power-unsupported !!)
  ?.  (equ:rd y (i2f u.u))  ~|(%frac-power-unsupported !!)
  =/  neg=?  !(syn:si u.u)
  =/  k=@ud  (abs:si u.u)
  =/  r=@rd  .~1
  =.  r
    |-  ^-  @rd
    ?:  =(k 0)  r
    $(r (mul:rd r x), k (dec k))
  ?:(neg (div:rd .~1 r) r)
++  ifloordiv
  |=  [a=@sd b=@sd]
  ^-  @sd
  ?:  =(b --0)  ~|(%integer-divide-by-zero !!)
  =/  qt  (fra:si a b)
  =/  rt  (rem:si a b)
  ?:  ?&(!=(rt --0) !=((syn:si a) (syn:si b)))
    (dif:si qt --1)
  qt
++  imod
  |=  [a=@sd b=@sd]
  ^-  @sd
  ?:  =(b --0)  ~|(%integer-modulo-by-zero !!)
  =/  q  (ifloordiv a b)
  (dif:si a (pro:si q b))
::                                                ::  ::  number formatting
++  fmt-int
  |=  i=@sd
  ^-  tape
  ::  scow %ud groups digits with dots (12.502.500); Lua wants plain digits
  =/  d  (skip (scow %ud (abs:si i)) |=(c=@ =(c '.')))
  ?:((syn:si i) d (weld "-" d))
++  fmt-flt
  |=  f=@rd
  ^-  tape
  =/  t  (slag 2 (scow %rd f))
  ?:  (lien t |=(c=@ |(=(c '.') =(c 'e') =(c 'E'))))
    t
  (weld t ".0")
::                                                ::  ::  lexer
++  keywords
  ^-  (set @t)
  %-  silt
  ^-  (list @t)
  :~  'and'  'break'  'do'  'else'  'elseif'  'end'  'false'  'for'
      'function'  'goto'  'if'  'in'  'local'  'nil'  'not'  'or'
      'repeat'  'return'  'then'  'true'  'until'  'while'
  ==
++  take-while
  |=  [t=tape pred=$-(@ ?)]
  ^-  [p=tape q=tape]
  =/  acc=tape  ~
  |-  ^-  [p=tape q=tape]
  ?:  &(?=(^ t) (pred i.t))  $(acc [i.t acc], t t.t)
  [(flop acc) t]
++  skip-line
  |=  t=tape
  ^-  tape
  ?~  t  t
  ?:  =(i.t 10)  t
  $(t t.t)
++  skip-long
  |=  t=tape
  ^-  tape
  ?~  t  t
  ?:  &(=(i.t ']') ?=(^ t.t) =(i.t.t ']'))  t.t.t
  $(t t.t)
++  esc
  |=  e=@
  ^-  @
  ?:  =(e 'n')  10
  ?:  =(e 't')  9
  ?:  =(e 'r')  13
  ?:  =(e 'a')  7
  ?:  =(e 'b')  8
  ?:  =(e 'f')  12
  ?:  =(e 'v')  11
  ?:  =(e '0')  0
  e
++  lex
  |=  src=tape
  ^-  (list token)
  =/  acc=(list token)  ~
  |-  ^-  (list token)
  ?~  src  (flop ^-((list token) [[%eof ~] acc]))
  =/  c=@  i.src
  ?:  ?|(=(c ' ') =(c 9) =(c 10) =(c 13))
    $(src t.src)
  ?:  &(=(c '-') ?=(^ t.src) =(i.t.src '-'))
    =/  r  t.t.src
    ?:  &(?=(^ r) =(i.r '[') ?=(^ t.r) =(i.t.r '['))
      $(src (skip-long t.t.r))
    $(src (skip-line r))
  ?:  |(=(c '"') =(c 39))
    =/  res  (lex-str src)
    $(acc [tok.res acc], src nex.res)
  ?:  &(=(c '[') ?=(^ t.src) =(i.t.src '['))
    =/  res  (lex-long src)
    $(acc [tok.res acc], src nex.res)
  ?:  |((dig c) &(=(c '.') ?=(^ t.src) (dig i.t.src)))
    =/  res  (lex-num src)
    $(acc [tok.res acc], src nex.res)
  ?:  (alf c)
    =/  res  (lex-name src)
    $(acc [tok.res acc], src nex.res)
  =/  res  (lex-op src)
  $(acc [tok.res acc], src nex.res)
::
++  lex-str
  |=  src=tape
  ^-  [tok=token nex=tape]
  ?~  src  ~|(%lex-empty !!)
  =/  q=@  i.src
  =/  rest=tape  t.src
  =/  acc=tape  ~
  |-  ^-  [tok=token nex=tape]
  ?~  rest  ~|(%unterminated-string !!)
  ?:  =(i.rest q)  [[%str (crip (flop acc))] t.rest]
  ?:  =(i.rest 92)
    ?~  t.rest  ~|(%bad-escape !!)
    $(acc [(esc i.t.rest) acc], rest t.t.rest)
  $(acc [i.rest acc], rest t.rest)
::
++  lex-long
  |=  src=tape
  ^-  [tok=token nex=tape]
  ?~  src  ~|(%lex-empty !!)
  ?~  t.src  ~|(%lex-empty !!)
  =/  rest  t.t.src
  =.  rest  ?:(&(?=(^ rest) =(i.rest 10)) t.rest rest)
  =/  acc=tape  ~
  |-  ^-  [tok=token nex=tape]
  ?~  rest  ~|(%unterminated-long-string !!)
  ?:  &(=(i.rest ']') ?=(^ t.rest) =(i.t.rest ']'))
    [[%str (crip (flop acc))] t.t.rest]
  $(acc [i.rest acc], rest t.rest)
::
++  lex-name
  |=  src=tape
  ^-  [tok=token nex=tape]
  =/  res  (take-while src aln)
  =/  nm=@t  (crip p.res)
  ?:  (~(has in keywords) nm)  [[%kw nm] q.res]
  [[%name nm] q.res]
::
++  lex-op
  |=  src=tape
  ^-  [tok=token nex=tape]
  ?~  src  ~|(%lex-empty !!)
  =/  c=@     i.src
  =/  r1=tape  t.src
  =/  d=@     ?~(r1 0 i.r1)
  =/  r2=tape  ?~(r1 ~ t.r1)
  =/  e=@     ?~(r2 0 i.r2)
  =/  r3=tape  ?~(r2 ~ t.r2)
  ?:  &(=(c '.') =(d '.') =(e '.'))  [[%op '...'] r3]
  ?:  &(=(c '.') =(d '.'))  [[%op '..'] r2]
  ?:  &(=(c '=') =(d '='))  [[%op '=='] r2]
  ?:  &(=(c '~') =(d '='))  [[%op '~='] r2]
  ?:  &(=(c '<') =(d '='))  [[%op '<='] r2]
  ?:  &(=(c '>') =(d '='))  [[%op '>='] r2]
  ?:  &(=(c '/') =(d '/'))  [[%op '//'] r2]
  ?:  &(=(c ':') =(d ':'))  [[%op '::'] r2]
  [[%op (crip ~[c])] r1]
::
++  lex-num
  |=  src=tape
  ^-  [tok=token nex=tape]
  ?~  src  ~|(%lex-empty !!)
  ?:  &(=(i.src '0') ?=(^ t.src) |(=(i.t.src 'x') =(i.t.src 'X')))
    =/  res  (take-while t.t.src hek)
    [[%num %i (sun:si (base-val 16 p.res))] q.res]
  =/  ir  (take-while src dig)
  =/  ip=tape  p.ir
  =/  rest=tape  q.ir
  =/  has-dot=?  ?&(?=(^ rest) =(i.rest '.'))
  =/  fp=tape  ~
  =.  rest  ?~(rest rest ?:(has-dot t.rest rest))
  =^  fp  rest  ?:(has-dot (take-while rest dig) [fp rest])
  =/  has-e=?  ?&(?=(^ rest) |(=(i.rest 'e') =(i.rest 'E')))
  =/  esign=?  %.y
  =/  ep=tape  ~
  =.  rest  ?~(rest rest ?:(has-e t.rest rest))
  =^  esign  rest
    ?:  ?&(has-e ?=(^ rest) |(=(i.rest '-') =(i.rest '+')))
      [=(i.rest '+') t.rest]
    [esign rest]
  =^  ep  rest  ?:(has-e (take-while rest dig) [ep rest])
  ?.  |(has-dot has-e)
    [[%num %i (sun:si (base-val 10 ip))] rest]
  =/  ipv=@rd  (sun:rd (base-val 10 ip))
  =/  fpv=@rd
    ?~  fp  .~0
    (div:rd (sun:rd (base-val 10 fp)) (powten (lent fp)))
  =/  mant=@rd  (add:rd ipv fpv)
  =/  ev=@ud  (base-val 10 ep)
  =/  res=@rd
    ?:  =(ev 0)  mant
    ?:  esign  (mul:rd mant (powten ev))
    (div:rd mant (powten ev))
  [[%num %f res] rest]
::                                                ::  ::  parser
++  hed  |=(q=(list token) ^-(token ?~(q [%eof ~] i.q)))
++  nx   |=(a=(list token) ^-((list token) ?~(a ~ t.a)))
++  is-op  |=([t=token s=@t] &(?=([%op *] t) =(p.t s)))
++  is-kw  |=([t=token s=@t] &(?=([%kw *] t) =(p.t s)))
++  expect-op
  |=  [q=(list token) s=@t]
  ^-  (list token)
  ?.  (is-op (hed q) s)  ~|([%lua-expected-op s got+(hed q)] !!)
  (nx q)
++  expect-kw
  |=  [q=(list token) s=@t]
  ^-  (list token)
  ?.  (is-kw (hed q) s)  ~|([%lua-expected-kw s got+(hed q)] !!)
  (nx q)
++  op-str
  |=  t=token
  ^-  @t
  ?:  ?=([%kw *] t)  p.t
  ?>(?=([%op *] t) p.t)
++  parse
  |=  q=(list token)
  ^-  block
  =+  (parse-block q)
  =/  h  (hed q)
  ?.  ?=(%eof -.h)  ~|([%lua-trailing-tokens h] !!)
  p
++  parse-block
  |=  q=(list token)
  ^-  [p=block q=(list token)]
  =/  stmts=(list stmt)  ~
  |-  ^-  [p=block q=(list token)]
  =/  h  (hed q)
  ?:  ?|  ?=(%eof -.h)
          (is-kw h 'end')
          (is-kw h 'else')
          (is-kw h 'elseif')
          (is-kw h 'until')
      ==
    [(flop stmts) q]
  ?:  (is-op h ';')  $(q (nx q))
  ?:  (is-kw h 'return')
    =/  r  (parse-return (nx q))
    [(flop [p.r stmts]) q.r]
  =/  r  (parse-stmt q)
  $(stmts [p.r stmts], q q.r)
++  parse-return
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  h  (hed q)
  ?:  ?|  ?=(%eof -.h)
          (is-kw h 'end')
          (is-kw h 'else')
          (is-kw h 'elseif')
          (is-kw h 'until')
          (is-op h ';')
      ==
    [[%return ~] ?:((is-op h ';') (nx q) q)]
  =/  r  (parse-exprlist q)
  [[%return p.r] ?:((is-op (hed q.r) ';') (nx q.r) q.r)]
++  parse-stmt
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  h  (hed q)
  ?:  (is-kw h 'local')   (parse-local (nx q))
  ?:  (is-kw h 'if')      (parse-if (nx q))
  ?:  (is-kw h 'while')   (parse-while (nx q))
  ?:  (is-kw h 'repeat')  (parse-repeat (nx q))
  ?:  (is-kw h 'for')     (parse-for (nx q))
  ?:  (is-kw h 'function')  (parse-funcstmt (nx q))
  ?:  (is-kw h 'do')
    =/  r  (parse-block (nx q))
    [[%do p.r] (expect-kw q.r 'end')]
  (parse-exprstmt q)
++  parse-local
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  ?:  (is-kw (hed q) 'function')
    =/  h  (hed (nx q))
    ?.  ?=(%name -.h)  ~|(%lua-expected-name !!)
    =/  r  (parse-funcbody (nx (nx q)) %.n)
    [[%localfunc p.h p.r] q.r]
  =/  nr  (parse-namelist q)
  ?:  (is-op (hed q.nr) '=')
    =/  er  (parse-exprlist (nx q.nr))
    [[%local p.nr p.er] q.er]
  [[%local p.nr ~] q.nr]
++  parse-namelist
  |=  q=(list token)
  ^-  [p=(list @t) q=(list token)]
  =/  h  (hed q)
  ?.  ?=(%name -.h)  ~|(%lua-expected-name !!)
  =/  names=(list @t)  ~[p.h]
  =.  q  (nx q)
  |-  ^-  [p=(list @t) q=(list token)]
  ?.  (is-op (hed q) ',')  [(flop names) q]
  =/  h2  (hed (nx q))
  ?.  ?=(%name -.h2)  [(flop names) q]
  $(names [p.h2 names], q (nx (nx q)))
++  parse-if
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  cr  (parse-expr q)
  =/  q  (expect-kw q.cr 'then')
  =/  br  (parse-block q)
  =/  clauses=(list [c=expr b=block])  ~[[p.cr p.br]]
  =.  q  q.br
  |-  ^-  [p=stmt q=(list token)]
  =/  h  (hed q)
  ?:  (is-kw h 'elseif')
    =/  c2  (parse-expr (nx q))
    =/  q2  (expect-kw q.c2 'then')
    =/  b2  (parse-block q2)
    $(clauses [[p.c2 p.b2] clauses], q q.b2)
  ?:  (is-kw h 'else')
    =/  eb  (parse-block (nx q))
    [[%if (flop clauses) `p.eb] (expect-kw q.eb 'end')]
  [[%if (flop clauses) ~] (expect-kw q 'end')]
++  parse-while
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  cr  (parse-expr q)
  =/  q  (expect-kw q.cr 'do')
  =/  br  (parse-block q)
  [[%while p.cr p.br] (expect-kw q.br 'end')]
++  parse-repeat
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  br  (parse-block q)
  =/  q  (expect-kw q.br 'until')
  =/  cr  (parse-expr q)
  [[%repeat p.br p.cr] q.cr]
++  parse-for
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  h  (hed q)
  ?.  ?=(%name -.h)  ~|(%lua-expected-for-name !!)
  =/  nm  p.h
  =.  q  (nx q)
  ?:  (is-op (hed q) '=')
    =/  e1  (parse-expr (nx q))
    =/  q  (expect-op q.e1 ',')
    =/  e2  (parse-expr q)
    =/  step=(unit expr)  ~
    =/  q  q.e2
    =^  step  q
      ?.  (is-op (hed q) ',')  [~ q]
      =/  e3  (parse-expr (nx q))
      [`p.e3 q.e3]
    =/  q  (expect-kw q 'do')
    =/  br  (parse-block q)
    [[%numfor nm p.e1 p.e2 step p.br] (expect-kw q.br 'end')]
  =/  names=(list @t)  ~[nm]
  =^  names  q
    ?.  (is-op (hed q) ',')  [names q]
    =/  nr  (parse-namelist (nx q))
    [(weld names p.nr) q.nr]
  =/  q  (expect-kw q 'in')
  =/  er  (parse-exprlist q)
  =/  q  (expect-kw q.er 'do')
  =/  br  (parse-block q)
  [[%genfor names p.er p.br] (expect-kw q.br 'end')]
++  parse-funcstmt
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  h  (hed q)
  ?.  ?=(%name -.h)  ~|(%lua-expected-func-name !!)
  =/  base=expr  [%name p.h]
  =.  q  (nx q)
  =^  base  q
    |-  ^-  [expr (list token)]
    ?.  (is-op (hed q) '.')  [base q]
    =/  h2  (hed (nx q))
    ?.  ?=(%name -.h2)  ~|(%lua-bad-funcname !!)
    $(base [%index base [%str p.h2]], q (nx (nx q)))
  =/  is-method=?  %.n
  =^  ism  q
    ?.  (is-op (hed q) ':')  [%.n q]
    =/  h2  (hed (nx q))
    ?.  ?=(%name -.h2)  ~|(%lua-bad-method !!)
    =.  base  [%index base [%str p.h2]]
    [%.y (nx (nx q))]
  =/  r  (parse-funcbody q ism)
  [[%assign ~[base] ~[p.r]] q.r]
++  parse-funcbody
  |=  [q=(list token) method=?]
  ^-  [p=expr q=(list token)]
  =/  q  (expect-op q '(')
  =/  params=(list @t)  ?:(method ~['self'] ~)
  =/  vararg=?  %.n
  =^  pv  q
    ?:  (is-op (hed q) ')')  [[params vararg] (nx q)]
    |-  ^-  [[(list @t) ?] (list token)]
    =/  h  (hed q)
    ?:  (is-op h '...')  [[params %.y] (expect-op (nx q) ')')]
    ?.  ?=(%name -.h)  ~|(%lua-expected-param !!)
    =.  params  (snoc params p.h)
    ?:  (is-op (hed (nx q)) ',')  $(q (nx (nx q)))
    [[params vararg] (expect-op (nx q) ')')]
  =/  br  (parse-block q)
  [[%func -.pv +.pv p.br] (expect-kw q.br 'end')]
++  parse-exprstmt
  |=  q=(list token)
  ^-  [p=stmt q=(list token)]
  =/  er  (parse-suffixed q)
  =/  e  p.er
  =.  q  q.er
  ?:  |((is-op (hed q) '=') (is-op (hed q) ','))
    =/  targets=(list expr)  ~[e]
    =^  targets  q
      |-  ^-  [(list expr) (list token)]
      ?.  (is-op (hed q) ',')  [targets q]
      =/  r  (parse-suffixed (nx q))
      $(targets (snoc targets p.r), q q.r)
    =/  q  (expect-op q '=')
    =/  vr  (parse-exprlist q)
    [[%assign targets p.vr] q.vr]
  ?.  |(?=([%call *] e) ?=([%method *] e))
    ~|(%lua-syntax-error-statement !!)
  [[%call e] q]
++  parse-exprlist
  |=  q=(list token)
  ^-  [p=(list expr) q=(list token)]
  =/  er  (parse-expr q)
  =/  es=(list expr)  ~[p.er]
  =.  q  q.er
  |-  ^-  [p=(list expr) q=(list token)]
  ?.  (is-op (hed q) ',')  [(flop es) q]
  =/  r  (parse-expr (nx q))
  $(es [p.r es], q q.r)
++  parse-args
  |=  q=(list token)
  ^-  [p=(list expr) q=(list token)]
  ?:  (is-op (hed q) ')')  [~ (nx q)]
  =/  r  (parse-exprlist q)
  [p.r (expect-op q.r ')')]
++  parse-expr
  |=  q=(list token)
  ^-  [p=expr q=(list token)]
  (parse-bin q 0)
++  binprec
  |=  t=token
  ^-  (unit @ud)
  ?:  ?=([%kw *] t)
    ?:  =(p.t 'or')  `1
    ?:  =(p.t 'and')  `2
    ~
  ?.  ?=([%op *] t)  ~
  =/  s  p.t
  ?:  ?|(=(s '<') =(s '>') =(s '<=') =(s '>=') =(s '~=') =(s '=='))  `3
  ?:  =(s '..')  `4
  ?:  |(=(s '+') =(s '-'))  `5
  ?:  ?|(=(s '*') =(s '/') =(s '//') =(s '%'))  `6
  ~
++  parse-bin
  |=  [q=(list token) minp=@ud]
  ^-  [p=expr q=(list token)]
  =/  lr  (parse-unary q)
  =/  left  p.lr
  =.  q  q.lr
  |-  ^-  [p=expr q=(list token)]
  =/  h  (hed q)
  =/  mp  (binprec h)
  ?~  mp  [left q]
  ?:  (lth u.mp minp)  [left q]
  =/  ops  (op-str h)
  =/  nextmin  ?:(=(ops '..') u.mp +(u.mp))
  =/  rr  (parse-bin (nx q) nextmin)
  $(left [%binop ops left p.rr], q q.rr)
++  parse-unary
  |=  q=(list token)
  ^-  [p=expr q=(list token)]
  =/  h  (hed q)
  ?:  |((is-kw h 'not') (is-op h '-') (is-op h '#'))
    =/  op=@t  ?:((is-kw h 'not') 'not' (op-str h))
    =/  r  (parse-unary (nx q))
    [[%unop op p.r] q.r]
  (parse-pow q)
++  parse-pow
  |=  q=(list token)
  ^-  [p=expr q=(list token)]
  =/  br  (parse-suffixed q)
  ?.  (is-op (hed q.br) '^')  br
  =/  rr  (parse-unary (nx q.br))
  [[%binop '^' p.br p.rr] q.rr]
++  parse-suffixed
  |=  q=(list token)
  ^-  [p=expr q=(list token)]
  =/  pr  (parse-primary q)
  =/  e  p.pr
  =.  q  q.pr
  |-  ^-  [p=expr q=(list token)]
  =/  h  (hed q)
  ?:  (is-op h '.')
    =/  h2  (hed (nx q))
    ?.  ?=(%name -.h2)  ~|(%lua-expected-field !!)
    $(e [%index e [%str p.h2]], q (nx (nx q)))
  ?:  (is-op h '[')
    =/  kr  (parse-expr (nx q))
    $(e [%index e p.kr], q (expect-op q.kr ']'))
  ?:  (is-op h '(')
    =/  ar  (parse-args (nx q))
    $(e [%call e p.ar], q q.ar)
  ?:  (is-op h ':')
    =/  h2  (hed (nx q))
    ?.  ?=(%name -.h2)  ~|(%lua-expected-method !!)
    =/  q2  (expect-op (nx (nx q)) '(')
    =/  ar  (parse-args q2)
    $(e [%method e p.h2 p.ar], q q.ar)
  ?:  ?=([%str *] h)
    $(e [%call e ~[[%str p.h]]], q (nx q))
  ?:  (is-op h '{')
    =/  tr  (parse-table q)
    $(e [%call e ~[p.tr]], q q.tr)
  [e q]
++  parse-primary
  |=  q=(list token)
  ^-  [p=expr q=(list token)]
  =/  h  (hed q)
  ?:  ?=([%num *] h)
    ?:  ?=(%i -.n.h)  [[%int p.n.h] (nx q)]
    [[%flt p.n.h] (nx q)]
  ?:  ?=([%str *] h)  [[%str p.h] (nx q)]
  ?:  (is-kw h 'nil')  [[%nil ~] (nx q)]
  ?:  (is-kw h 'true')  [[%true ~] (nx q)]
  ?:  (is-kw h 'false')  [[%false ~] (nx q)]
  ?:  (is-op h '...')  [[%vararg ~] (nx q)]
  ?:  (is-kw h 'function')  (parse-funcbody (nx q) %.n)
  ?:  (is-op h '{')  (parse-table q)
  ?:  (is-op h '(')
    =/  er  (parse-expr (nx q))
    [[%paren p.er] (expect-op q.er ')')]
  ?:  ?=(%name -.h)  [[%name p.h] (nx q)]
  ~|([%lua-unexpected-token h] !!)
++  parse-table
  |=  q=(list token)
  ^-  [p=expr q=(list token)]
  =/  q  (expect-op q '{')
  =/  fields=(list tfield)  ~
  |-  ^-  [p=expr q=(list token)]
  ?:  (is-op (hed q) '}')  [[%table (flop fields)] (nx q)]
  =/  fr  (parse-field q)
  =/  q  q.fr
  =.  q  ?:(|((is-op (hed q) ',') (is-op (hed q) ';')) (nx q) q)
  $(fields [p.fr fields], q q)
++  parse-field
  |=  q=(list token)
  ^-  [p=tfield q=(list token)]
  =/  h  (hed q)
  ?:  (is-op h '[')
    =/  kr  (parse-expr (nx q))
    =/  q  (expect-op (expect-op q.kr ']') '=')
    =/  vr  (parse-expr q)
    [[%key p.kr p.vr] q.vr]
  ?:  ?&(?=(%name -.h) (is-op (hed (nx q)) '='))
    =/  vr  (parse-expr (nx (nx q)))
    [[%name p.h p.vr] q.vr]
  =/  vr  (parse-expr q)
  [[%pos p.vr] q.vr]
::                                                ::  ::  store helpers
++  init-store  ^-(store [~ ~ ~ ~ 0 ~])
++  fresh
  |=  s=store
  ^-  [@ud store]
  [next.s s(next +(next.s))]
++  truthy
  |=  v=value
  ^-  ?
  ?:  ?=(%nil -.v)  %.n
  ?:  ?=(%b -.v)  p.v
  %.y
++  look
  |=  [env=scope nm=@t]
  ^-  (unit @ud)
  ?~  env  ~
  =/  c  (~(get by i.env) nm)
  ?~  c  $(env t.env)
  c
++  rd-var
  |=  [nm=@t env=scope s=store]
  ^-  value
  =/  c  (look env nm)
  ?~  c  (~(gut by glob.s) nm [%nil ~])
  (~(gut by cells.s) u.c [%nil ~])
++  set-var
  |=  [nm=@t v=value env=scope s=store]
  ^-  store
  =/  c  (look env nm)
  ?~  c  s(glob (~(put by glob.s) nm v))
  s(cells (~(put by cells.s) u.c v))
++  decl
  |=  [nm=@t v=value env=scope s=store]
  ^-  [scope store]
  =^  id  s  (fresh s)
  =/  env2=scope
    ?~  env  ~[(~(put by *frame) nm id)]
    [(~(put by i.env) nm id) t.env]
  [env2 s(cells (~(put by cells.s) id v))]
++  new-table
  |=  s=store
  ^-  [@ud store]
  =^  id  s  (fresh s)
  [id s(tabs (~(put by tabs.s) id ~))]
++  norm-key
  |=  v=value
  ^-  vkey
  ?-  -.v
    %i    [%i p.v]
    %s    [%s p.v]
    %b    [%b p.v]
    %f    =/  u  (toi:rd p.v)
          ?~  u  [%f p.v]
          ?:((equ:rd p.v (i2f u.u)) [%i u.u] [%f p.v])
    %nil  ~|(%lua-table-nil-key !!)
    %t    ~|(%lua-table-key-unsupported !!)
    %c    ~|(%lua-table-key-unsupported !!)
    %fn   ~|(%lua-table-key-unsupported !!)
  ==
++  unkey
  |=  k=vkey
  ^-  value
  ?-  -.k
    %i  [%i p.k]
    %f  [%f p.k]
    %s  [%s p.k]
    %b  [%b p.k]
  ==
++  tab-get
  |=  [id=@ud k=value s=store]
  ^-  value
  =/  tb  (~(gut by tabs.s) id ~)
  (~(gut by tb) (norm-key k) [%nil ~])
++  tab-set
  |=  [id=@ud k=value v=value s=store]
  ^-  store
  =/  tb  (~(gut by tabs.s) id ~)
  =/  tb2
    ?:  ?=(%nil -.v)  (~(del by tb) (norm-key k))
    (~(put by tb) (norm-key k) v)
  s(tabs (~(put by tabs.s) id tb2))
++  tab-len
  |=  [id=@ud s=store]
  ^-  @sd
  =/  tb  (~(gut by tabs.s) id ~)
  =/  n=@ud  1
  |-  ^-  @sd
  ?:  (~(has by tb) [%i (sun:si n)])  $(n +(n))
  (sun:si (dec n))
::                                                ::  ::  value ops
++  val-eq
  |=  [a=value b=value]
  ^-  ?
  ?:  ?&(?=(%i -.a) ?=(%i -.b))  =(p.a p.b)
  ?:  ?&(?=(%f -.a) ?=(%f -.b))  (equ:rd p.a p.b)
  ?:  ?&(?=(%i -.a) ?=(%f -.b))  (equ:rd (i2f p.a) p.b)
  ?:  ?&(?=(%f -.a) ?=(%i -.b))  (equ:rd p.a (i2f p.b))
  ?:  ?&(?=(%s -.a) ?=(%s -.b))  =(p.a p.b)
  ?:  ?&(?=(%b -.a) ?=(%b -.b))  =(p.a p.b)
  ?:  ?&(?=(%nil -.a) ?=(%nil -.b))  %.y
  ?:  ?&(?=(%t -.a) ?=(%t -.b))  =(id.a id.b)
  ?:  ?&(?=(%c -.a) ?=(%c -.b))  =(id.a id.b)
  ?:  ?&(?=(%fn -.a) ?=(%fn -.b))  =(p.a p.b)
  %.n
++  cmp-cord
  |=  [a=@t b=@t]
  ^-  @s
  =/  x  (trip a)
  =/  y  (trip b)
  |-  ^-  @s
  ?~  x  ?~(y --0 -1)
  ?~  y  --1
  ?:  (lth i.x i.y)  -1
  ?:  (gth i.x i.y)  --1
  $(x t.x, y t.y)
++  as-num
  |=  v=value
  ^-  value
  ?:  |(?=(%i -.v) ?=(%f -.v))  v
  ~|([%lua-arith-on-non-number -.v] !!)
++  as-str
  |=  v=value
  ^-  @t
  ?:  ?=(%s -.v)  p.v
  ?:  ?=(%i -.v)  (crip (fmt-int p.v))
  ?:  ?=(%f -.v)  (crip (fmt-flt p.v))
  ~|(%lua-expected-string !!)
++  as-int
  |=  v=value
  ^-  @sd
  ?:  ?=(%i -.v)  p.v
  ?.  ?=(%f -.v)  ~|(%lua-expected-integer !!)
  =/  u  (toi:rd p.v)
  ?~  u  ~|(%lua-not-an-integer !!)
  u.u
++  arith
  |=  [op=@t a=value b=value]
  ^-  value
  =.  a  (as-num a)
  =.  b  (as-num b)
  ?:  =(op '/')  [%f (div:rd (toflt a) (toflt b))]
  ?:  =(op '^')  [%f (powrd (toflt a) (toflt b))]
  ?:  ?&(?=(%i -.a) ?=(%i -.b))
    ?:  =(op '+')   [%i (sum:si p.a p.b)]
    ?:  =(op '-')   [%i (dif:si p.a p.b)]
    ?:  =(op '*')   [%i (pro:si p.a p.b)]
    ?:  =(op '//')  [%i (ifloordiv p.a p.b)]
    ?:  =(op '%')   [%i (imod p.a p.b)]
    ~|([%lua-bad-arith op] !!)
  =/  x  (toflt a)
  =/  y  (toflt b)
  ?:  =(op '+')   [%f (add:rd x y)]
  ?:  =(op '-')   [%f (sub:rd x y)]
  ?:  =(op '*')   [%f (mul:rd x y)]
  ?:  =(op '//')  [%f (ffloor (div:rd x y))]
  ?:  =(op '%')   [%f (sub:rd x (mul:rd (ffloor (div:rd x y)) y))]
  ~|([%lua-bad-arith op] !!)
++  ord-result
  |=  [op=@t c=@s]
  ^-  value
  ?:  =(op '<')   [%b =(c -1)]
  ?:  =(op '>')   [%b =(c --1)]
  ?:  =(op '<=')  [%b |(=(c -1) =(c --0))]
  ?:  =(op '>=')  [%b |(=(c --1) =(c --0))]
  ~|([%lua-bad-compare op] !!)
++  compare
  |=  [op=@t a=value b=value]
  ^-  value
  ?:  =(op '==')  [%b (val-eq a b)]
  ?:  =(op '~=')  [%b !(val-eq a b)]
  ?:  ?&(?=(%s -.a) ?=(%s -.b))  (ord-result op (cmp-cord p.a p.b))
  =/  x  (toflt (as-num a))
  =/  y  (toflt (as-num b))
  =/  c=@s  ?:((equ:rd x y) --0 ?:((lth:rd x y) -1 --1))
  (ord-result op c)
++  concat
  |=  [a=value b=value]
  ^-  value
  [%s (crip (weld (trip (as-str a)) (trip (as-str b))))]
++  tostr
  |=  [v=value s=store]
  ^-  tape
  ?-  -.v
    %nil  "nil"
    %b    ?:(p.v "true" "false")
    %i    (fmt-int p.v)
    %f    (fmt-flt p.v)
    %s    (trip p.v)
    %t    (weld "table: " (scow %ux id.v))
    %c    (weld "function: " (scow %ux id.v))
    %fn   (weld "builtin: " (trip p.v))
  ==
::                                                ::  ::  evaluator
++  arg
  |=  [n=@ud as=(list value)]
  ^-  value
  ?:((lth n (lent as)) (snag n as) [%nil ~])
++  ev
  |=  [e=* env=scope va=(list value) s=store]
  ^-  [value store]
  =/  e  ;;(expr e)
  ?-  -.e
    %nil    [[%nil ~] s]
    %true   [[%b %.y] s]
    %false  [[%b %.n] s]
    %int    [[%i p.e] s]
    %flt    [[%f p.e] s]
    %str    [[%s p.e] s]
    %vararg  [?~(va [%nil ~] i.va) s]
    %paren  (ev e.e env va s)
    %name   [(rd-var p.e env s) s]
  ::
      %index
    =^  tv  s  (ev t.e env va s)
    =^  kv  s  (ev k.e env va s)
    ?.  ?=(%t -.tv)  ~|([%lua-index-non-table -.tv] !!)
    [(tab-get id.tv kv s) s]
  ::
      %call
    =^  vs  s  (do-call e env va s)
    [?~(vs [%nil ~] i.vs) s]
  ::
      %method
    =^  vs  s  (do-call e env va s)
    [?~(vs [%nil ~] i.vs) s]
  ::
      %func
    =^  id  s  (fresh s)
    =/  bd  ;;((list stmt) body.e)
    [[%c id] s(funs (~(put by funs.s) id [params.e vararg.e bd env]))]
  ::
      %table
    =^  id  s  (new-table s)
    =/  s  (build-table id fields.e env va s)
    [[%t id] s]
  ::
      %binop  (ev-binop e env va s)
      %unop   (ev-unop e env va s)
  ==
++  ev-binop
  |=  [ex=* env=scope va=(list value) s=store]
  ^-  [value store]
  =/  e  ;;(expr ex)
  ?>  ?=(%binop -.e)
  =/  op  op.e
  ?:  =(op 'and')
    =^  l  s  (ev l.e env va s)
    ?.  (truthy l)  [l s]
    (ev r.e env va s)
  ?:  =(op 'or')
    =^  l  s  (ev l.e env va s)
    ?:  (truthy l)  [l s]
    (ev r.e env va s)
  =^  l  s  (ev l.e env va s)
  =^  r  s  (ev r.e env va s)
  ?:  =(op '..')  [(concat l r) s]
  ?:  ?|(=(op '==') =(op '~=') =(op '<') =(op '>') =(op '<=') =(op '>='))
    [(compare op l r) s]
  [(arith op l r) s]
++  ev-unop
  |=  [ex=* env=scope va=(list value) s=store]
  ^-  [value store]
  =/  e  ;;(expr ex)
  ?>  ?=(%unop -.e)
  =^  v  s  (ev e.e env va s)
  ?:  =(op.e 'not')  [[%b !(truthy v)] s]
  ?:  =(op.e '-')
    ?:  ?=(%i -.v)  [[%i (dif:si --0 p.v)] s]
    ?:  ?=(%f -.v)  [[%f (sub:rd .~0 p.v)] s]
    ~|(%lua-unary-minus-non-number !!)
  ?:  ?=(%s -.v)  [[%i (sun:si (lent (trip p.v)))] s]
  ?:  ?=(%t -.v)  [[%i (tab-len id.v s)] s]
  ~|(%lua-length-of-non-table !!)
++  evm
  |=  [ex=* env=scope va=(list value) s=store]
  ^-  [(list value) store]
  =/  e  ;;(expr ex)
  ?:  ?=(%call -.e)    (do-call e env va s)
  ?:  ?=(%method -.e)  (do-call e env va s)
  ?:  ?=(%vararg -.e)  [va s]
  =^  v  s  (ev e env va s)
  [~[v] s]
++  evl
  |=  [es=(list *) env=scope va=(list value) s=store]
  ^-  [(list value) store]
  ?~  es  [~ s]
  ?~  t.es  (evm i.es env va s)
  =^  v  s  (ev i.es env va s)
  =^  rest  s  $(es t.es)
  [[v rest] s]
++  build-table
  |=  [id=@ud fs=(list *) env=scope va=(list value) s=store]
  ^-  store
  =/  idx=@ud  1
  |-  ^-  store
  ?~  fs  s
  =/  f  ;;(tfield i.fs)
  ?-  -.f
      %pos
    ?~  t.fs
      =^  vs  s  (evm v.f env va s)
      (place-multi id idx vs s)
    =^  vv  s  (ev v.f env va s)
    =.  s  (tab-set id [%i (sun:si idx)] vv s)
    $(fs t.fs, idx +(idx))
  ::
      %key
    =^  kv  s  (ev k.f env va s)
    =^  vv  s  (ev v.f env va s)
    =.  s  (tab-set id kv vv s)
    $(fs t.fs)
  ::
      %name
    =^  vv  s  (ev v.f env va s)
    =.  s  (tab-set id [%s n.f] vv s)
    $(fs t.fs)
  ==
++  place-multi
  |=  [id=@ud idx=@ud vs=(list value) s=store]
  ^-  store
  ?~  vs  s
  =.  s  (tab-set id [%i (sun:si idx)] i.vs s)
  $(vs t.vs, idx +(idx))
++  do-call
  |=  [ex=* env=scope va=(list value) s=store]
  ^-  [(list value) store]
  =/  e  ;;(expr ex)
  ?:  ?=(%method -.e)
    =^  ov  s  (ev o.e env va s)
    ?.  ?=(%t -.ov)  ~|(%lua-method-on-non-table !!)
    =/  fnv  (tab-get id.ov [%s m.e] s)
    =^  args  s  (evl args.e env va s)
    (apply fnv [ov args] s)
  ?>  ?=(%call -.e)
  =^  fnv  s  (ev f.e env va s)
  =^  args  s  (evl args.e env va s)
  (apply fnv args s)
++  apply
  |=  [fnv=value args=(list value) s=store]
  ^-  [(list value) store]
  ?:  ?=(%c -.fnv)
    (call-closure (~(got by funs.s) id.fnv) args s)
  ?:  ?=(%fn -.fnv)
    (call-builtin p.fnv args s)
  ~|([%lua-call-non-function -.fnv] !!)
++  call-closure
  |=  [cl=closure args=(list value) s=store]
  ^-  [(list value) store]
  ::  record allocation state so we can reclaim this call's cells on return
  =/  pre=@ud       next.s
  =/  pre-funs=@ud  ~(wyt by funs.s)
  =/  pre-tabs=@ud  ~(wyt by tabs.s)
  =/  env2=scope  [*frame env.cl]
  =/  ps  params.cl
  =/  as  args
  =^  env2  s
    |-  ^-  [scope store]
    ?~  ps  [env2 s]
    =/  eo  (decl i.ps ?~(as [%nil ~] i.as) env2 s)
    $(ps t.ps, as ?~(as ~ t.as), env2 -.eo, s +.eo)
  =/  newva=(list value)
    ?.  vararg.cl  ~
    (slag (lent params.cl) args)
  =/  res  (do-stmts body.cl env2 newva s)
  =/  fl  -.res
  =/  s2  +.res
  ::  if the call made no closures and no tables, every cell it allocated
  ::  is unreachable now (only this call's discarded frames referenced them)
  ::  — reclaim them so deep recursion doesn't grow the store unboundedly.
  =?  s2  &(=(pre-funs ~(wyt by funs.s2)) =(pre-tabs ~(wyt by tabs.s2)))
    s2(next pre, cells (prune-cells cells.s2 pre next.s2))
  ?-  -.fl
    %ret   [vs.fl s2]
    %brk   [~ s2]
    %norm  [~ s2]
  ==
++  prune-cells
  |=  [m=(map @ud value) lo=@ud hi=@ud]
  ^-  (map @ud value)
  ?:  =(lo hi)  m
  $(m (~(del by m) lo), lo +(lo))
::                                                ::  ::  statements
++  do-stmts
  ::  takes an already-clammed statement list, so blocks executed
  ::  repeatedly (loop bodies, called functions) are not re-clammed.
  |=  [b=(list stmt) env=scope va=(list value) s=store]
  ^-  [flow store]
  |-  ^-  [flow store]
  ?~  b  [[%norm ~] s]
  =/  st  i.b
  ?-  -.st
      %local
    =^  vs  s  (evl exprs.st env va s)
    =/  eo  (bind-locals names.st vs env s)
    $(b t.b, env -.eo, s +.eo)
  ::
      %localfunc
    =/  eo  (bind-locals ~[name.st] ~[[%nil ~]] env s)
    =.  env  -.eo
    =.  s    +.eo
    =^  fv  s  (ev f.st env va s)
    =.  s  (set-var name.st fv env s)
    $(b t.b)
  ::
      %assign
    =^  vs  s  (evl exprs.st env va s)
    =.  s  (do-assign targets.st vs env va s)
    $(b t.b)
  ::
      %call
    =^  cv  s  (do-call e.st env va s)
    $(b t.b)
  ::
      %return
    =^  vs  s  (evl exprs.st env va s)
    [[%ret vs] s]
  ::
      %break  [[%brk ~] s]
  ::
      %do
    =/  res  (do-stmts ;;((list stmt) body.st) env va s)
    ?.  ?=(%norm -.-.res)  res
    $(b t.b, s +.res)
  ::
      %while
    =/  res  (do-while c.st body.st env va s)
    ?.  ?=(%norm -.-.res)  res
    $(b t.b, s +.res)
  ::
      %repeat
    =/  res  (do-repeat body.st c.st env va s)
    ?.  ?=(%norm -.-.res)  res
    $(b t.b, s +.res)
  ::
      %if
    =/  res  (do-if clauses.st els.st env va s)
    ?.  ?=(%norm -.-.res)  res
    $(b t.b, s +.res)
  ::
      %numfor
    =/  res  (do-numfor st env va s)
    ?.  ?=(%norm -.-.res)  res
    $(b t.b, s +.res)
  ::
      %genfor
    =/  res  (do-genfor st env va s)
    ?.  ?=(%norm -.-.res)  res
    $(b t.b, s +.res)
  ==
++  bind-locals
  |=  [names=(list @t) vs=(list value) env=scope s=store]
  ^-  [scope store]
  ?~  names  [env s]
  =/  eo  (decl i.names ?~(vs [%nil ~] i.vs) env s)
  $(names t.names, vs ?~(vs ~ t.vs), env -.eo, s +.eo)
++  set-locals
  |=  [names=(list @t) vs=(list value) env=scope s=store]
  ^-  store
  ?~  names  s
  =.  s  (set-var i.names ?~(vs [%nil ~] i.vs) env s)
  $(names t.names, vs ?~(vs ~ t.vs))
++  do-assign
  |=  [targets=(list *) vs=(list value) env=scope va=(list value) s=store]
  ^-  store
  =/  i=@ud  0
  |-  ^-  store
  ?~  targets  s
  =/  val  ?:((lth i (lent vs)) (snag i vs) [%nil ~])
  =/  tgt  ;;(expr i.targets)
  ?:  ?=(%name -.tgt)
    =.  s  (set-var p.tgt val env s)
    $(targets t.targets, i +(i))
  ?:  ?=(%index -.tgt)
    =^  tv  s  (ev t.tgt env va s)
    =^  kv  s  (ev k.tgt env va s)
    ?.  ?=(%t -.tv)  ~|(%lua-assign-index-non-table !!)
    =.  s  (tab-set id.tv kv val s)
    $(targets t.targets, i +(i))
  ~|(%lua-bad-assign-target !!)
++  do-while
  |=  [c=* b=* env=scope va=(list value) s=store]
  ^-  [flow store]
  =/  body  ;;((list stmt) b)
  |-  ^-  [flow store]
  =^  cv  s  (ev c env va s)
  ?.  (truthy cv)  [[%norm ~] s]
  =/  res  (do-stmts body env va s)
  ?-  -.-.res
    %brk   [[%norm ~] +.res]
    %ret   res
    %norm  $(s +.res)
  ==
++  do-repeat
  |=  [b=* c=* env=scope va=(list value) s=store]
  ^-  [flow store]
  =/  body  ;;((list stmt) b)
  |-  ^-  [flow store]
  =/  res  (do-stmts body env va s)
  ?-  -.-.res
    %brk   [[%norm ~] +.res]
    %ret   res
      %norm
    =/  s2  +.res
    =^  cv  s2  (ev c env va s2)
    ?:  (truthy cv)  [[%norm ~] s2]
    $(s s2)
  ==
++  do-if
  |=  [clauses=(list [c=* b=*]) els=(unit *) env=scope va=(list value) s=store]
  ^-  [flow store]
  ?~  clauses
    ?~  els  [[%norm ~] s]
    (do-stmts ;;((list stmt) u.els) env va s)
  =^  cv  s  (ev c.i.clauses env va s)
  ?:  (truthy cv)  (do-stmts ;;((list stmt) b.i.clauses) env va s)
  $(clauses t.clauses)
++  do-numfor
  |=  [st=stmt env=scope va=(list value) s=store]
  ^-  [flow store]
  ?>  ?=(%numfor -.st)
  =/  body  ;;((list stmt) body.st)
  =^  fromv  s  (ev from.st env va s)
  =^  tov  s  (ev to.st env va s)
  =^  stepv  s  ?~(step.st [`value`[%i --1] s] (ev u.step.st env va s))
  ?:  ?&(?=(%i -.fromv) ?=(%i -.tov) ?=(%i -.stepv))
    =/  i=@sd  p.fromv
    =/  lim=@sd  p.tov
    =/  stp=@sd  p.stepv
    =/  up=?  (syn:si stp)
    ::  allocate the loop variable's cell ONCE, then mutate it each
    ::  iteration (avoids growing the store by one cell per iteration)
    =^  env2  s  (decl v.st [%i i] env s)
    |-  ^-  [flow store]
    ?.  ?:(up (sle i lim) (sge i lim))  [[%norm ~] s]
    =.  s  (set-var v.st [%i i] env2 s)
    =/  res  (do-stmts body env2 va s)
    ?-  -.-.res
      %brk   [[%norm ~] +.res]
      %ret   res
      %norm  $(i (sum:si i stp), s +.res)
    ==
  =/  x=@rd  (toflt (as-num fromv))
  =/  lim=@rd  (toflt (as-num tov))
  =/  stp=@rd  (toflt (as-num stepv))
  =/  up=?  !(lth:rd stp .~0)
  =^  env2  s  (decl v.st [%f x] env s)
  |-  ^-  [flow store]
  ?.  ?:(up (rlte x lim) (rgte x lim))  [[%norm ~] s]
  =.  s  (set-var v.st [%f x] env2 s)
  =/  res  (do-stmts body env2 va s)
  ?-  -.-.res
    %brk   [[%norm ~] +.res]
    %ret   res
    %norm  $(x (add:rd x stp), s +.res)
  ==
++  do-genfor
  |=  [st=stmt env=scope va=(list value) s=store]
  ^-  [flow store]
  ?>  ?=(%genfor -.st)
  =/  body  ;;((list stmt) body.st)
  =^  vals  s  (evl exprs.st env va s)
  =/  f  (arg 0 vals)
  =/  st8  (arg 1 vals)
  =/  ctrl  (arg 2 vals)
  ::  allocate the loop variables' cells ONCE, then mutate each iteration
  =^  env2  s  (bind-locals names.st `(list value)`~ env s)
  |-  ^-  [flow store]
  =^  rets  s  (apply f ~[st8 ctrl] s)
  =/  first  ?~(rets [%nil ~] i.rets)
  ?:  ?=(%nil -.first)  [[%norm ~] s]
  =.  ctrl  first
  =.  s  (set-locals names.st rets env2 s)
  =/  res  (do-stmts body env2 va s)
  ?-  -.-.res
    %brk   [[%norm ~] +.res]
    %ret   res
    %norm  $(s +.res)
  ==
::                                                ::  ::  builtins
++  call-builtin
  |=  [nm=@tas args=(list value) s=store]
  ^-  [(list value) store]
  ?+    nm  ~|([%lua-unknown-builtin nm] !!)
      %print
    =/  parts  (turn args |=(v=value (tostr v s)))
    =/  tab=tape  ~[`@tD`9]
    =/  line  (zing (join tab parts))
    [~ s(out (snoc out.s line))]
  ::
      %type     [~[(bi-type (arg 0 args))] s]
      %tostring  [~[[%s (crip (tostr (arg 0 args) s))]] s]
      %tonumber  [~[(bi-tonumber (arg 0 args))] s]
      %pairs    [~[[%fn %next] (arg 0 args) [%nil ~]] s]
      %ipairs   [~[[%fn %inext] (arg 0 args) [%i --0]] s]
      %next      [(bi-next args s) s]
      %rawequal  [~[[%b (val-eq (arg 0 args) (arg 1 args))]] s]
      %rawget    [~[(tab-get id:;;([%t id=@ud] (arg 0 args)) (arg 1 args) s)] s]
      %rawlen    [~[(bi-rawlen (arg 0 args) s)] s]
  ::
      %inext
    =/  tv  (arg 0 args)
    =/  iv  (arg 1 args)
    ?.  ?=(%t -.tv)  ~|(%lua-ipairs-non-table !!)
    ?.  ?=(%i -.iv)  ~|(%lua-ipairs-bad-index !!)
    =/  ni  (sum:si p.iv --1)
    =/  val  (tab-get id.tv [%i ni] s)
    ?:  ?=(%nil -.val)  [~[[%nil ~]] s]
    [~[[%i ni] val] s]
  ::
      %assert
    ?:  (truthy (arg 0 args))  [args s]
    =/  m  (arg 1 args)
    ?:  ?=(%s -.m)  ~|((trip p.m) !!)
    ~|(%lua-assertion-failed !!)
  ::
      %error
    =/  v  (arg 0 args)
    ?:  ?=(%s -.v)  ~|((trip p.v) !!)
    ~|([%lua-error v] !!)
  ::
      %select
    =/  n  (arg 0 args)
    =/  rest  ?~(args ~ t.args)
    ?:  ?&(?=(%s -.n) =(p.n '#'))  [~[[%i (sun:si (lent rest))]] s]
    ?.  ?=(%i -.n)  ~|(%lua-select-bad-arg !!)
    [(slag (dec (abs:si p.n)) rest) s]
  ::
      %mfloor   [~[(mfloor-v (arg 0 args))] s]
      %mceil    [~[(mceil-v (arg 0 args))] s]
      %mabs     [~[(mabs-v (arg 0 args))] s]
      %msqrt    [~[[%f (sqrt-rd (toflt (as-num (arg 0 args))))]] s]
      %mmax     [~[(mmax args)] s]
      %mmin     [~[(mmin args)] s]
  ::
      %slen     [~[[%i (sun:si (lent (trip (as-str (arg 0 args)))))]] s]
      %ssub     [~[(bi-ssub args)] s]
      %srep     [~[(bi-srep args)] s]
      %supper   [~[[%s (crip (turn (trip (as-str (arg 0 args))) up-char))]] s]
      %slower   [~[[%s (crip (turn (trip (as-str (arg 0 args))) low-char))]] s]
      %sformat  [~[(bi-sformat args s)] s]
  ::
      %tinsert  (bi-tinsert args s)
      %tremove  (bi-tremove args s)
      %tconcat  [~[(bi-tconcat args s)] s]
  ==
++  bi-type
  |=  v=value
  ^-  value
  :-  %s
  ?-  -.v
    %nil  'nil'
    %b    'boolean'
    %i    'number'
    %f    'number'
    %s    'string'
    %t    'table'
    %c    'function'
    %fn   'function'
  ==
++  bi-rawlen
  |=  [v=value s=store]
  ^-  value
  ?:  ?=(%t -.v)  [%i (tab-len id.v s)]
  ?:  ?=(%s -.v)  [%i (sun:si (lent (trip p.v)))]
  ~|(%lua-rawlen-bad-arg !!)
++  bi-tonumber
  |=  v=value
  ^-  value
  ?:  |(?=(%i -.v) ?=(%f -.v))  v
  ?.  ?=(%s -.v)  [%nil ~]
  =/  tp  (trip p.v)
  =/  neg=?  &(?=(^ tp) =(i.tp '-'))
  =.  tp  ?~(tp tp ?:(neg t.tp tp))
  ?~  tp  [%nil ~]
  ?.  |((dig i.tp) =(i.tp '.'))  [%nil ~]
  =/  r  (lex-num tp)
  ?.  ?=(~ nex.r)  [%nil ~]
  ?.  ?=(%num -.tok.r)  [%nil ~]
  ?:  ?=(%i -.n.tok.r)
    [%i ?:(neg (dif:si --0 p.n.tok.r) p.n.tok.r)]
  [%f ?:(neg (sub:rd .~0 p.n.tok.r) p.n.tok.r)]
++  bi-next
  |=  [args=(list value) s=store]
  ^-  (list value)
  =/  tv  (arg 0 args)
  ?.  ?=(%t -.tv)  ~|(%lua-next-non-table !!)
  =/  k  (arg 1 args)
  =/  ps  ~(tap by (~(gut by tabs.s) id.tv ~))
  ?:  ?=(%nil -.k)
    ?~  ps  ~[[%nil ~]]
    [(unkey p.i.ps) q.i.ps ~]
  =/  kk  (norm-key k)
  |-  ^-  (list value)
  ?~  ps  ~[[%nil ~]]
  ?:  =(p.i.ps kk)
    ?~  t.ps  ~[[%nil ~]]
    [(unkey p.i.t.ps) q.i.t.ps ~]
  $(ps t.ps)
++  mfloor-v
  |=  v=value
  ^-  value
  ?:  ?=(%i -.v)  v
  ?.  ?=(%f -.v)  ~|(%lua-floor-non-number !!)
  =/  u  (toi:rd (ffloor p.v))
  ?~(u v [%i u.u])
++  mceil-v
  |=  v=value
  ^-  value
  ?:  ?=(%i -.v)  v
  ?.  ?=(%f -.v)  ~|(%lua-ceil-non-number !!)
  =/  u  (toi:rd (sub:rd .~0 (ffloor (sub:rd .~0 p.v))))
  ?~(u v [%i u.u])
++  mabs-v
  |=  v=value
  ^-  value
  ?:  ?=(%i -.v)  [%i (sun:si (abs:si p.v))]
  ?.  ?=(%f -.v)  ~|(%lua-abs-non-number !!)
  ?:((lth:rd p.v .~0) [%f (sub:rd .~0 p.v)] [%f p.v])
++  sqrt-rd
  |=  x=@rd
  ^-  @rd
  ?:  (rlte x .~0)  .~0
  =/  g=@rd  x
  =/  n=@ud  40
  |-  ^-  @rd
  ?:  =(n 0)  g
  $(g (div:rd (add:rd g (div:rd x g)) .~2), n (dec n))
++  mmax
  |=  args=(list value)
  ^-  value
  ?~  args  ~|(%lua-max-no-args !!)
  =/  best  i.args
  =/  rest  t.args
  |-  ^-  value
  ?~  rest  best
  =.  best  ?:((truthy (compare '<' best i.rest)) i.rest best)
  $(rest t.rest)
++  mmin
  |=  args=(list value)
  ^-  value
  ?~  args  ~|(%lua-min-no-args !!)
  =/  best  i.args
  =/  rest  t.args
  |-  ^-  value
  ?~  rest  best
  =.  best  ?:((truthy (compare '>' best i.rest)) i.rest best)
  $(rest t.rest)
++  bi-ssub
  |=  args=(list value)
  ^-  value
  =/  str  (trip (as-str (arg 0 args)))
  =/  len  (lent str)
  =/  i  (as-int (arg 1 args))
  =/  j  ?:((gth (lent args) 2) (as-int (arg 2 args)) (sun:si len))
  =/  st1=@sd  ?:((syn:si i) i (sum:si (sun:si len) (sum:si i --1)))
  =/  en1=@sd  ?:((syn:si j) j (sum:si (sun:si len) (sum:si j --1)))
  =/  st2=@sd  ?:(=(-1 (cmp:si st1 --1)) --1 st1)
  =/  en2=@sd  ?:(=(--1 (cmp:si en1 (sun:si len))) (sun:si len) en1)
  ?:  =(--1 (cmp:si st2 en2))  [%s '']
  =/  start  (abs:si st2)
  =/  cnt  (add 1 (sub (abs:si en2) (abs:si st2)))
  [%s (crip (scag cnt (slag (dec start) str)))]
++  bi-srep
  |=  args=(list value)
  ^-  value
  =/  str  (trip (as-str (arg 0 args)))
  =/  n  (abs:si (as-int (arg 1 args)))
  =/  acc=tape  ~
  |-  ^-  value
  ?:  =(n 0)  [%s (crip acc)]
  $(acc (weld str acc), n (dec n))
++  bi-sformat
  |=  [args=(list value) s=store]
  ^-  value
  =/  fmt  (trip (as-str (arg 0 args)))
  =/  rest  ?~(args ~ t.args)
  =/  acc=tape  ~
  |-  ^-  value
  ?~  fmt  [%s (crip (flop acc))]
  ?.  =(i.fmt '%')  $(acc [i.fmt acc], fmt t.fmt)
  ?~  t.fmt  $(acc [i.fmt acc], fmt t.fmt)
  =/  spec  i.t.fmt
  ?:  =(spec '%')  $(acc ['%' acc], fmt t.t.fmt)
  =/  a  ?~(rest [%nil ~] i.rest)
  =/  rest2  ?~(rest ~ t.rest)
  =/  piece=tape
    ?:  |(=(spec 'd') =(spec 'i'))  (fmt-int (as-int a))
    ?:  =(spec 's')  (tostr a s)
    ?:  |(=(spec 'f') =(spec 'g'))  (fmt-flt (toflt (as-num a)))
    ?:  =(spec 'x')  (slag 2 (scow %ux (abs:si (as-int a))))
    ~[spec]
  $(acc (weld (flop piece) acc), fmt t.t.fmt, rest rest2)
++  bi-tinsert
  |=  [args=(list value) s=store]
  ^-  [(list value) store]
  =/  tv  (arg 0 args)
  ?.  ?=(%t -.tv)  ~|(%lua-insert-non-table !!)
  ?:  =(2 (lent args))
    =/  n  (tab-len id.tv s)
    [~ (tab-set id.tv [%i (sum:si n --1)] (arg 1 args) s)]
  =/  pos  (as-int (arg 1 args))
  =/  v  (arg 2 args)
  =/  n  (tab-len id.tv s)
  =/  i=@sd  n
  =.  s
    |-  ^-  store
    ?.  =(-1 (cmp:si i pos))  s
    =/  cur  (tab-get id.tv [%i i] s)
    =.  s  (tab-set id.tv [%i (sum:si i --1)] cur s)
    $(i (dif:si i --1))
  [~ (tab-set id.tv [%i pos] v s)]
++  bi-tremove
  |=  [args=(list value) s=store]
  ^-  [(list value) store]
  =/  tv  (arg 0 args)
  ?.  ?=(%t -.tv)  ~|(%lua-remove-non-table !!)
  =/  n  (tab-len id.tv s)
  ?:  =(n --0)  [~[[%nil ~]] s]
  =/  pos  ?:((gth (lent args) 1) (as-int (arg 1 args)) n)
  =/  val  (tab-get id.tv [%i pos] s)
  =/  i=@sd  pos
  =.  s
    |-  ^-  store
    ?.  =(-1 (cmp:si i n))  s
    =/  nx  (tab-get id.tv [%i (sum:si i --1)] s)
    =.  s  (tab-set id.tv [%i i] nx s)
    $(i (sum:si i --1))
  [~[val] (tab-set id.tv [%i n] [%nil ~] s)]
++  bi-tconcat
  |=  [args=(list value) s=store]
  ^-  value
  =/  tv  (arg 0 args)
  ?.  ?=(%t -.tv)  ~|(%lua-concat-non-table !!)
  =/  sep  ?:((gth (lent args) 1) (trip (as-str (arg 1 args))) "")
  =/  n  (tab-len id.tv s)
  =/  i=@sd  --1
  =/  acc=tape  ~
  |-  ^-  value
  ?:  =(--1 (cmp:si i n))  [%s (crip acc)]
  =/  piece  (tostr (tab-get id.tv [%i i] s) s)
  =/  acc2  ?:(=(i --1) piece (weld acc (weld sep piece)))
  $(acc acc2, i (sum:si i --1))
::                                                ::  ::  setup + run
++  setup
  |=  s=store
  ^-  store
  =.  glob.s
    %-  ~(gas by glob.s)
    ^-  (list [@t value])
    :~  ['print' [%fn %print]]
        ['type' [%fn %type]]
        ['tostring' [%fn %tostring]]
        ['tonumber' [%fn %tonumber]]
        ['pairs' [%fn %pairs]]
        ['ipairs' [%fn %ipairs]]
        ['next' [%fn %next]]
        ['select' [%fn %select]]
        ['assert' [%fn %assert]]
        ['error' [%fn %error]]
        ['rawget' [%fn %rawget]]
        ['rawequal' [%fn %rawequal]]
        ['rawlen' [%fn %rawlen]]
    ==
  =^  mid  s  (new-table s)
  =.  s  (tab-set mid [%s 'floor'] [%fn %mfloor] s)
  =.  s  (tab-set mid [%s 'ceil'] [%fn %mceil] s)
  =.  s  (tab-set mid [%s 'abs'] [%fn %mabs] s)
  =.  s  (tab-set mid [%s 'sqrt'] [%fn %msqrt] s)
  =.  s  (tab-set mid [%s 'max'] [%fn %mmax] s)
  =.  s  (tab-set mid [%s 'min'] [%fn %mmin] s)
  =.  s  (tab-set mid [%s 'pi'] [%f .~3.141592653589793] s)
  =.  glob.s  (~(put by glob.s) 'math' [%t mid])
  =^  sid  s  (new-table s)
  =.  s  (tab-set sid [%s 'len'] [%fn %slen] s)
  =.  s  (tab-set sid [%s 'sub'] [%fn %ssub] s)
  =.  s  (tab-set sid [%s 'rep'] [%fn %srep] s)
  =.  s  (tab-set sid [%s 'upper'] [%fn %supper] s)
  =.  s  (tab-set sid [%s 'lower'] [%fn %slower] s)
  =.  s  (tab-set sid [%s 'format'] [%fn %sformat] s)
  =.  glob.s  (~(put by glob.s) 'string' [%t sid])
  =^  tid  s  (new-table s)
  =.  s  (tab-set tid [%s 'insert'] [%fn %tinsert] s)
  =.  s  (tab-set tid [%s 'remove'] [%fn %tremove] s)
  =.  s  (tab-set tid [%s 'concat'] [%fn %tconcat] s)
  =.  glob.s  (~(put by glob.s) 'table' [%t tid])
  s
++  run
  |=  src=@t
  ^-  (list tape)
  =/  ast  (parse (lex (trip src)))
  =/  s  (setup init-store)
  =/  res  (do-stmts ;;((list stmt) ast) ~[~] ~ s)
  out:+.res
--

::  marker
