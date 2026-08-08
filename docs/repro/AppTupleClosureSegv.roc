app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}

import pf.Stdout

render : { a : F64 }, [Ef, Rpe] -> Str
render = |row, lens| {
    cols =
        match lens {
            Ef => [("a", |r| F64.to_str(r.a)), ("b", |r| F64.to_str(r.a))]
            Rpe => [("b", |r| F64.to_str(r.a))]
        }
    headers = List.map(cols, |c| c.0)
    cells = List.map(cols, |c| (c.1)(row))
    Str.join_with(List.concat(headers, cells), ",")
}

main! = |_args| Stdout.line!(render({ a: 1.0 }, Ef))
