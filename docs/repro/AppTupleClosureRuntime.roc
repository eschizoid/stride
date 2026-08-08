app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}

import pf.Stdout
import pf.OsStr

render : { a : F64 } -> Str
render = |row| {
    cols = [("a", |r| F64.to_str(r.a)), ("b", |r| F64.to_str(r.a))]
    Str.join_with(List.map(cols, |c| (c.1)(row)), ",")
}

# value comes from argv, so the compiler cannot fold this at compile time
main! = |args| {
    n = F64.from_str(OsStr.display(List.get(args, 1).ok_or(OsStr.from_str("1.0")))).ok_or(1.0)
    Stdout.line!(render({ a: n }))
}
