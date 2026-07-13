# amber-orm

Source-only P0 ORM/modeling package for Amber.

This first implementation provides the runtime layers from the design:

- inferred columns with optional exact schema expectations;
- local dirty tracking;
- structured validation errors;
- `Result`-returning `save`, `find`, `get`, and `delete`;
- tableless models;
- SQLite execution through `sqlite3-amber`;
- execution instrumentation and an opt-in live query logger;
- model/tableless macros for class-local declarations.

Macro-backed models use Amber's `use` injection macro surface. Amber's parser
currently requires parenthesized calls inside the DSL:

```amber
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

```amber
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
Amber's raw postfix/block AST shapes.

The public macros have exact call shapes rather than `*args` / `**opts`
catch-alls. Factory `model` accepts an optional positional name plus `name:`,
`table:`, `expected_schema:`, and `validations:`. Factory `tableless` accepts an
optional positional name plus `name:`, `schema:`, `validations:`, and
`persisted:`. In a `use` declaration, Amber supplies the class AST as the first
argument, so `name:` is derived and rejected as an override. Unknown keywords
are expansion errors.

Without `table:`, the `use` form derives a deliberately small P0 default from
the class name: `AuditLog` becomes `audit_logs`. Irregular plurals still require
an explicit `table:`.

Macro parameters are typed as `Ast` because function-like Amber macros receive
unevaluated syntax. The generated runtime table value is still a `Str` or
`Symbol`; calling the macro does not pretend `table: :users` is already a
runtime string during expansion.

Macro-backed constructors, `new`, `create`, `find`, `get`, and query hydration
all return an instance of the declared model class. Constructors and create
methods accept either an attribute map or keyword attributes. Dynamic factory
models keep the same API and return `orm.Record` instances.

The factory shape is still available and is what the macros generate:

```amber
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

```amber
adults = User.where |query|:
  query.field(:age) >= 18

users = adults.all.or_raise
first = adults.first.or_raise
```

Comparisons support `==`, `!=`, `>`, `>=`, `<`, `<=`, `one_of`,
`not_one_of`, `present?`, and `absent?`. Predicates compose with `and_where`
and `or_where`; repeated `where` calls compose with AND. SQLite compilation uses
quoted identifiers and bound parameters rather than interpolated values.

`save` returns `Ok(record)` or `Err(orm.ValidationError /
orm.PersistenceError)`. Use `.or_raise` when escalation is wanted.

Records use ordinary index access for dynamic attributes:

```amber
form[:email]
form[:email] = "ada@example.test"
```

SQLite execution can be wrapped independently of logging. An instrumenter
receives a `sqlite3.SqlExecution`, calls the real execution block, and notifies
its subscribers with one `orm.ExecutionEvent`:

```amber
instrumentation = orm.Instrumentation([tracer])
User.bind!(sqlite_adapter(db, instrumentation: instrumentation))
```

Subscribers implement `started(event)` and `finished(event)`. This is the same
surface used by the query logger, so an OpenTelemetry subscriber can create and
finish spans without changing the adapter:

```amber
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

ORM failure objects are ordinary Amber classes under `Exception`, allowing
structured payloads such as `ValidationError#errors` and
`SchemaMismatchError#diff`. SQLite faults use sqlite3-amber's bodyless
`NativeError` hierarchy because they originate in the native error registry.

## Layout

```text
amber.build.yaml          core source-only package manifest
src/orm.am                model, attributes, dirty tracking, validation, tableless
src/orm/sqlite3.am        SQLite adapter over sqlite3-amber
test/selftest.am          tableless and SQLite-backed conformance test
examples/tableless.am     tableless usage
examples/sqlite_basic.am  SQLite usage
```

## Running The Self-Test

From this repo:

```sh
../amber-lang/build/amberc build test/selftest.build.yaml --target native --out-dir out --cache-dir cache
./out/orm.selftest
```
