# ── sport vocabulary (pure) ─────────────────────────────────────────
#
# One home for every "what kind of sport is this string" question. The answers
# used to live scattered through Metrics.roc beside resampling math; four
# separate policies (family filters, load-model class, pace routing for
# detection AND decoupling, the pace-TSS exponent) each carried their own list.
# Here the vocabulary is DATA — a table of rows — and the functions are thin
# lookups, so adding a sport or a synonym is editing one row, not four ifs.
Sports :: [].{

    # Human words and the Strava sport_type spellings they mean. NO e-bike arms
    # in the ride family on purpose: analyze computes best_*_w for anything with
    # a power stream, so one motor-assisted ride would set the power-curve max
    # at every duration and drag the CP fit up permanently.
    families : List({ words : List(Str), sports : List(Str) })
    families = [
        { words: ["bike", "cycling", "ride", "rides"], sports: ["Ride", "VirtualRide", "GravelRide", "MountainBikeRide"] },
        { words: ["run", "running", "runs"], sports: ["Run", "VirtualRun", "TrailRun"] },
        { words: ["row", "rowing"], sports: ["Rowing", "VirtualRow"] },
        { words: ["swim", "swimming"], sports: ["Swim", "OpenWaterSwim"] },
        { words: ["walk", "walking", "hike", "hiking"], sports: ["Walk", "Hike"] },
        { words: ["strength", "weights", "lifting"], sports: ["WeightTraining", "Workout"] },
    ]

    # family("bike") -> the ride spellings; unknown words pass through as a
    # singleton so a literal sport_type keeps filtering exactly and a typo
    # produces the no-matches hint downstream rather than a wrong guess.
    family : Str -> List(Str)
    family = |word| {
        low = Str.with_ascii_lowercased(word)
        match List.first(List.keep_if(families, |f| List.contains(f.words, low))) {
            Ok(f) => f.sports
            Err(_) => [word]
        }
    }

    # Load-model class: strength-like sports rank the athlete's RPE above HR
    # (a strap lies about lifting); endurance ranks measured signals first.
    class : Str -> [Endurance, StrengthLike]
    class = |sport_type| {
        strengthish = ["WeightTraining", "Workout", "Crossfit", "HighIntensityIntervalTraining", "Yoga", "Pilates"]
        if List.contains(strengthish, sport_type) StrengthLike else Endurance
    }

    # Sports where speed IS the effort signal — runs and swims per ADR 0008.
    # LOAD-BEARING FOR TWO POLICIES: interval detection's pace routing AND
    # aerobic decoupling's pace arm (#134). A meter-less RIDE must not fall
    # through to either: cycling speed varies with terrain, so run-tuned pace
    # parameters would invent work reps, and speed-over-HR would masquerade as
    # efficiency. Widening this widens both features at once — on purpose,
    # but consciously.
    pace_routed : Str -> Bool
    pace_routed = |sport| {
        low = Str.with_ascii_lowercased(sport)
        Str.contains(low, "run") or Str.contains(low, "swim")
    }

    # rTSS/sTSS intensity exponent: running 2, swimming 3 (drag rises faster
    # with speed in water).
    pace_tss_exponent : Str -> F64
    pace_tss_exponent = |sport|
        if Str.contains(Str.with_ascii_lowercased(sport), "swim") 3.0 else 2.0
}

# families widen, unknown words pass through, case folds
expect {
    Sports.family("bike") == ["Ride", "VirtualRide", "GravelRide", "MountainBikeRide"]
    and Sports.family("BIKE") == ["Ride", "VirtualRide", "GravelRide", "MountainBikeRide"]
    and Sports.family("run") == ["Run", "VirtualRun", "TrailRun"]
    and Sports.family("Rowing") == ["Rowing", "VirtualRow"]
    and Sports.family("Yoga") == ["Yoga"]
}

# the table itself is well-formed: no word claims two families, no family empty —
# iterating the DATA is what a table buys over an if-chain
expect {
    all_words = List.join(List.map(Sports.families, |f| f.words))
    distinct = List.fold(all_words, [], |acc, w| if List.contains(acc, w) acc else List.append(acc, w))
    List.len(all_words) == List.len(distinct)
    and List.all(Sports.families, |f| !(List.is_empty(f.sports)) and !(List.is_empty(f.words)))
}

# class routing matches the load-model invariant
expect {
    Sports.class("WeightTraining") == StrengthLike
    and Sports.class("Workout") == StrengthLike
    and Sports.class("Ride") == Endurance
    and Sports.class("Rowing") == Endurance
}

# pace routing: runs and swims only — never rides, walks, rows
expect {
    Sports.pace_routed("Run") and Sports.pace_routed("VirtualRun")
    and Sports.pace_routed("TrailRun") and Sports.pace_routed("OpenWaterSwim")
    and !(Sports.pace_routed("Ride")) and !(Sports.pace_routed("Walk"))
    and !(Sports.pace_routed("Hike")) and !(Sports.pace_routed("Rowing"))
}

# the exponent: water is cubic, land is quadratic
expect {
    (Sports.pace_tss_exponent("Swim") - 3.0).abs() < 0.001
    and (Sports.pace_tss_exponent("OpenWaterSwim") - 3.0).abs() < 0.001
    and (Sports.pace_tss_exponent("Run") - 2.0).abs() < 0.001
    and (Sports.pace_tss_exponent("Ride") - 2.0).abs() < 0.001
}
