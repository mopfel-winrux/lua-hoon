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
  sys.kelvin      -- [%zuse 410]
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
- strings with escapes, and `..` concatenation; `#` length
- `nil` / booleans / `and` / `or` / `not` (with short-circuit)
- locals and globals, multiple assignment (`a, b = b, a`)
- functions, **closures with shared mutable upvalues**, recursion
- varargs (`...`) and multiple return values
- control flow: `if`/`elseif`/`else`, `while`, `repeat`/`until`,
  numeric `for`, generic `for ... in`
- tables: array + hash parts, constructors, `t[k]` / `t.k`, `#t`
- standard library: `print`, `type`, `tostring`, `tonumber`, `pairs`,
  `ipairs`, `next`, `select`, `assert`, `error`, `rawget`/`rawequal`/`rawlen`;
  `math.*` (`floor ceil abs sqrt max min pi`); `string.*`
  (`len sub upper lower rep format`); `table.*` (`insert remove concat`)

## Not (yet) supported

- metatables / metamethods
- coroutines
- bitwise operators (`& | ~ << >>`)
- `goto` / labels
- `string.format` width/precision specifiers (e.g. `%.2f`); `%d %s %f %x %%` work
- **closures created inside a loop share the loop variable** (Lua 5.3 behavior,
  not 5.4's fresh-per-iteration) — a deliberate tradeoff for not allocating a
  fresh cell every iteration

## Performance

Tree-walking interpreter over a functional store, interpreted through Nock — so
expect scripting speeds, not LuaJIT. Measured on a fakeship (vere 3.2):

| workload                         | cost                          |
|----------------------------------|-------------------------------|
| simple loop iteration            | ~38 µs (~26k/s), flat at scale |
| trivial function call            | ~15 µs                        |
| heavy recursive call (`fib`)     | ~140 µs                       |
| table set                        | ~20 µs                        |

Loops and call-heavy code run in bounded memory (a call that creates no closures
or tables reclaims its cells on return), so a 100k-iteration loop or hundreds of
thousands of calls scale linearly without exhausting the loom.

## Implementation note: recursive types

Lua's AST is naturally a recursive type (`expr` contains `expr`). The vere build
this was developed against crashes its compiler (`dig: over`) when pattern-matching
(`?-` / `?=`) over a directly self-recursive `$%`. To work around it, recursive
child positions in the `expr` / `stmt` / `tfield` molds are typed as `*` (raw
noun) so the declared types are non-recursive, and each evaluator arm `;;`-clamps
a node back to its typed mold before dispatching. If your toolchain doesn't have
that bug, the molds can be written with ordinary self-reference.
