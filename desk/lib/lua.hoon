::  lua.hoon — a pragmatic-core Lua 5.4 interpreter in Hoon
::
::    a hand-written lexer + recursive-descent parser + tree-walking
::    interpreter.  numbers are int (@sd) or float (@rd) per Lua 5.4.
::    tables and variables are mutable via a shared store keyed by id;
::    closures capture lexical scope so upvalues work; metatables drive
::    operator/index overloading.
::
::    coroutines need true suspension, which a recursive tree-walker can't
::    give, so a coroutine body runs instead on a small CEK step machine
::    (see the "CEK machine" sections) whose continuation is reified as a
::    flat list and parked on yield.  the two evaluators share every leaf arm.
::
::    public arm:  (run src=@t) -> (list tape)   :: stdout lines
::
|%
::                                                ::  ::  types
+$  number  $%([%i p=@sd] [%f p=@rd])
+$  fspec
  $:  fm=?         :: '-'  left-justify
      fp=?         :: '+'  force sign
      fsp=?        :: ' '  space before positive
      fh=?         :: '#'  alternate form
      fz=?         :: '0'  zero-pad
      width=@ud
      prec=(unit @ud)
      conv=@t
  ==
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
      [%label name=@t]
      [%goto name=@t]
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
      [%co id=@ud]
  ==
::    a coroutine holds a SUSPENDED CEK MACHINE (its continuation/env/varargs),
::    so yield can suspend from any depth and resume re-enters exactly there.
::    cells/tabs/funs/glob stay global in the store and are shared across
::    resumes, so interleaved side effects persist (no replay).
+$  coro
  $:  fun=value                 :: body function
      status=?(%susp %dead %run)
      started=?
      ksave=kont                :: saved continuation stack
      esave=scope               :: saved env register
      vsave=(list value)        :: saved varargs register
  ==
+$  vkey  $%([%i p=@sd] [%f p=@rd] [%s p=@t] [%b p=?])
+$  ltable  (map vkey value)
+$  closure  [params=(list @t) vararg=? body=(list stmt) env=scope]
+$  frame  (map @t @ud)
+$  scope  (list frame)
+$  flow   $%([%norm ~] [%brk ~] [%ret vs=(list value)] [%goto name=@t])
+$  store
  $:  cells=(map @ud value)
      tabs=(map @ud ltable)
      funs=(map @ud closure)
      glob=(map @t value)
      metas=(map @ud @ud)
      coros=(map @ud coro)
      curco=(list @ud)
      next=@ud
      out=(list tape)
  ==
::                                                ::  ::  CEK machine molds
::    Control register: what the machine is doing this step.
+$  ctrl
  $%  [%ee e=*]                       :: eval expr -> single (head of vs)
      [%em e=*]                       :: eval expr -> value LIST
      [%el acc=(list value) es=(list *)]    :: eval expr-list (evl semantics)
      [%es whole=(list *) b=(list *)] :: exec stmt list (b=suffix, whole=for goto)
      [%sif clauses=(list *) els=(unit *)]  :: select an if-clause
      [%rv vs=(list value)]           :: a value-list produced -> feed top frame
      [%fl fl=flow]                   :: a block flow produced  -> feed top frame
      [%halt vs=(list value)]         :: body returned (machine done)
      [%yield vs=(list value)]        :: coroutine yielded; k holds resumption
  ==
::    One continuation frame.  dig:over RULE: a kframe NEVER embeds a kframe
::    (the rest-of-stack is the list tail) and AST children are `*`, so this
::    $% is flat (non-recursive) like flow/value and survives ?-/?=.
+$  kframe
  $%  [%sc op=@t r=*]                 :: and/or short-circuit: have L
      [%br op=@t r=*]                 :: binop: have L, eval R next
      [%bl op=@t l=value]             :: binop: have R, combine with L
      [%un op=@t]                     :: unop: have operand
      [%ik k=*]                       :: index: have table, eval key
      [%iv t=value]                   :: index: have key, do index-get
      [%cf args=(list *)]             :: call: have fn, eval arg-list
      [%mo m=@t args=(list *)]        :: method: have obj
      [%ca fn=value pre=(list value)] :: call: have fn(+self), eval'd args=rv
      [%lc acc=(list value) rest=(list *)]    :: %el accumulator
      [%ifc b=* more=(list *) els=(unit *)]   :: if: clause cond evaluated
      [%loc names=(list @t) whole=(list *) b=(list *)]   :: bind locals, continue
      [%asn tgts=(list *) whole=(list *) b=(list *)]     :: assign, continue
      [%kseq whole=(list *) b=(list *)]                  :: discard call-stmt
      [%ret ~]                        :: value-list -> %ret flow
      [%rt env=scope va=(list value) pre=@ud pf=@ud pt=@ud]   :: closure return
      [%cont env=scope whole=(list *) b=(list *)]        :: construct done
      [%nf v=@t i=@sd lim=@sd stp=@sd up=? cap=? body=(list *) e0=scope]
      [%whb c=* body=(list *) e0=scope]
      [%gfs names=(list @t) body=(list *) e0=scope]
      [%gfc names=(list @t) body=(list *) e0=scope f=value st=value]
      [%gfb names=(list @t) body=(list *) e0=scope f=value st=value ctl=value]
  ==
+$  kont    (list kframe)
+$  mstate  $:(c=ctrl k=kont env=scope va=(list value) s=store)
::    result of stepping a program run as a thread (see ++thread-step):
::    %done = the program returned; %yield = it called an effect builtin.
+$  tres
  $%  [%done vals=(list value) out=(list tape)]
      [%yield tag=@t args=(list value) out=(list tape)]
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
::                                                ::  ::  bitwise (64-bit)
++  bmask  ^-(@ (dec (bex 64)))
++  to-u64
  |=  i=@sd
  ^-  @
  ?:  (syn:si i)  (dis (abs:si i) bmask)
  (dis (sub (bex 64) (dis (abs:si i) bmask)) bmask)
++  from-u64
  |=  u=@
  ^-  @sd
  ?:  (lth u (bex 63))  (sun:si u)
  (new:si %.n (sub (bex 64) u))
++  lua-shl
  |=  [x=@ n=@sd]
  ^-  @
  ?:  (syn:si n)
    =/  k  (abs:si n)
    ?:  (gte k 64)  0
    (dis (lsh [0 k] x) bmask)
  =/  k  (abs:si n)
  ?:  (gte k 64)  0
  (rsh [0 k] x)
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
  ?:  &(=(c '<') =(d '<'))  [[%op '<<'] r2]
  ?:  &(=(c '>') =(d '>'))  [[%op '>>'] r2]
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
  ?:  (is-kw h 'break')   [[%break ~] (nx q)]
  ?:  (is-kw h 'function')  (parse-funcstmt (nx q))
  ?:  (is-kw h 'do')
    =/  r  (parse-block (nx q))
    [[%do p.r] (expect-kw q.r 'end')]
  ?:  (is-kw h 'goto')
    =/  h2  (hed (nx q))
    ?.  ?=(%name -.h2)  ~|(%lua-expected-goto-label !!)
    [[%goto p.h2] (nx (nx q))]
  ?:  (is-op h '::')
    =/  h2  (hed (nx q))
    ?.  ?=(%name -.h2)  ~|(%lua-expected-label-name !!)
    [[%label p.h2] (expect-op (nx (nx q)) '::')]
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
  ?:  =(s '|')  `4
  ?:  =(s '~')  `5
  ?:  =(s '&')  `6
  ?:  |(=(s '<<') =(s '>>'))  `7
  ?:  =(s '..')  `8
  ?:  |(=(s '+') =(s '-'))  `9
  ?:  ?|(=(s '*') =(s '/') =(s '//') =(s '%'))  `10
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
  ?:  |((is-kw h 'not') (is-op h '-') (is-op h '#') (is-op h '~'))
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
++  init-store  ^-(store [~ ~ ~ ~ ~ ~ ~ 0 ~])
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
    %co   ~|(%lua-table-key-unsupported !!)
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
  ?:  ?&(?=(%co -.a) ?=(%co -.b))  =(id.a id.b)
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
++  as-bint
  |=  v=value
  ^-  @sd
  ?:  ?=(%i -.v)  p.v
  ?.  ?=(%f -.v)  ~|(%lua-bitwise-on-non-integer !!)
  =/  u  (toi:rd p.v)
  ?~  u  ~|(%lua-number-has-no-integer-representation !!)
  ?.  (equ:rd p.v (i2f u.u))  ~|(%lua-number-has-no-integer-representation !!)
  u.u
++  bitwise
  |=  [op=@t a=value b=value]
  ^-  value
  =/  x  (to-u64 (as-bint a))
  ?:  =(op '<<')  [%i (from-u64 (lua-shl x (as-bint b)))]
  ?:  =(op '>>')  [%i (from-u64 (lua-shl x (dif:si --0 (as-bint b))))]
  =/  y  (to-u64 (as-bint b))
  ?:  =(op '&')  [%i (from-u64 (dis x y))]
  ?:  =(op '|')  [%i (from-u64 (con x y))]
  ?:  =(op '~')  [%i (from-u64 (mix x y))]
  ~|([%lua-bad-bitwise op] !!)
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
    %co   (weld "thread: " (scow %ux id.v))
  ==
::                                                ::  ::  metamethods
++  mm-lookup
  |=  [v=value name=@t s=store]
  ^-  value
  ?.  ?=(%t -.v)  [%nil ~]
  =/  mid  (~(get by metas.s) id.v)
  ?~  mid  [%nil ~]
  (tab-get u.mid [%s name] s)
++  bin-mm
  |=  [name=@t a=value b=value s=store]
  ^-  (unit value)
  =/  h  (mm-lookup a name s)
  ?.  ?=(%nil -.h)  `h
  =/  h2  (mm-lookup b name s)
  ?.  ?=(%nil -.h2)  `h2
  ~
++  arith-mm-name
  |=  op=@t
  ^-  @t
  ?:  =(op '+')   '__add'
  ?:  =(op '-')   '__sub'
  ?:  =(op '*')   '__mul'
  ?:  =(op '/')   '__div'
  ?:  =(op '%')   '__mod'
  ?:  =(op '^')   '__pow'
  ?:  =(op '//')  '__idiv'
  '__add'
++  index-get
  |=  [tv=value k=value s=store]
  ^-  [value store]
  ?.  ?=(%t -.tv)  ~|([%lua-index-non-table -.tv] !!)
  =/  raw  (tab-get id.tv k s)
  ?.  ?=(%nil -.raw)  [raw s]
  =/  mid  (~(get by metas.s) id.tv)
  ?~  mid  [[%nil ~] s]
  =/  h  (tab-get u.mid [%s '__index'] s)
  ?:  ?=(%nil -.h)  [[%nil ~] s]
  ?:  ?=(%t -.h)  (index-get h k s)
  ?:  ?|(?=(%c -.h) ?=(%fn -.h))
    =^  rs  s  (apply h ~[tv k] s)
    [?~(rs [%nil ~] i.rs) s]
  [[%nil ~] s]
++  index-set
  |=  [tv=value k=value v=value s=store]
  ^-  store
  ?.  ?=(%t -.tv)  ~|(%lua-assign-index-non-table !!)
  =/  raw  (tab-get id.tv k s)
  ?.  ?=(%nil -.raw)  (tab-set id.tv k v s)
  =/  mid  (~(get by metas.s) id.tv)
  ?~  mid  (tab-set id.tv k v s)
  =/  h  (tab-get u.mid [%s '__newindex'] s)
  ?:  ?=(%nil -.h)  (tab-set id.tv k v s)
  ?:  ?=(%t -.h)  (index-set h k v s)
  ?:  ?|(?=(%c -.h) ?=(%fn -.h))
    =^  rs  s  (apply h ~[tv k v] s)
    s
  (tab-set id.tv k v s)
++  do-arith
  |=  [op=@t a=value b=value s=store]
  ^-  [value store]
  ?:  ?|(?=(%t -.a) ?=(%t -.b))
    =/  h  (bin-mm (arith-mm-name op) a b s)
    ?~  h  ~|([%lua-arith-on-non-number op] !!)
    =^  rs  s  (apply u.h ~[a b] s)
    [?~(rs [%nil ~] i.rs) s]
  [(arith op a b) s]
++  do-concat
  |=  [a=value b=value s=store]
  ^-  [value store]
  ?:  ?|(?=(%t -.a) ?=(%t -.b))
    =/  h  (bin-mm '__concat' a b s)
    ?~  h  ~|(%lua-concat-non-string !!)
    =^  rs  s  (apply u.h ~[a b] s)
    [?~(rs [%nil ~] i.rs) s]
  [(concat a b) s]
++  do-compare
  |=  [op=@t a=value b=value s=store]
  ^-  [value store]
  ?:  ?|(=(op '==') =(op '~='))
    =/  raw  (val-eq a b)
    ?:  ?&(!raw ?=(%t -.a) ?=(%t -.b))
      =/  h  (mm-lookup a '__eq' s)
      =.  h  ?:(?=(%nil -.h) (mm-lookup b '__eq' s) h)
      ?:  ?=(%nil -.h)  [[%b ?:(=(op '==') %.n %.y)] s]
      =^  rs  s  (apply h ~[a b] s)
      =/  res  (truthy ?~(rs [%nil ~] i.rs))
      [[%b ?:(=(op '==') res !res)] s]
    [[%b ?:(=(op '==') raw !raw)] s]
  ?:  ?|(?=(%t -.a) ?=(%t -.b))
    =/  le=?    ?|(=(op '<=') =(op '>='))
    =/  swap=?  ?|(=(op '>') =(op '>='))
    =/  mm=@t   ?:(le '__le' '__lt')
    =/  lhs  ?:(swap b a)
    =/  rhs  ?:(swap a b)
    =/  h  (bin-mm mm lhs rhs s)
    ?~  h  ~|([%lua-compare-no-metamethod op] !!)
    =^  rs  s  (apply u.h ~[lhs rhs] s)
    [[%b (truthy ?~(rs [%nil ~] i.rs))] s]
  [(compare op a b) s]
++  do-tostr
  |=  [v=value s=store]
  ^-  [tape store]
  ?.  ?=(%t -.v)  [(tostr v s) s]
  =/  h  (mm-lookup v '__tostring' s)
  ?:  ?=(%nil -.h)  [(tostr v s) s]
  =^  rs  s  (apply h ~[v] s)
  =/  r  ?~(rs [%nil ~] i.rs)
  [(tostr r s) s]
++  tostr-args
  |=  [args=(list value) s=store]
  ^-  [(list tape) store]
  ?~  args  [~ s]
  =^  p  s  (do-tostr i.args s)
  =^  rest  s  $(args t.args)
  [[p rest] s]
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
    (index-get tv kv s)
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
  (binop-apply op l r s)
++  binop-apply
  |=  [op=@t l=value r=value s=store]
  ^-  [value store]
  ?:  =(op '..')  (do-concat l r s)
  ?:  ?|(=(op '==') =(op '~=') =(op '<') =(op '>') =(op '<=') =(op '>='))
    (do-compare op l r s)
  ?:  ?|(=(op '&') =(op '|') =(op '~') =(op '<<') =(op '>>'))
    [(bitwise op l r) s]
  (do-arith op l r s)
++  ev-unop
  |=  [ex=* env=scope va=(list value) s=store]
  ^-  [value store]
  =/  e  ;;(expr ex)
  ?>  ?=(%unop -.e)
  =^  v  s  (ev e.e env va s)
  (unop-apply op.e v s)
++  unop-apply
  |=  [op=@t v=value s=store]
  ^-  [value store]
  ?:  =(op 'not')  [[%b !(truthy v)] s]
  ?:  =(op '-')
    ?:  ?=(%i -.v)  [[%i (dif:si --0 p.v)] s]
    ?:  ?=(%f -.v)  [[%f (sub:rd .~0 p.v)] s]
    ?:  ?=(%t -.v)
      =/  h  (mm-lookup v '__unm' s)
      ?.  ?=(%nil -.h)
        =^  rs  s  (apply h ~[v v] s)
        [?~(rs [%nil ~] i.rs) s]
      ~|(%lua-unary-minus-non-number !!)
    ~|(%lua-unary-minus-non-number !!)
  ?:  =(op '~')
    [[%i (from-u64 (mix bmask (to-u64 (as-bint v))))] s]
  ?:  ?=(%s -.v)  [[%i (sun:si (lent (trip p.v)))] s]
  ?:  ?=(%t -.v)
    =/  h  (mm-lookup v '__len' s)
    ?.  ?=(%nil -.h)
      =^  rs  s  (apply h ~[v] s)
      [?~(rs [%nil ~] i.rs) s]
    [[%i (tab-len id.v s)] s]
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
    =^  fnv  s  (index-get ov [%s m.e] s)
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
  ?:  ?=(%t -.fnv)
    =/  h  (mm-lookup fnv '__call' s)
    ?:  ?=(%nil -.h)  ~|([%lua-call-non-function -.fnv] !!)
    (apply h [fnv args] s)
  ~|([%lua-call-non-function -.fnv] !!)
++  bind-params
  |=  [cl=closure args=(list value) s=store]
  ^-  [scope store]
  =/  env2=scope  [*frame env.cl]
  =/  ps  params.cl
  =/  as  args
  |-  ^-  [scope store]
  ?~  ps  [env2 s]
  =/  eo  (decl i.ps ?~(as [%nil ~] i.as) env2 s)
  $(ps t.ps, as ?~(as ~ t.as), env2 -.eo, s +.eo)
++  call-closure
  |=  [cl=closure args=(list value) s=store]
  ^-  [(list value) store]
  ::  record allocation state so we can reclaim this call's cells on return
  =/  pre=@ud       next.s
  =/  pre-funs=@ud  ~(wyt by funs.s)
  =/  pre-tabs=@ud  ~(wyt by tabs.s)
  =^  env2  s  (bind-params cl args s)
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
    %goto  ~|([%lua-no-visible-label name.fl] !!)
    %norm  [~ s2]
  ==
++  prune-cells
  |=  [m=(map @ud value) lo=@ud hi=@ud]
  ^-  (map @ud value)
  ?:  =(lo hi)  m
  $(m (~(del by m) lo), lo +(lo))
::                                                ::  ::  statements
::  return the suffix of a block starting AT the matching label, else ~
++  find-label
  |=  [b=(list stmt) nm=@t]
  ^-  (unit (list stmt))
  ?~  b  ~
  ?:  ?&(?=(%label -.i.b) =(name.i.b nm))  `b
  $(b t.b)
++  do-stmts
  ::  takes an already-clammed statement list, so blocks executed
  ::  repeatedly (loop bodies, called functions) are not re-clammed.
  |=  [b=(list stmt) env=scope va=(list value) s=store]
  ^-  [flow store]
  =/  whole  b
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
      %label  $(b t.b)
  ::
      %goto
    =/  tgt  (find-label whole name.st)
    ?~  tgt  [[%goto name.st] s]
    $(b u.tgt)
  ::
      %do
    =/  res  (do-stmts ;;((list stmt) body.st) env va s)
    ?:  ?=(%norm -.-.res)  $(b t.b, s +.res)
    ?.  ?=(%goto -.-.res)  res
    =/  tgt  (find-label whole name.-.res)
    ?~  tgt  res
    $(b u.tgt, s +.res)
  ::
      %while
    =/  res  (do-while c.st body.st env va s)
    ?:  ?=(%norm -.-.res)  $(b t.b, s +.res)
    ?.  ?=(%goto -.-.res)  res
    =/  tgt  (find-label whole name.-.res)
    ?~  tgt  res
    $(b u.tgt, s +.res)
  ::
      %repeat
    =/  res  (do-repeat body.st c.st env va s)
    ?:  ?=(%norm -.-.res)  $(b t.b, s +.res)
    ?.  ?=(%goto -.-.res)  res
    =/  tgt  (find-label whole name.-.res)
    ?~  tgt  res
    $(b u.tgt, s +.res)
  ::
      %if
    =/  res  (do-if clauses.st els.st env va s)
    ?:  ?=(%norm -.-.res)  $(b t.b, s +.res)
    ?.  ?=(%goto -.-.res)  res
    =/  tgt  (find-label whole name.-.res)
    ?~  tgt  res
    $(b u.tgt, s +.res)
  ::
      %numfor
    =/  res  (do-numfor st env va s)
    ?:  ?=(%norm -.-.res)  $(b t.b, s +.res)
    ?.  ?=(%goto -.-.res)  res
    =/  tgt  (find-label whole name.-.res)
    ?~  tgt  res
    $(b u.tgt, s +.res)
  ::
      %genfor
    =/  res  (do-genfor st env va s)
    ?:  ?=(%norm -.-.res)  $(b t.b, s +.res)
    ?.  ?=(%goto -.-.res)  res
    =/  tgt  (find-label whole name.-.res)
    ?~  tgt  res
    $(b u.tgt, s +.res)
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
    =.  s  (index-set tv kv val s)
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
    %goto  res
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
    %goto  res
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
::  loop-capture analysis: does a block/expr contain a %func (closure)?
::  children are `*`, so clam each node back to its mold before matching.
++  blk-has-func
  |=  b=(list stmt)
  ^-  ?
  ?~  b  %.n
  ?:  (stmt-has-func i.b)  %.y
  $(b t.b)
++  stmt-has-func
  |=  st=stmt
  ^-  ?
  ?-  -.st
      %local      (exprs-have-func exprs.st)
      %localfunc  %.y
      %assign     |((exprs-have-func targets.st) (exprs-have-func exprs.st))
      %call       (expr-has-func e.st)
      %do         (blk-has-func ;;((list stmt) body.st))
      %while      |((expr-has-func c.st) (blk-has-func ;;((list stmt) body.st)))
      %repeat     |((blk-has-func ;;((list stmt) body.st)) (expr-has-func c.st))
      %if         (if-has-func clauses.st els.st)
  ::
      %numfor
    ?|  (expr-has-func from.st)
        (expr-has-func to.st)
        ?~(step.st %.n (expr-has-func u.step.st))
        (blk-has-func ;;((list stmt) body.st))
    ==
  ::
      %genfor   |((exprs-have-func exprs.st) (blk-has-func ;;((list stmt) body.st)))
      %return   (exprs-have-func exprs.st)
      %label    %.n
      %goto     %.n
      %break    %.n
  ==
++  if-has-func
  |=  [clauses=(list [c=* b=*]) els=(unit *)]
  ^-  ?
  ?:  ?&(?=(^ els) (blk-has-func ;;((list stmt) u.els)))  %.y
  |-  ^-  ?
  ?~  clauses  %.n
  ?:  (expr-has-func c.i.clauses)  %.y
  ?:  (blk-has-func ;;((list stmt) b.i.clauses))  %.y
  $(clauses t.clauses)
++  exprs-have-func
  |=  es=(list *)
  ^-  ?
  ?~  es  %.n
  ?:  (expr-has-func i.es)  %.y
  $(es t.es)
++  fields-have-func
  |=  fs=(list *)
  ^-  ?
  ?~  fs  %.n
  =/  f  ;;(tfield i.fs)
  =/  hit=?
    ?-  -.f
      %pos   (expr-has-func v.f)
      %key   |((expr-has-func k.f) (expr-has-func v.f))
      %name  (expr-has-func v.f)
    ==
  ?:  hit  %.y
  $(fs t.fs)
++  expr-has-func
  |=  ex=*
  ^-  ?
  =/  e  ;;(expr ex)
  ?-  -.e
    %nil     %.n
    %true    %.n
    %false   %.n
    %int     %.n
    %flt     %.n
    %str     %.n
    %vararg  %.n
    %name    %.n
    %paren   (expr-has-func e.e)
    %index   |((expr-has-func t.e) (expr-has-func k.e))
    %call    |((expr-has-func f.e) (exprs-have-func args.e))
    %method  |((expr-has-func o.e) (exprs-have-func args.e))
    %func    %.y
    %table   (fields-have-func fields.e)
    %binop   |((expr-has-func l.e) (expr-has-func r.e))
    %unop    (expr-has-func e.e)
  ==
++  do-numfor
  |=  [st=stmt env=scope va=(list value) s=store]
  ^-  [flow store]
  ?>  ?=(%numfor -.st)
  =/  body  ;;((list stmt) body.st)
  =/  cap   (blk-has-func body)
  =^  fromv  s  (ev from.st env va s)
  =^  tov  s  (ev to.st env va s)
  =^  stepv  s  ?~(step.st [`value`[%i --1] s] (ev u.step.st env va s))
  ?:  ?&(?=(%i -.fromv) ?=(%i -.tov) ?=(%i -.stepv))
    =/  i=@sd  p.fromv
    =/  lim=@sd  p.tov
    =/  stp=@sd  p.stepv
    =/  up=?  (syn:si stp)
    ::  Lua 5.4: fresh cell per iteration only when the body may capture the
    ::  loop var in a closure; otherwise reuse one cell (bounded store).
    ?:  cap
      |-  ^-  [flow store]
      ?.  ?:(up (sle i lim) (sge i lim))  [[%norm ~] s]
      =^  env2  s  (decl v.st [%i i] env s)
      =/  res  (do-stmts body env2 va s)
      ?-  -.-.res
        %brk   [[%norm ~] +.res]
        %ret   res
        %goto  res
        %norm  $(i (sum:si i stp), s +.res)
      ==
    =^  env2  s  (decl v.st [%i i] env s)
    |-  ^-  [flow store]
    ?.  ?:(up (sle i lim) (sge i lim))  [[%norm ~] s]
    =.  s  (set-var v.st [%i i] env2 s)
    =/  res  (do-stmts body env2 va s)
    ?-  -.-.res
      %brk   [[%norm ~] +.res]
      %ret   res
      %goto  res
      %norm  $(i (sum:si i stp), s +.res)
    ==
  =/  x=@rd  (toflt (as-num fromv))
  =/  lim=@rd  (toflt (as-num tov))
  =/  stp=@rd  (toflt (as-num stepv))
  =/  up=?  !(lth:rd stp .~0)
  ?:  cap
    |-  ^-  [flow store]
    ?.  ?:(up (rlte x lim) (rgte x lim))  [[%norm ~] s]
    =^  env2  s  (decl v.st [%f x] env s)
    =/  res  (do-stmts body env2 va s)
    ?-  -.-.res
      %brk   [[%norm ~] +.res]
      %ret   res
      %goto  res
      %norm  $(x (add:rd x stp), s +.res)
    ==
  =^  env2  s  (decl v.st [%f x] env s)
  |-  ^-  [flow store]
  ?.  ?:(up (rlte x lim) (rgte x lim))  [[%norm ~] s]
  =.  s  (set-var v.st [%f x] env2 s)
  =/  res  (do-stmts body env2 va s)
  ?-  -.-.res
    %brk   [[%norm ~] +.res]
    %ret   res
    %goto  res
    %norm  $(x (add:rd x stp), s +.res)
  ==
++  do-genfor
  |=  [st=stmt env=scope va=(list value) s=store]
  ^-  [flow store]
  ?>  ?=(%genfor -.st)
  =/  body  ;;((list stmt) body.st)
  =/  cap   (blk-has-func body)
  =^  vals  s  (evl exprs.st env va s)
  =/  f  (arg 0 vals)
  =/  st8  (arg 1 vals)
  =/  ctrl  (arg 2 vals)
  ?:  cap
    ::  Lua 5.4: rebind the loop vars from the outer scope each iteration.
    |-  ^-  [flow store]
    =^  rets  s  (apply f ~[st8 ctrl] s)
    =/  first  ?~(rets [%nil ~] i.rets)
    ?:  ?=(%nil -.first)  [[%norm ~] s]
    =.  ctrl  first
    =^  env2  s  (bind-locals names.st rets env s)
    =/  res  (do-stmts body env2 va s)
    ?-  -.-.res
      %brk   [[%norm ~] +.res]
      %ret   res
      %goto  res
      %norm  $(s +.res)
    ==
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
    %goto  res
    %norm  $(s +.res)
  ==
::                                                ::  ::  CEK machine (coroutines)
::    A resumable step machine used ONLY to run coroutine bodies, so yield can
::    suspend from any depth.  The main thread keeps using the tree-walker.
::    All Lua *semantics* are delegated to the shared leaf arms (binop-apply,
::    index-get, call-builtin, ...); the machine only reifies *control*.
::    Every machine mold is a FLAT $% (frames never embed frames; the rest of
::    the stack is the list tail), so none are self-recursive -> no dig:over.
++  expr-has-call
  |=  ex=*
  ^-  ?
  =/  e  ;;(expr ex)
  ?-  -.e
    %nil  %.n   %true  %.n   %false  %.n   %int  %.n   %flt  %.n
    %str  %.n   %vararg  %.n   %name  %.n   %func  %.n
    %paren  (expr-has-call e.e)
    %index  |((expr-has-call t.e) (expr-has-call k.e))
    %call   %.y
    %method  %.y
    %table  (fields-have-call fields.e)
    %binop  |((expr-has-call l.e) (expr-has-call r.e))
    %unop   (expr-has-call e.e)
  ==
++  fields-have-call
  |=  fs=(list *)
  ^-  ?
  ?~  fs  %.n
  =/  f  ;;(tfield i.fs)
  =/  hit=?
    ?-  -.f
      %pos   (expr-has-call v.f)
      %key   |((expr-has-call k.f) (expr-has-call v.f))
      %name  (expr-has-call v.f)
    ==
  ?:  hit  %.y
  $(fs t.fs)
::  does a statement / block contain a CALL anywhere (so it could yield)?
++  blk-has-call
  |=  b=(list *)
  ^-  ?
  ?~  b  %.n
  ?:  (stmt-has-call i.b)  %.y
  $(b t.b)
++  stmt-has-call
  |=  st1=*
  ^-  ?
  =/  st  ;;(stmt st1)
  ?-  -.st
      %local      (exprs-have-call exprs.st)
      %localfunc  (expr-has-call f.st)
      %assign     |((exprs-have-call targets.st) (exprs-have-call exprs.st))
      %call       %.y
      %do         (blk-has-call ;;((list *) body.st))
      %while      |((expr-has-call c.st) (blk-has-call ;;((list *) body.st)))
      %repeat     |((blk-has-call ;;((list *) body.st)) (expr-has-call c.st))
      %if         (if-has-call clauses.st els.st)
  ::
      %numfor
    ?|  (expr-has-call from.st)
        (expr-has-call to.st)
        ?~(step.st %.n (expr-has-call u.step.st))
        (blk-has-call ;;((list *) body.st))
    ==
  ::
      %genfor   |((exprs-have-call exprs.st) (blk-has-call ;;((list *) body.st)))
      %return   (exprs-have-call exprs.st)
      %label    %.n
      %goto     %.n
      %break    %.n
  ==
++  if-has-call
  |=  [clauses=(list [c=* b=*]) els=(unit *)]
  ^-  ?
  ?:  ?&(?=(^ els) (blk-has-call ;;((list *) u.els)))  %.y
  |-  ^-  ?
  ?~  clauses  %.n
  ?:  (expr-has-call c.i.clauses)  %.y
  ?:  (blk-has-call ;;((list *) b.i.clauses))  %.y
  $(clauses t.clauses)
++  exprs-have-call
  |=  es=(list *)
  ^-  ?
  ?~  es  %.n
  ?:  (expr-has-call i.es)  %.y
  $(es t.es)
++  run-mach
  |=  m=mstate
  ^-  mstate
  ?:  ?|(?=(%halt -.c.m) ?=(%yield -.c.m))  m
  $(m (step m))
++  step
  |=  m=mstate
  ^-  mstate
  ?-  -.c.m
    %ee     (step-ee m)
    %em     (step-em m)
    %el     (step-el m)
    %es     (step-es m)
    %sif    (step-sif m)
    %rv     (step-rv m)
    %fl     (step-fl m)
    %halt   m
    %yield  m
  ==
::  eval expr to a single value (consumer takes head of the rv list)
++  step-ee
  |=  m=mstate
  ^-  mstate
  ?>  ?=(%ee -.c.m)
  =/  e  ;;(expr e.c.m)
  ::  a subtree with no call can't suspend: evaluate it atomically (fast path).
  ?.  (expr-has-call e)
    =^  v  s.m  (ev e env.m va.m s.m)
    m(c [%rv ~[v]])
  ::  only call-containing compounds reach here; everything else hit the
  ::  fast path above, so the default just delegates to the tree-walker.
  ?+  -.e  =^(v s.m (ev e env.m va.m s.m) m(c [%rv ~[v]]))
    %paren   m(c [%ee e.e])
    %call    m(c [%em e])
    %method  m(c [%em e])
    %index   m(c [%ee t.e], k [[%ik k.e] k.m])
    %unop    m(c [%ee e.e], k [[%un op.e] k.m])
    %table   ~|(%lua-yield-in-table-unsupported !!)
  ::
      %binop
    ?:  ?|(=(op.e 'and') =(op.e 'or'))  m(c [%ee l.e], k [[%sc op.e r.e] k.m])
    m(c [%ee l.e], k [[%br op.e r.e] k.m])
  ==
::  eval expr to a value LIST (call/method expand; vararg)
++  step-em
  |=  m=mstate
  ^-  mstate
  ?>  ?=(%em -.c.m)
  =/  e  ;;(expr e.c.m)
  ?:  ?=(%vararg -.e)  m(c [%rv va.m])
  ?.  (expr-has-call e)
    =^  vs  s.m  (evm e env.m va.m s.m)
    m(c [%rv vs])
  ?:  ?=(%call -.e)    m(c [%ee f.e], k [[%cf args.e] k.m])
  ?:  ?=(%method -.e)  m(c [%ee o.e], k [[%mo m.e args.e] k.m])
  m(c [%ee e])
::  eval an expr-list to a value-list (evl semantics: last item multi-expands)
++  step-el
  |=  m=mstate
  ^-  mstate
  ?>  ?=(%el -.c.m)
  =/  es  es.c.m
  ?~  es  m(c [%rv acc.c.m])
  ?~  t.es  m(c [%em i.es], k [[%lc acc.c.m ~] k.m])
  m(c [%ee i.es], k [[%lc acc.c.m t.es] k.m])
::  execute a statement list
++  step-es
  |=  m=mstate
  ^-  mstate
  ?>  ?=(%es -.c.m)
  =/  whole  whole.c.m
  ?~  b.c.m  m(c [%fl [%norm ~]])
  =/  st  ;;(stmt i.b.c.m)
  =/  rest  t.b.c.m
  ?-  -.st
      %local   m(c [%el ~ exprs.st], k [[%loc names.st whole rest] k.m])
      %assign  m(c [%el ~ exprs.st], k [[%asn targets.st whole rest] k.m])
      %call    m(c [%em e.st], k [[%kseq whole rest] k.m])
      %return  m(c [%el ~ exprs.st], k [[%ret ~] k.m])
      %break   m(c [%fl [%brk ~]])
      %label   m(c [%es whole rest])
  ::
      %goto
    =/  tgt  (find-label ;;((list stmt) whole) name.st)
    ?~  tgt  m(c [%fl [%goto name.st]])
    m(c [%es whole `(list *)`u.tgt])
  ::
      %do
    m(c [%es ;;((list stmt) body.st) ;;((list stmt) body.st)], k [[%cont env.m whole rest] k.m])
  ::
      %if
    m(c [%sif clauses.st els.st], k [[%cont env.m whole rest] k.m])
  ::
      %while
    =/  body  ;;((list stmt) body.st)
    ?.  (blk-has-call body)
      =/  res  (do-while c.st body.st env.m va.m s.m)
      m(c [%fl -.res], s +.res, k [[%cont env.m whole rest] k.m])
    m(c [%fl [%norm ~]], k [[%whb c.st body env.m] [[%cont env.m whole rest] k.m]])
  ::
      %numfor
    =/  body  ;;((list stmt) body.st)
    ?.  (blk-has-call body)
      =/  res  (do-numfor st env.m va.m s.m)
      m(c [%fl -.res], s +.res, k [[%cont env.m whole rest] k.m])
    (nfor-init st env.m [[%cont env.m whole rest] k.m] m)
  ::
      %repeat
    =/  res  (do-repeat body.st c.st env.m va.m s.m)
    m(c [%fl -.res], s +.res, k [[%cont env.m whole rest] k.m])
  ::
      %genfor
    =/  body  ;;((list *) body.st)
    ?.  (blk-has-call body)
      =/  res  (do-genfor st env.m va.m s.m)
      m(c [%fl -.res], s +.res, k [[%cont env.m whole rest] k.m])
    m(c [%el ~ exprs.st], k [[%gfs names.st body env.m] [[%cont env.m whole rest] k.m]])
  ::
      %localfunc
    =/  eo  (bind-locals ~[name.st] ~[[%nil ~]] env.m s.m)
    =.  env.m  -.eo
    =.  s.m  +.eo
    =^  fv  s.m  (ev f.st env.m va.m s.m)
    =.  s.m  (set-var name.st fv env.m s.m)
    m(c [%es whole rest])
  ==
::  select an if-clause
++  step-sif
  |=  m=mstate
  ^-  mstate
  ?>  ?=(%sif -.c.m)
  ?~  clauses.c.m
    ?~  els.c.m  m(c [%fl [%norm ~]])
    m(c [%es ;;((list stmt) u.els.c.m) ;;((list stmt) u.els.c.m)])
  =/  cl  ;;([c=* b=*] i.clauses.c.m)
  m(c [%ee c.cl], k [[%ifc b.cl t.clauses.c.m els.c.m] k.m])
::  consume a produced value-list: feed the top frame
++  step-rv
  |=  m=mstate
  ^-  mstate
  ?>  ?=(%rv -.c.m)
  =/  rv  vs.c.m
  ?~  k.m  m(c [%halt rv])
  =/  fr=kframe  i.k.m
  =/  kr=kont  t.k.m
  =/  hd  ?~(rv [%nil ~] i.rv)
  ?+  -.fr  ~|([%lua-bad-rv-frame -.fr] !!)
      %sc
    ?:  =(op.fr 'and')
      ?:((truthy hd) m(c [%ee r.fr], k kr) m(c [%rv ~[hd]], k kr))
    ?:((truthy hd) m(c [%rv ~[hd]], k kr) m(c [%ee r.fr], k kr))
  ::
      %br   m(c [%ee r.fr], k [[%bl op.fr hd] kr])
      %bl   =^(res s.m (binop-apply op.fr l.fr hd s.m) m(c [%rv ~[res]], k kr))
      %un   =^(res s.m (unop-apply op.fr hd s.m) m(c [%rv ~[res]], k kr))
      %ik   m(c [%ee k.fr], k [[%iv hd] kr])
      %iv   =^(res s.m (index-get t.fr hd s.m) m(c [%rv ~[res]], k kr))
      %cf   m(c [%el ~ args.fr], k [[%ca hd ~] kr])
      %mo
    =^  fnv  s.m  (index-get hd [%s m.fr] s.m)
    m(c [%el ~ args.fr], k [[%ca fnv ~[hd]] kr])
  ::
      %ca   (enter-call fn.fr (weld pre.fr rv) m(k kr))
      %lc
    ?~  rest.fr  m(c [%rv (weld acc.fr rv)], k kr)
    =/  acc2  (snoc acc.fr hd)
    ?~  t.rest.fr  m(c [%em i.rest.fr], k [[%lc acc2 ~] kr])
    m(c [%ee i.rest.fr], k [[%lc acc2 t.rest.fr] kr])
  ::
      %ifc
    ?:  (truthy hd)
      m(c [%es ;;((list stmt) b.fr) ;;((list stmt) b.fr)], k kr)
    m(c [%sif more.fr els.fr], k kr)
  ::
      %loc
    =/  env2  (bind-locals names.fr rv env.m s.m)
    m(c [%es whole.fr b.fr], env -.env2, s +.env2, k kr)
  ::
      %asn
    =.  s.m  (do-assign tgts.fr rv env.m va.m s.m)
    m(c [%es whole.fr b.fr], k kr)
  ::
      %kseq   m(c [%es whole.fr b.fr], k kr)
      %ret    m(c [%fl [%ret rv]], k kr)
  ::
      %gfs
    =/  f  (arg 0 rv)
    =/  st8  (arg 1 rv)
    =/  ctl  (arg 2 rv)
    (enter-call f ~[st8 ctl] m(k [[%gfc names.fr body.fr e0.fr f st8] kr]))
  ::
      %gfc
    ?:  ?=(%nil -.hd)  m(c [%fl [%norm ~]], k kr)
    =/  env2  (bind-locals names.fr rv e0.fr s.m)
    m(c [%es body.fr body.fr], env -.env2, s +.env2, k [[%gfb names.fr body.fr e0.fr f.fr st.fr hd] kr])
  ==
::  consume a produced flow: feed the top flow-frame
++  step-fl
  |=  m=mstate
  ^-  mstate
  ?>  ?=(%fl -.c.m)
  =/  fl  fl.c.m
  ?~  k.m  m(c [%halt ~])
  =/  fr=kframe  i.k.m
  =/  kr=kont  t.k.m
  ?+  -.fr  ~|([%lua-bad-fl-frame -.fr] !!)
      %rt
    =.  s.m
      ?.  &(=(pf.fr ~(wyt by funs.s.m)) =(pt.fr ~(wyt by tabs.s.m)))  s.m
      s.m(next pre.fr, cells (prune-cells cells.s.m pre.fr next.s.m))
    ?-  -.fl
      %ret   m(c [%rv vs.fl], env env.fr, va va.fr, k kr)
      %norm  m(c [%rv ~], env env.fr, va va.fr, k kr)
      %brk   ~|(%lua-break-outside-loop !!)
      %goto  ~|([%lua-no-visible-label name.fl] !!)
    ==
  ::
      %cont
    ?-  -.fl
        %norm  m(c [%es whole.fr b.fr], env env.fr, k kr)
        %brk   m(c [%fl [%brk ~]], k kr)
        %ret   m(c [%fl [%ret vs.fl]], k kr)
        %goto
      =/  tgt  (find-label ;;((list stmt) whole.fr) name.fl)
      ?~  tgt  m(c [%fl [%goto name.fl]], k kr)
      m(c [%es whole.fr `(list *)`u.tgt], env env.fr, k kr)
    ==
  ::
      %nf
    ?-  -.fl
      %ret   m(c [%fl [%ret vs.fl]], k kr)
      %goto  m(c [%fl [%goto name.fl]], k kr)
      %brk   m(c [%fl [%norm ~]], env e0.fr, k kr)
        %norm
      =/  ni  (sum:si i.fr stp.fr)
      (nfor-step fr(i ni) kr m)
    ==
  ::
      %whb
    ?-  -.fl
      %ret   m(c [%fl [%ret vs.fl]], k kr)
      %goto  m(c [%fl [%goto name.fl]], k kr)
      %brk   m(c [%fl [%norm ~]], env e0.fr, k kr)
      %norm  (while-step c.fr body.fr e0.fr kr m)
    ==
  ::
      %gfb
    ?-  -.fl
      %ret   m(c [%fl [%ret vs.fl]], k kr)
      %goto  m(c [%fl [%goto name.fl]], k kr)
      %brk   m(c [%fl [%norm ~]], env e0.fr, k kr)
        %norm
      (enter-call f.fr ~[st.fr ctl.fr] m(env e0.fr, k [[%gfc names.fr body.fr e0.fr f.fr st.fr] kr]))
    ==
  ==
::  start a machine numeric-for (body has a call): set up loop var, first test
++  nfor-init
  |=  [st=stmt env=scope kr=kont m=mstate]
  ^-  mstate
  ?>  ?=(%numfor -.st)
  =/  body  ;;((list stmt) body.st)
  =/  cap   (blk-has-func body)
  =^  fromv  s.m  (ev from.st env va.m s.m)
  =^  tov  s.m  (ev to.st env va.m s.m)
  =^  stepv  s.m  ?~(step.st [`value`[%i --1] s.m] (ev u.step.st env va.m s.m))
  ?>  ?&(?=(%i -.fromv) ?=(%i -.tov) ?=(%i -.stepv))
  =/  fr=kframe
    [%nf v.st p.fromv p.tov p.stepv (syn:si p.stepv) cap body env]
  (nfor-step fr kr m)
::  one numeric-for iteration (or finish)
++  nfor-step
  |=  [fr=kframe kr=kont m=mstate]
  ^-  mstate
  ?>  ?=(%nf -.fr)
  ?.  ?:(up.fr (sle i.fr lim.fr) (sge i.fr lim.fr))
    m(c [%fl [%norm ~]], env e0.fr, k kr)
  =^  env2  s.m
    ?:  cap.fr  (decl v.fr [%i i.fr] e0.fr s.m)
    [e0.fr (set-var v.fr [%i i.fr] e0.fr s.m)]
  m(c [%es body.fr body.fr], env env2, k [fr kr])
::  one while iteration: test condition, run body or exit
++  while-step
  |=  [c=* body=(list *) e0=scope kr=kont m=mstate]
  ^-  mstate
  =^  cv  s.m  (ev c e0 va.m s.m)
  ?.  (truthy cv)  m(c [%fl [%norm ~]], env e0, k kr)
  m(c [%es body body], env e0, k [[%whb c body e0] kr])
::  enter a call ON THE MACHINE (closures run as machine frames; coyield suspends)
++  enter-call
  |=  [fnv=value args=(list value) m=mstate]
  ^-  mstate
  ?:  ?=(%c -.fnv)
    =/  cl  (~(got by funs.s.m) id.fnv)
    =/  pre=@ud  next.s.m
    =/  pf=@ud  ~(wyt by funs.s.m)
    =/  pt=@ud  ~(wyt by tabs.s.m)
    =^  env2  s.m  (bind-params cl args s.m)
    =/  nva=(list value)  ?:(vararg.cl (slag (lent params.cl) args) ~)
    =/  bd  ;;((list stmt) body.cl)
    m(c [%es bd bd], env env2, va nva, k [[%rt env.m va.m pre pf pt] k.m])
  ?:  ?=(%fn -.fnv)
    ?:  =(p.fnv %coyield)  m(c [%yield args])
    ?:  =(p.fnv %coresume)
      =^  rv  s.m  (do-resume args s.m)
      m(c [%rv rv])
    =^  rv  s.m  (call-builtin p.fnv args s.m)
    m(c [%rv rv])
  ?:  ?=(%t -.fnv)
    =/  h  (mm-lookup fnv '__call' s.m)
    ?:  ?=(%nil -.h)  ~|([%lua-call-non-function -.fnv] !!)
    (enter-call h [fnv args] m)
  ~|([%lua-call-non-function -.fnv] !!)
::  coroutine.resume: a nested trampoline over the coro's saved machine
++  do-resume
  |=  [args=(list value) s=store]
  ^-  [(list value) store]
  =/  cov  (arg 0 args)
  ?.  ?=(%co -.cov)  ~|(%lua-resume-non-coroutine !!)
  =/  coid  id.cov
  =/  rargs  ?~(args ~ t.args)
  =/  co  (~(got by coros.s) coid)
  ?:  ?=(%dead status.co)  [~[[%b %.n] [%s 'cannot resume dead coroutine']] s]
  ?:  ?=(%run status.co)   [~[[%b %.n] [%s 'cannot resume non-suspended coroutine']] s]
  =.  coros.s  (~(put by coros.s) coid co(status %run, started %.y))
  =.  curco.s  [coid curco.s]
  =/  m0=mstate
    ?:  started.co
      [[%rv rargs] ksave.co esave.co vsave.co s]
    (enter-call fun.co rargs [[%rv ~] ~ ~ ~ s])
  =/  mf  (run-mach m0)
  =.  s  s.mf
  =.  curco.s  ?~(curco.s ~ t.curco.s)
  =/  co2  (~(got by coros.s) coid)
  ?-  -.c.mf
      %halt
    =.  coros.s  (~(put by coros.s) coid co2(status %dead))
    [[[%b %.y] vs.c.mf] s]
  ::
      %yield
    =/  co3  co2(status %susp, ksave k.mf, esave env.mf, vsave va.mf)
    =.  coros.s  (~(put by coros.s) coid co3)
    [[[%b %.y] vs.c.mf] s]
  ::
      *  ~|(%lua-coro-stuck !!)
  ==
::                                                ::  ::  builtins
++  call-builtin
  |=  [nm=@tas args=(list value) s=store]
  ^-  [(list value) store]
  ?+    nm  ~|([%lua-unknown-builtin nm] !!)
      %cocreate
    =^  id  s  (fresh s)
    =.  coros.s  (~(put by coros.s) id [(arg 0 args) %susp %.n ~ ~ ~])
    [~[[%co id]] s]
  ::
      %coresume  (do-resume args s)
  ::
      %coyield  ~|(%lua-yield-outside-coroutine !!)
  ::
      %costatus
    =/  cov  (arg 0 args)
    ?.  ?=(%co -.cov)  ~|(%lua-status-non-coroutine !!)
    =/  co  (~(got by coros.s) id.cov)
    =/  txt=@t
      ?:  =(`id.cov ?~(curco.s ~ `i.curco.s))  'running'
      ?:  (lien curco.s |=(c=@ud =(c id.cov)))  'normal'
      ?-(status.co %dead 'dead', %susp 'suspended', %run 'running')
    [~[[%s txt]] s]
  ::
      %corunning
    ?~  curco.s  [~[[%nil ~] [%b %.y]] s]
    [~[[%co i.curco.s] [%b %.n]] s]
  ::
      %coyieldable  [~[[%b ?=(^ curco.s)]] s]
  ::
      %print
    =^  parts  s  (tostr-args args s)
    =/  tab=tape  ~[`@tD`9]
    =/  line  (zing (join tab parts))
    [~ s(out (snoc out.s line))]
  ::
      %type     [~[(bi-type (arg 0 args))] s]
      %tostring
    =^  t  s  (do-tostr (arg 0 args) s)
    [~[[%s (crip t)]] s]
  ::
      %tonumber  [~[(bi-tonumber (arg 0 args))] s]
      %pairs    [~[[%fn %next] (arg 0 args) [%nil ~]] s]
      %ipairs   [~[[%fn %inext] (arg 0 args) [%i --0]] s]
      %next      [(bi-next args s) s]
      %rawequal  [~[[%b (val-eq (arg 0 args) (arg 1 args))]] s]
      %rawget    [~[(tab-get id:;;([%t id=@ud] (arg 0 args)) (arg 1 args) s)] s]
      %rawlen    [~[(bi-rawlen (arg 0 args) s)] s]
  ::
      %setmetatable
    =/  tv  (arg 0 args)
    ?.  ?=(%t -.tv)  ~|(%lua-setmetatable-non-table !!)
    =/  mv  (arg 1 args)
    ?:  ?=(%nil -.mv)
      [~[tv] s(metas (~(del by metas.s) id.tv))]
    ?.  ?=(%t -.mv)  ~|(%lua-setmetatable-bad-meta !!)
    [~[tv] s(metas (~(put by metas.s) id.tv id.mv))]
  ::
      %getmetatable
    =/  tv  (arg 0 args)
    ?.  ?=(%t -.tv)  [~[[%nil ~]] s]
    =/  mid  (~(get by metas.s) id.tv)
    ?~  mid  [~[[%nil ~]] s]
    [~[[%t u.mid]] s]
  ::
      %rawset
    =/  tv  (arg 0 args)
    ?.  ?=(%t -.tv)  ~|(%lua-rawset-non-table !!)
    [~[tv] (tab-set id.tv (arg 1 args) (arg 2 args) s)]
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
    %co   'thread'
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
++  read-flags
  |=  t=tape
  ^-  [m=? p=? sp=? h=? z=? t=tape]
  =/  m=?  %.n
  =/  p=?  %.n
  =/  sp=?  %.n
  =/  h=?  %.n
  =/  z=?  %.n
  |-  ^-  [m=? p=? sp=? h=? z=? t=tape]
  ?~  t  [m p sp h z t]
  ?:  =(i.t '-')  $(m %.y, t t.t)
  ?:  =(i.t '+')  $(p %.y, t t.t)
  ?:  =(i.t ' ')  $(sp %.y, t t.t)
  ?:  =(i.t '#')  $(h %.y, t t.t)
  ?:  =(i.t '0')  $(z %.y, t t.t)
  [m p sp h z t]
++  read-spec
  |=  t=tape
  ^-  [spec=fspec rest=tape]
  =/  fl  (read-flags t)
  =.  t  t.fl
  =/  wd  (take-while t dig)
  =/  width=@ud  ?~(p.wd 0 (base-val 10 p.wd))
  =.  t  q.wd
  =/  prec=(unit @ud)  ~
  =^  prec  t
    ?:  &(?=(^ t) =(i.t '.'))
      =/  pd  (take-while t.t dig)
      [`(base-val 10 p.pd) q.pd]
    [~ t]
  ?~  t  ~|(%lua-bad-format !!)
  [[m.fl p.fl sp.fl h.fl z.fl width prec i.t] t.t]
++  digit-char
  |=  [d=@ upper=?]
  ^-  @
  ?:  (lth d 10)  (add '0' d)
  ?:(upper (add 'A' (sub d 10)) (add 'a' (sub d 10)))
++  to-base
  |=  [n=@ud base=@ud upper=?]
  ^-  tape
  ?:  =(n 0)  "0"
  =/  acc=tape  ~
  |-  ^-  tape
  ?:  =(n 0)  acc
  $(acc [(digit-char (mod n base) upper) acc], n (div n base))
++  as-u64
  |=  i=@sd
  ^-  @ud
  ?:  (syn:si i)  (abs:si i)
  (sub (bex 64) (abs:si i))
++  find-char
  |=  [t=tape c=@]
  ^-  @ud
  =/  i=@ud  0
  |-  ^-  @ud
  ?~  t  i
  ?:  =(i.t c)  i
  $(i +(i), t t.t)
++  find-e
  |=  t=tape
  ^-  @ud
  =/  i=@ud  0
  |-  ^-  @ud
  ?~  t  i
  ?:  |(=(i.t 'e') =(i.t 'E'))  i
  $(i +(i), t t.t)
++  pad-str
  |=  [t=tape width=@ud left=?]
  ^-  tape
  ?:  (gte (lent t) width)  t
  =/  pad  (reap (sub width (lent t)) ' ')
  ?:(left (weld t pad) (weld pad t))
++  fmt-fixed
  |=  [x=@rd prec=@ud]
  ^-  tape
  =/  scaled  (add:rd (mul:rd x (powten prec)) .~0.5)
  =/  u  (toi:rd scaled)
  =/  n=@ud  ?~(u 0 (abs:si u.u))
  =/  ds  (to-base n 10 %.n)
  ?:  =(prec 0)  ds
  =?  ds  (lte (lent ds) prec)
    (weld (reap (sub +(prec) (lent ds)) '0') ds)
  =/  l  (lent ds)
  (weld (scag (sub l prec) ds) (weld "." (slag (sub l prec) ds)))
++  normsci
  |=  [m=@rd e=@s]
  ^-  [@rd @s]
  ?:  (equ:rd m .~0)  [.~0 --0]
  ?:  (rgte m .~10)  $(m (div:rd m .~10), e (sum:si e --1))
  ?:  (lth:rd m .~1)  $(m (mul:rd m .~10), e (dif:si e --1))
  [m e]
++  fmt-exp
  |=  [e=@s upper=?]
  ^-  tape
  =/  neg=?  =(-1 (cmp:si e --0))
  =/  ds  (to-base (abs:si e) 10 %.n)
  =?  ds  (lth (lent ds) 2)  (weld (reap (sub 2 (lent ds)) '0') ds)
  (weld ~[?:(upper 'E' 'e') ?:(neg '-' '+')] ds)
++  fmt-sci
  |=  [x=@rd prec=@ud upper=?]
  ^-  tape
  ?:  (equ:rd x .~0)
    (weld (fmt-fixed .~0 prec) (fmt-exp --0 upper))
  =/  me  (normsci x --0)
  =/  m  -.me
  =/  e  +.me
  =/  mt  (fmt-fixed m prec)
  =^  mt  e
    ?:  (gth (find-char mt '.') 1)
      [(fmt-fixed (div:rd m .~10) prec) (sum:si e --1)]
    [mt e]
  (weld mt (fmt-exp e upper))
++  strip-frac
  |=  t=tape
  ^-  tape
  ?.  (lien t |=(c=@ =(c '.')))  t
  =/  r  (flop t)
  =.  r  |-(^-(tape ?~(r r ?:(=(i.r '0') $(r t.r) r))))
  =.  r  ?~(r r ?:(=(i.r '.') t.r r))
  (flop r)
++  strip-zeros
  |=  t=tape
  ^-  tape
  =/  ei  (find-e t)
  (weld (strip-frac (scag ei t)) (slag ei t))
++  fmt-gen
  |=  [x=@rd prec=@ud upper=?]
  ^-  tape
  =/  p  ?:(=(prec 0) 1 prec)
  ?:  (equ:rd x .~0)  "0"
  =/  me  (normsci x --0)
  =/  ex  +.me
  =/  use-f=?  &((sge ex -4) =(-1 (cmp:si ex (sun:si p))))
  =/  raw=tape
    ?:  use-f
      (fmt-fixed x (abs:si (dif:si (dif:si (sun:si p) --1) ex)))
    (fmt-sci x (dec p) upper)
  (strip-zeros raw)
++  fmt-int-spec
  |=  [sp=fspec v=value]
  ^-  tape
  =/  i  (as-int v)
  =/  cv  conv.sp
  =/  uns=?  ?!(|(=(cv 'd') =(cv 'i')))
  =/  base=@ud  ?:(|(=(cv 'x') =(cv 'X')) 16 ?:(=(cv 'o') 8 10))
  =/  upr=?  =(cv 'X')
  =/  mag=@ud  ?:(uns (as-u64 i) (abs:si i))
  =/  ds=tape  (to-base mag base upr)
  =?  ds  ?=(^ prec.sp)
    ?:  &(=(u.prec.sp 0) =(mag 0))  ~
    ?:  (gte (lent ds) u.prec.sp)  ds
    (weld (reap (sub u.prec.sp (lent ds)) '0') ds)
  =/  sign=tape
    ?:  uns  ~
    ?:  !(syn:si i)  "-"
    ?:  fp.sp  "+"
    ?:  fsp.sp  " "
    ~
  =/  pfx=tape
    ?.  fh.sp  ~
    ?:  =(mag 0)  ~
    ?:  =(cv 'o')  "0"
    ?:  =(cv 'x')  "0x"
    ?:  =(cv 'X')  "0X"
    ~
  =/  body  (weld sign (weld pfx ds))
  =/  w  width.sp
  ?:  (gte (lent body) w)  body
  =/  np  (sub w (lent body))
  ?:  fm.sp  (weld body (reap np ' '))
  ?:  &(fz.sp ?=(~ prec.sp))
    (weld sign (weld pfx (weld (reap np '0') ds)))
  (weld (reap np ' ') body)
++  fmt-flt-spec
  |=  [sp=fspec v=value]
  ^-  tape
  =/  x0  (toflt (as-num v))
  =/  neg=?  (lth:rd x0 .~0)
  =/  x  ?:(neg (sub:rd .~0 x0) x0)
  =/  cv  conv.sp
  =/  prec  ?~(prec.sp 6 u.prec.sp)
  =/  digits=tape
    ?:  |(=(cv 'e') =(cv 'E'))  (fmt-sci x prec =(cv 'E'))
    ?:  |(=(cv 'g') =(cv 'G'))  (fmt-gen x prec =(cv 'G'))
    (fmt-fixed x prec)
  =/  sign=tape
    ?:  neg  "-"
    ?:  fp.sp  "+"
    ?:  fsp.sp  " "
    ~
  =/  body  (weld sign digits)
  =/  w  width.sp
  ?:  (gte (lent body) w)  body
  =/  np  (sub w (lent body))
  ?:  fm.sp  (weld body (reap np ' '))
  ?:  fz.sp  (weld sign (weld (reap np '0') digits))
  (weld (reap np ' ') body)
++  quote-str
  |=  c=@t
  ^-  tape
  =/  t  (trip c)
  =/  bs=@  92
  =/  acc=tape  ~
  =.  acc
    |-  ^-  tape
    ?~  t  acc
    =/  e=tape
      ?:  =(i.t '"')   ~[bs '"']
      ?:  =(i.t bs)    ~[bs bs]
      ?:  =(i.t 10)    ~[bs 'n']
      ?:  =(i.t 13)    ~[bs 'r']
      ?:  =(i.t 0)     ~[bs '0']
      ~[i.t]
    $(acc (weld acc e), t t.t)
  (weld ~['"'] (weld acc ~['"']))
++  bi-sformat
  |=  [args=(list value) s=store]
  ^-  value
  =/  fmt  (trip (as-str (arg 0 args)))
  =/  rest  ?~(args ~ t.args)
  =/  acc=tape  ~
  |-  ^-  value
  ?~  fmt  [%s (crip (flop acc))]
  ?.  =(i.fmt '%')  $(acc [i.fmt acc], fmt t.fmt)
  ?~  t.fmt  ~|(%lua-bad-format !!)
  ?:  =(i.t.fmt '%')  $(acc ['%' acc], fmt t.t.fmt)
  =/  rs  (read-spec t.fmt)
  =/  sp  spec.rs
  =/  cv  conv.sp
  =/  a  ?~(rest [%nil ~] i.rest)
  =/  rest2  ?~(rest ~ t.rest)
  =/  piece=tape
    ?:  ?|(=(cv 'd') =(cv 'i') =(cv 'u') =(cv 'o') =(cv 'x') =(cv 'X'))
      (fmt-int-spec sp a)
    ?:  ?|(=(cv 'f') =(cv 'F') =(cv 'e') =(cv 'E') =(cv 'g') =(cv 'G'))
      (fmt-flt-spec sp a)
    ?:  =(cv 's')
      =/  ts  (tostr a s)
      =.  ts  ?~(prec.sp ts (scag u.prec.sp ts))
      (pad-str ts width.sp fm.sp)
    ?:  =(cv 'q')  (quote-str (as-str a))
    ?:  =(cv 'c')
      =/  ch=@  (abs:si (as-int a))
      (pad-str ~[ch] width.sp fm.sp)
    ~|([%lua-bad-format-spec cv] !!)
  $(acc (weld (flop piece) acc), fmt rest.rs, rest rest2)
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
        ['rawset' [%fn %rawset]]
        ['setmetatable' [%fn %setmetatable]]
        ['getmetatable' [%fn %getmetatable]]
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
  =^  cid  s  (new-table s)
  =.  s  (tab-set cid [%s 'create'] [%fn %cocreate] s)
  =.  s  (tab-set cid [%s 'resume'] [%fn %coresume] s)
  =.  s  (tab-set cid [%s 'yield'] [%fn %coyield] s)
  =.  s  (tab-set cid [%s 'status'] [%fn %costatus] s)
  =.  s  (tab-set cid [%s 'running'] [%fn %corunning] s)
  =.  s  (tab-set cid [%s 'isyieldable'] [%fn %coyieldable] s)
  =.  glob.s  (~(put by glob.s) 'coroutine' [%t cid])
  s
++  run
  |=  src=@t
  ^-  (list tape)
  =/  ast  (parse (lex (trip src)))
  =/  s  (setup init-store)
  =/  res  (do-stmts ;;((list stmt) ast) ~[~] ~ s)
  out:+.res
::                                                ::  ::  thread driver
::    Run a Lua program as a resumable coroutine so it can drive Urbit IO.
::    Effect builtins (the `sys` table) call coroutine.yield(tag, args...);
::    a Hoon strand performs the effect and resumes with the result.
++  prelude
  ^-  @t
  %+  rap  3
  :~  'sys={} '
      'function sys.wait(ms) return coroutine.yield("wait",ms) end '
      'function sys.flog(s) return coroutine.yield("flog",s) end '
      'function sys.now() return coroutine.yield("now") end '
  ==
++  thread-init
  |=  src=@t
  ^-  [coid=@ud s=store]
  =/  ast  (parse (lex (trip (cat 3 prelude src))))
  =/  s  (setup init-store)
  =^  fid  s  (fresh s)
  =.  funs.s  (~(put by funs.s) fid [~ %.n ;;((list stmt) ast) ~])
  =^  cid  s  (fresh s)
  =.  coros.s  (~(put by coros.s) cid [[%c fid] %susp %.n ~ ~ ~])
  [cid s]
++  thread-step
  |=  [coid=@ud in=(list value) s=store]
  ^-  [tres store]
  =^  rv  s  (do-resume [[%co coid] in] s)
  =/  co  (~(got by coros.s) coid)
  =/  vals  (slag 1 rv)
  ?:  ?=(%dead status.co)  [[%done vals out.s] s]
  =/  tag  ?~(vals '' (vcord i.vals))
  [[%yield tag ?~(vals ~ t.vals) out.s] s]
++  vcord
  |=  v=value
  ^-  @t
  ?:  ?=(%s -.v)  p.v
  ?:  ?=(%i -.v)  (crip (fmt-int p.v))
  (crip (tostr v *store))
++  vnum
  |=  v=value
  ^-  @
  ?:(?=(%i -.v) (abs:si p.v) 0)
--

::  marker
