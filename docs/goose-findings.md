# Goose findings

Gaps, bugs, and surprises in the pinned Goose compiler and stdlib, found while building
this package. Each entry has a minimal program that shows it, the Goose commit it was
found on, the workaround used here, and whether it has been reported upstream.

The entries come in two parts: [bugs](#bugs), where Goose does something wrong or other
than its spec says, then [feature requests](#feature-requests), for what it lacks. Each
part runs from the least work a fix is expected to take to the most, so the cheap fixes
come first. The order is an estimate from reading the compiler. Place a new entry where
its expected work puts it, and delete an entry once the pin has its fix: git keeps it.

## Bugs

None yet.

## Feature requests

### A block's result can't be held across a catcher without naming its type

Found on `3ee3871` (`v2026.2`), task 004. Status: open; not reported

A function that runs a block inside a catcher, so that a `return ... from` the catcher
can leave it, must keep the block's value in a variable declared outside the catcher.
Goose gives no way to declare that variable at the block's result type: a `let`
without an initializer needs a type, and there is no `typeof`. The caller must name
the type, and `default<T>()` limits it to a fixed-size one.

    struct Error { code: i64 }
    fn attempt<F>() -> Error[] { F(); return []; }

    fn guarded<F>() {
        let r;                                 // error: a declaration without an
        let failed = attempt() { r = F(); };   // initializer needs a type
        return r, failed;
    }

    fn guarded_as<T, F>() -> T, Error[] {      // compiles: the caller names T
        var r = default<T>();                  // and T must be fixed-size
        let failed = attempt() { r = F(); };
        return r, failed;
    }

Expected: a way to name a function value's result type, such as `result<F>` or a
`let r: typeof(F())`, or a `let` without an initializer whose type the first
assignment gives, so that `let v, err = guarded() { ... value };` works for any type,
non-fixed ones built in the caller's destination.

Workaround: `pg::transaction<T>` names a fixed-size `T` at the call, and a block that
builds a non-fixed value writes it into the caller's variables (task 004).
