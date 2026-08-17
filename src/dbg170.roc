app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
    http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}
import pf.Stdout

main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |_| {
    profile : List(I64)
    profile = [111, 197, 185, 206, 206, 204, 204, 192, 197, 194, 198, 201, 248, 254, 255, 258, 261, 255, 259, 266, 263, 266, 264, 268, 262, 269, 267, 271, 264, 263, 267, 264, 269, 269, 270, 275, 269, 268, 272, 273, 273, 273, 272, 277, 281, 277, 274, 274, 265, 270, 274, 270, 268, 269, 268, 282, 273, 273, 279, 280, 111, 148, 158, 171, 171, 164, 157, 153, 148, 157, 154, 148, 263, 266, 270, 275, 268, 263, 267, 264, 267, 274, 274, 272, 266, 266, 264, 267, 272, 268, 261, 266, 269, 267, 266, 265, 269, 269, 263, 260, 257, 266, 264, 263, 262, 255, 266, 265, 271, 271, 267, 267, 262, 265, 268, 262, 259, 256, 256, 241, 116, 124, 122, 118, 139, 138, 125, 131, 134, 137, 133, 131, 249, 258, 257, 251, 249, 249, 254, 247, 244, 249, 253, 251, 248, 254, 251, 250, 250, 247, 254, 253, 255, 246, 249, 251, 249, 253, 256, 257, 266, 271, 267, 259, 251, 279, 261, 248, 248, 252, 245, 257, 246, 247, 252, 245, 245, 251, 242, 244, 95]
    Stdout.line!("profile n=${(List.len(profile)).to_str()}")?
    one = Iter.fold(0.I64..<15, [], |acc, k| List.append(acc, { t: k, v: 1.0 }))
    Stdout.line!("one n=${(List.len(one)).to_str()}")?
    fixture = Iter.fold(0..<(List.len(profile) * 15), [], |acc, i| {
        w = List.get(profile, i // 15) ?? 0
        List.append(acc, { t: (i).to_i64_wrap(), v: (w).to_f64() })
    })
    Stdout.line!("fixture n=${(List.len(fixture)).to_str()}")?
    Ok({})
}
