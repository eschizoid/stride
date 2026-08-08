app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}

import pf.Stdout

render : { a : F64 } -> Str
render = |row| {
    cols = [("a", |r| F64.to_str(r.a)), ("b", |r| F64.to_str(r.a))]
    Str.join_with(List.map(cols, |c| (c.1)(row)), ",")
}

main! = |_args| Stdout.line!(render({ a: 1.0 }))
