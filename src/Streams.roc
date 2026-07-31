module [stream_pairs, decode_streams]

import json.Json
import json.Option exposing [Option]

# ── decoding of stored Strava stream JSON (pure) ────────────────────

StreamSeq : { data : List (Option F64) }
StreamsResp : { time : Option StreamSeq, heartrate : Option StreamSeq, watts : Option StreamSeq }

empty_streams : StreamsResp
empty_streams = { time: Option.none({}), heartrate: Option.none({}), watts: Option.none({}) }

# decode stored stream JSON, distinguishing a genuine "no streams" (Null, or the
# {} 404-marker which decodes to all-None) from a real DECODE FAILURE (corrupt /
# schema-drifted JSON) so callers can surface it instead of silently zeroing.
decode_streams : [NotNull Str, Null] -> { streams : StreamsResp, failed : Bool }
decode_streams = |raw|
    when raw is
        NotNull(text) ->
            decoded : Result StreamsResp _
            decoded = Decode.from_bytes(Str.to_utf8(text), Json.utf8)
            when decoded is
                Ok(s) -> { streams: s, failed: Bool.false }
                Err(_) -> { streams: empty_streams, failed: Bool.true }

        Null -> { streams: empty_streams, failed: Bool.false }

# pair up stream time+value samples, dropping nulls
stream_pairs : Option StreamSeq, Option StreamSeq -> List { t : I64, v : F64 }
stream_pairs = |time_opt, val_opt|
    when (Option.get(time_opt), Option.get(val_opt)) is
        (Some(ts), Some(vs)) ->
            maybe_pairs = List.map2(
                ts.data,
                vs.data,
                |ot, ov|
                    when (Option.get(ot), Option.get(ov)) is
                        (Some(t), Some(v)) -> Ok({ t: Num.round(t), v })
                        _ -> Err({}),
            )
            List.keep_oks(maybe_pairs, |p| p)

        _ -> []

# the {} 404-marker decodes cleanly to "no streams", NOT a failure
expect
    d = decode_streams(NotNull("{}"))
    d.failed == Bool.false and List.is_empty(stream_pairs(d.streams.time, d.streams.heartrate))

# corrupt JSON is a FAILURE (so analyze can say "unreadable"), not silent zeros
expect decode_streams(NotNull("not json at all")).failed == Bool.true

# absent row (Null) is genuine no-data, not a failure
expect decode_streams(Null).failed == Bool.false

# real payload: pairs join on index, null samples dropped
expect
    d = decode_streams(NotNull("{\"time\":{\"data\":[0,1,2]},\"heartrate\":{\"data\":[100,null,120]}}"))
    pairs = stream_pairs(d.streams.time, d.streams.heartrate)
    !(d.failed) and List.len(pairs) == 2 and (List.last(pairs) |> Result.map_ok(|p| p.t == 2) |> Result.with_default(Bool.false))
