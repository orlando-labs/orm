# orm

Source-only P0 ORM/modeling package for Sputnik.

The implemented ORM pool substrate and the proposed controller-transparent /
explicit bare-handler web integration are specified in
[`DESIGN-connection-pool-2026-07-15.md`](DESIGN-connection-pool-2026-07-15.md).

This first implementation provides the runtime layers from the design:

- inferred columns with optional exact schema expectations;
- local dirty tracking;
- structured validation errors;
- `Result`-returning `save`, `find`, `get`, and `delete`;
- tableless models;
- SQLite execution through `sqlite3`;
- a thin pool facade with one-time model binding and scoped checkout;
- model-level transactions with rollback on an `Err` block result;
- execution instrumentation and an opt-in live query logger;
- model/tableless macros for class-local declarations.

Macro-backed models use Sputnik's `use` injection macro surface. Sputnik's parser
currently requires parenthesized calls inside the DSL:

```sputnik
class User:
  use orm.model(table: :users):
    expect_schema:
      column(:id, type: :integer, primary_key: true, generated: true)
      column(:email, type: :text, nullable: false)
    validate:
      expect(:email, email.present?, message: "must be present")
      expect(:age, age.absent? or age >= 0,
        code: :gte,
        message: "must be greater than or equal to 0")

user = User(email: "ada@example.test", age: 36)
```

`expect_schema:` is optional. Without it, the model adopts the table schema
reported by the adapter when `bind!` succeeds. `column` is an expectation and
belongs only inside that block.

Tableless models declare attributes directly:

```sputnik
class SignupForm:
  use orm.tableless:
    schema:
      attribute(:email, type: :text)
      attribute(:password, type: :text)

    validate:
      expect(:email, email.present?, message: "must be present")
```

`attribute` is valid only inside the tableless `schema:` block. A loose
attribute declaration is rejected when the model descriptor is initialized,
so schema and validation declarations stay grouped.

These DSL blocks are executable macro blocks: `model`, `expect_schema`,
`tableless`, `schema`, and `validate` invoke their declared `&blk`, while their
nested macros emit ordinary quoted descriptor code. The package does not parse
Sputnik's raw postfix/block AST shapes.

The public macros have exact call shapes rather than `*args` / `**opts`
catch-alls. Factory `model` accepts an optional positional name plus `name:`,
`table:`, `expected_schema:`, and `validations:`. Factory `tableless` accepts an
optional positional name plus `name:`, `schema:`, `validations:`, and
`persisted:`. In a `use` declaration, Sputnik supplies the class AST as the first
argument, so `name:` is derived and rejected as an override. Unknown keywords
are expansion errors.

Without `table:`, the `use` form derives a deliberately small P0 default from
the class name: `AuditLog` becomes `audit_logs`. Irregular plurals still require
an explicit `table:`.

Macro parameters are typed as `Ast` because function-like Sputnik macros receive
unevaluated syntax. The generated runtime table value is still a `Str` or
`Symbol`; calling the macro does not pretend `table: :users` is already a
runtime string during expansion.

Macro-backed constructors, `new`, `create`, `find`, `get`, `all`, and query
hydration all return an instance of the declared model class. Constructors and
create methods accept either an attribute map or keyword attributes. Dynamic
factory models keep the same API and return `orm.Record` instances.

The factory shape is still available and is what the macros generate:

```sputnik
def user_validations():
  orm.validate:
    expect(:email, email.present?, message: "must be present")
    expect(:age, age.absent? or age >= 0,
      code: :gte,
      message: "must be greater than or equal to 0")

User = orm.model(name: :User,
  table: :users,
  expected_schema: orm.ExpectedSchema([
    orm.column(:id, type: :integer, primary_key: true, generated: true),
    orm.column(:email, type: :text, nullable: false),
    orm.column(:age, type: :integer, nullable: true, default: null)
  ]),
  validations: user_validations().validations)
```

The initial query relation supports maps and an explicit comparison block:

```sputnik
adults = User.where |query|:
  query.field(:age) >= 18

users = adults.all.or_raise
first = adults.first.or_raise

# An unfiltered model query does not need an empty `where`.
all_users = User.all.or_raise
```

Comparisons support `==`, `!=`, `>`, `>=`, `<`, `<=`, `one_of`,
`not_one_of`, `present?`, and `absent?`. Predicates compose with `and_where`
and `or_where`; repeated `where` calls compose with AND. SQLite compilation uses
quoted identifiers and bound parameters rather than interpolated values.

`save` returns `Ok(record)` or `Err(orm.ValidationError /
orm.PersistenceError)`. Use `.or_raise` when escalation is wanted.

## Connection pools

`orm.sqlite3` owns the public constructors while the adapter and pool
implementation live in separate modules. Models bind once during application
startup; controller and business code continues to use the ordinary model API:

```sputnik
from orm.sqlite3 import pool as sqlite_pool

database = sqlite_pool("data/app.db",
  min_size: 1,
  max_size: 8,
  checkout_timeout: 0.25,
  busy_timeout: 2.0,
  pragmas: {foreign_keys: true, journal_mode: :wal})

database.bind!(Person, AuditEvent).or_raise

database.with_connection:
  Person.find(id)
```

Nested model operations reuse the current logical-task lease. A spawned child
does not inherit that exclusive lease and checks out its own connection. Calls
made without an outer scope still work through operation-local checkout, which
is useful for scripts; a web request scope is what guarantees one connection
across several related ORM operations.

The future Orbit controller integration owns that request wrapper, so a
controller action remains pool-unaware:

```sputnik
class People < orbit.Controller:
  def show(id as Int):
    Person.find(id)
```

A bare `&handler` has no controller lifecycle and therefore needs explicit
infrastructure at the route/declaration boundary. Both proposed forms preserve
the handler signature:

```sputnik
db_request = orbit_orm.connection(database)

routes = orbit.routes:
  post "/people", to: &create, before: [db_request]

# Equivalent intrinsic policy for a reusable bare handler:
before db_request
def create(request):
  Person.create(name: request.query(:name))
```

`before` belongs to the web integration and is an annotation macro that wraps
the declaration at compile time; it is not an implicit Sputnik binding and is not
implemented by this ORM package.

Transactions are available through either the model or the pool wrapper. An
`Err` returned by the block rolls the transaction back and is returned intact:

```sputnik
result = Person.transaction(mode: :immediate):
  Person.create(name: "Ada").or_raise
  Err(orm.PersistenceError("abort"))
```

`with_connection` timeout/closed/lease failures use the DB-neutral errors from
`orm.pool`: `ConnectionPoolTimeoutError`, `ConnectionPoolClosedError`, and
`ConnectionPoolLeaseError`. Rebinding an already configured model to another
pool returns `Err(ModelBindingError)`.

Records use ordinary index access for dynamic attributes:

```sputnik
form[:email]
form[:email] = "ada@example.test"
```

SQLite execution can be wrapped independently of logging. An instrumenter
receives a `sqlite3.SqlExecution`, calls the real execution block, and notifies
its subscribers with one `orm.ExecutionEvent`:

```sputnik
instrumentation = orm.Instrumentation([tracer])
User.bind!(sqlite_adapter(db, instrumentation: instrumentation))
```

Subscribers implement `started(event)` and `finished(event)`. This is the same
surface used by the query logger, so an OpenTelemetry subscriber can create and
finish spans without changing the adapter:

```sputnik
logger = orm.QueryLogger(
  dynamic: true,
  leave: true,
  refresh: 0.08,
  color: :auto)

instrumentation = orm.Instrumentation([logger])
User.bind!(sqlite_adapter(db, instrumentation: instrumentation))
```

`dynamic: true` is the explicit opt-in for cursor-updating output. The logger
writes a record before execution, refreshes elapsed wall time on a no-GIL
spawned task, keeps parallel queries on separate terminal rows, and finalizes
each row with `v` or `x`. With `leave: false`, the completed batch is erased.

Attribute and dirty-state snapshots use shallow `Map#copy`. Mutating a nested
value in place is not tracked; assign a replacement through
`record[:name] = value` or `assign!`
to make that change observable. The ORM does not deep-copy user instances or
opaque resources merely to take a snapshot.

ORM failure objects are ordinary Sputnik classes under `Exception`, allowing
structured payloads such as `ValidationError#errors` and
`SchemaMismatchError#diff`. SQLite faults use sqlite3's bodyless
`NativeError` hierarchy because they originate in the native error registry.

## Layout

```text
sputnik.build.yaml          core source-only package manifest
src/orm.s                model, attributes, validation, queries, transactions
src/orm/pool.s           DB-neutral pool and binding errors
src/orm/sqlite3.s        public SQLite adapter/pool constructors
src/orm/sqlite3/adapter.s SQLite model executor
src/orm/sqlite3/pool.s   thin wrapper over sqlite3.Pool
test/selftest.s          existing ORM conformance test
test/pool_selftest.s     pool, scope, transaction, and concurrency contract
examples/tableless.s     tableless usage
examples/sqlite_basic.s  SQLite usage
```

## Running The Self-Test

From this repo:

```sh
../sputnik-lang/build/sputnik build test/selftest.build.yaml --target native --out-dir out --cache-dir cache
./out/orm.selftest

../sputnik-lang/build/sputnik build test/pool_selftest.build.yaml --target native --out-dir out-pool --cache-dir cache-pool
./out-pool/orm.pool_selftest
```
