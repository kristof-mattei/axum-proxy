Rules:

- Be strict
- Show places where downstream effects occur, e.g. when `iter()` causes `clone()`, post the lines of code where the `clone()` occurs as well
- Don't assume
- Think about the language, e.g. if it's Rust we care about memory.
    - Don't suggest `fn foo(s: &str) -> String { todo!() }` is better than `fn foo(s: impl Into<Cow<'_, str>>) -> Cow<'_, str> { todo!() }` because
      'in most places we pass something by ref'. Most is not all. This is NOT a good recommendation.
      If there is a single place where we pass it by value our code is better, as it avoids allocations, even at the cost of reading complexity.
    - `fn foo<'i, I: Into<Cow<'i, str>>>(f: I) -> Cow<'i, str> { todo!() }` is not complex, it is the correct way to write it in Rust
