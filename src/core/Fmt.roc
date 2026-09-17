# stride-core: definitions both binaries need.
#
# The engine (basic-cli) and the window (roc-ray) bind different platforms, so
# for most of this project's life they could share nothing but SQL views (ADR
# 0017). Since both build on one compiler they can import one package, and
# this is where a definition goes when BOTH surfaces state it. A definition
# only one binary uses stays in that binary.
Fmt :: [].{
    # seconds as m:ss, zero-padded on the seconds so a column of them aligns.
    # Both surfaces speak this: the CLI renders pace per kilometre and interval
    # durations, the window labels a pace family's threshold. One body, so a
    # rounding or padding change cannot reach one surface and miss the other.
    # Negative input clamps to zero - there is no such thing as a negative
    # duration, and a "-1:-30" would be a worse answer than "0:00".
    mmss : I64 -> Str
    mmss = |secs| {
        t = if secs < 0 (0) else secs
        m = t // 60
        s = t % 60
        "${I64.to_str(m)}:${if s < 10 "0" else ""}${I64.to_str(s)}"
    }

    expect mmss(181) == "3:01"
    expect mmss(720) == "12:00"
    expect mmss(0) == "0:00"
    expect mmss(59) == "0:59"
    expect mmss(-5) == "0:00"
    # a pace beyond an hour still reads in minutes rather than rolling over:
    # 75 minutes per kilometre is a walk, not an error, and "75:00" says so
    expect mmss(4500) == "75:00"

    # hundredths as a two-decimal string: 98 -> "0.98", 105 -> "1.05". The
    # engine reaches it through a float (fmt2 rounds first), the window
    # through an already-scaled integer - a value the SQL rounded - so the
    # shared body takes the hundredths and neither surface repeats the
    # zero-padding rule that makes 5 read as ".05" rather than ".5".
    # The sign lives here too: between -1 and 0 the whole part rounds to 0,
    # so "-0.42" needs the minus that I64.to_str(0) cannot carry.
    hundredths : I64 -> Str
    hundredths = |n| {
        whole = n // 100
        frac = I64.abs(n % 100)
        frac_str = if frac < 10 "0${I64.to_str(frac)}" else I64.to_str(frac)
        sign = if n < 0 and whole == 0 "-" else ""
        "${sign}${I64.to_str(whole)}.${frac_str}"
    }

    expect hundredths(98) == "0.98"
    expect hundredths(105) == "1.05"
    expect hundredths(100) == "1.00"
    expect hundredths(-42) == "-0.42"
    expect hundredths(-150) == "-1.50"
    expect hundredths(0) == "0.00"
}
