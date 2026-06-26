# lua-hoon

A pragmatic-core **Lua 5.4 interpreter written in [Hoon](https://docs.urbit.org/language/hoon)**, runnable on an Urbit ship.

It is a hand-written **lexer → recursive-descent parser → tree-walking interpreter**. Lua values, tables, and closures live in a purely-functional store that is threaded through evaluation, so closures capture upvalues correctly and tables are mutable — all without leaving Nock.

```lua
print("hello, " .. "urbit")        --> hello, urbit
print(10 / 3)                      --> 3.333333333333333
local function fib(n)
  if n < 2 then return n end
  return fib(n-1) + fib(n-2)
end
print(fib(10))                     --> 55
```

## Contents

```
desk/
  lib/lua.hoon    -- the interpreter (lexer + parser + evaluator)
  mar/lua.hoon    -- a %lua source mark, for storing .lua files in Clay
  gen/lua.hoon    -- the `+lua` generator: run a Lua string and print stdout
  sys.kelvin      -- [%zuse 408]
examples/         -- sample Lua programs
```

## Usage

On a running ship (real or fake), create a desk from this `desk/` directory and
run the generator. For a fakeship:

```dojo
> |new-desk %lua
> |mount %lua
```

Copy `desk/lib/lua.hoon`, `desk/mar/lua.hoon`, `desk/gen/lua.hoon` (and, if you
want to commit `.lua` files via the mark, your base ship's `mar/mime.hoon` and
`mar/txt.hoon`) into the mounted `%lua` desk, then:

```dojo
> |commit %lua
> +lua 'print(1 + 2)'
3
```

The simplest path while developing is to drop the three files onto your `%base`
desk instead, so `+lua` runs live with no desk pinning:

```dojo
> +lua 'local s=0 for i=1,100 do s=s+i end print(s)'
5050
```

`run:lua` is the library entrypoint: `(run:lua src=@t)` parses and evaluates a
Lua source cord and returns its stdout as a `(list tape)`.

## Supported language

- numbers: integers (`@sd`) and floats (`@rd`), with Lua's int/float promotion
  (`+ - *` stay integer; `/` and `^` produce floats; `// %` follow operands)
- **bitwise operators** `& | ~ << >>` and unary `~` (64-bit two's-complement)
- strings with escapes, and `..` concatenation; `#` length
- `nil` / booleans / `and` / `or` / `not` (with short-circuit)
- locals and globals, multiple assignment (`a, b = b, a`)
- functions, **closures with mutable upvalues**, recursion
- varargs (`...`) and multiple return values
- control flow: `if`/`elseif`/`else`, `while`, `repeat`/`until`,
  numeric `for`, generic `for ... in`, `break`, **`goto` / `::label::`**
- **per-iteration loop-variable capture** (Lua 5.4 semantics): closures made in
  different iterations capture distinct values
- tables: array + hash parts, constructors, `t[k]` / `t.k`, `#t`
- **metatables / metamethods**: `__index`, `__newindex`, `__add` `__sub` `__mul`
  `__div` `__mod` `__pow` `__idiv` `__unm`, `__eq` `__lt` `__le`, `__concat`,
  `__len`, `__call`, `__tostring`; `setmetatable` / `getmetatable`
- **true coroutines** (real suspension from any depth): `coroutine.create` /
  `resume` / `yield` / `status` / `running` / `isyieldable` — see notes below
- standard library: `print`, `type`, `tostring`, `tonumber`, `pairs`,
  `ipairs`, `next`, `select`, `assert`, `error`,
  `rawget`/`rawset`/`rawequal`/`rawlen`;
  `math.*` (`floor ceil abs sqrt max min pi`); `string.*`
  (`len sub upper lower rep`, and full C-style `format`: flags, width,
  `.precision`, `d i u o x X e E f g G c s q %`); `table.*`
  (`insert remove concat`)

## Coroutines

These are **true** coroutines, not a generator fake. `yield` suspends from any
depth — inside a loop, a nested call, an `if` — and `resume` re-enters exactly
where it left off, with values passed both ways. So all of these work as in
real Lua: infinite generators, resume-value passing, side effects interleaved
between resumes, and nested (asymmetric) coroutines.

```lua
-- yield from inside a loop; driven across resumes
local function gen(n) for i = 1, n do coroutine.yield(i) end end
local co = coroutine.create(gen)
print(coroutine.resume(co, 3))  --> true  1
print(coroutine.resume(co))     --> true  2
print(coroutine.resume(co))     --> true  3
print(coroutine.resume(co))     --> true        (body returned)
print(coroutine.resume(co))     --> false  cannot resume dead coroutine

-- resume args flow back as yield's return value
local c = coroutine.create(function() local x = coroutine.yield(10); return x + 1 end)
print(coroutine.resume(c))      --> true  10
print(coroutine.resume(c, 99))  --> true  100
```

### How it works

The main thread runs on the recursive tree-walker (fast, common case). A
coroutine body instead runs on a small **CEK step machine**: its continuation
is reified as a flat `(list kframe)` stored in the coroutine, so `yield` simply
parks that stack and returns to the resumer, and `resume` spins the machine
again from the saved state. Both evaluators share every leaf arm (arithmetic,
indexing, metamethods, builtins), so semantics stay identical. Sub-expressions
that provably contain no call skip the machine and run atomically, so a hot
yield-free loop body inside a coroutine keeps tree-walker speed.

### Coroutine limits

- `coroutine.wrap` is not provided (use `create` + `resume`).
- You cannot `yield` across a **builtin or metamethod** boundary — e.g. a
  `yield` inside an `__index` function, a `pcall`, or a `table.sort` comparator
  errors (`yield outside coroutine`). This mirrors Lua's historical "attempt to
  yield across a C-call boundary."
- A runtime error inside a coroutine body propagates as a host crash rather
  than being caught and returned as `false, msg`.
- `numeric for` with **float** bounds and a `yield` in its body is unsupported
  (integer numeric-for, while, and generic-for all work).

## Not yet supported

- the coroutine cases above (wrap, yield-across-builtin, float-for yield)
- `goto` into the scope of a local is not statically rejected
- `__index` chains / `__eq` cover the common cases; metamethods are not invoked
  by `string.format("%s", t)` or `table.concat` (they use raw `tostring`)

## Performance

Tree-walking interpreter over a functional store, interpreted through Nock — so
expect scripting speeds, not LuaJIT. Timed with the runtime's own `~> %bout`
hint on a fakeship, wrapping `(run:lua src)`:

| benchmark                          |      work | wall time | per unit   |
|------------------------------------|----------:|----------:|------------|
| lex + parse + stdlib setup         |         — |   0.43 ms | fixed start |
| `s = s + i` loop                   | 1,000,000 |   35.5 s  | ~35 µs/iter |
| Ackermann `A(3,5)`                 |    42,438 |    3.42 s | ~81 µs/call |
| Ackermann `A(3,6)`                 |   172,233 |   14.1 s  | ~82 µs/call |
| Ackermann `A(3,7)`                 |   693,964 |   57.4 s  | ~83 µs/call |
| naive recursive `fib(25)`          |   242,785 |   34.2 s  | ~141 µs/call |

("work" = loop iterations, or the exact number of function calls made.)

The Ackermann rows are the interesting ones: per-call cost stays flat (~82 µs)
from 10k to 700k calls. That's the point — a call that creates no closures or
tables reclaims its cells on return, so deep/wide recursion runs in **bounded
memory** and scales linearly instead of growing the store until the loom is
exhausted. The same holds for loops (flat from 10⁵ to 10⁶ iterations).

See [`examples/`](examples) for runnable programs, including `ackermann.lua` and
an infinite coroutine prime generator (`primes.lua`).

## Implementation note: recursive types

Lua's AST is naturally a recursive type (`expr` contains `expr`). The vere build
this was developed against crashes its compiler (`dig: over`) when pattern-matching
(`?-` / `?=`) over a directly self-recursive `$%`. To work around it, recursive
child positions in the `expr` / `stmt` / `tfield` molds are typed as `*` (raw
noun) so the declared types are non-recursive, and each evaluator arm `;;`-clamps
a node back to its typed mold before dispatching. If your toolchain doesn't have
that bug, the molds can be written with ordinary self-reference.
