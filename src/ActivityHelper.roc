import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path

ActivityHelper :: [].{
    ActivityDetail : { max_hr : F64, best_60 : F64, best_180 : F64, best_300 : F64, best_1200 : F64, easy_s : I64, moderate_s : I64, hard_s : I64, failed : Bool }
    decoder_path! = |_| {
        override = match Env.var_str!(OsStr.from_str("STRIDE_ACTIVITY_DECODER")) { Ok(path) => path  Err(_) => "" }
        home = match Env.var_str!(OsStr.from_str("HOME")) { Ok(path) => path  Err(_) => "" }
        candidates = List.join([
            if Str.is_empty(override) [] else [override],
            ["/usr/local/libexec/stride_activity_file.py"],
            if Str.is_empty(home) [] else ["${home}/.local/lib/stride/stride_activity_file.py"],
            ["tools/stride_activity_file.py"],
        ])
        find_decoder!(candidates)
    }

    find_decoder! = |paths|
        match paths {
            [] => Err(ActivityDecoderNotFound)
            [path, .. as rest] =>
                match Path.type!(Path.utf8(path)) {
                    Ok(IsFile) => Ok(path)
                    _ => find_decoder!(rest)
                }
        }

    analyze_export! = |db, activity_id, ftp, threshold, z1, z2, z3, z4, signature, revision| {
        decoder = decoder_path!({})?
        args = [
            decoder,
            "--analyze-store",
            db,
            I64.to_str(activity_id),
            F64.to_str(ftp),
            F64.to_str(threshold),
            F64.to_str(z1),
            F64.to_str(z2),
            F64.to_str(z3),
            F64.to_str(z4),
            signature,
            I64.to_str(revision),
        ]
        output = Cmd.new(OsStr.from_str("python3")).args(List.map(args, OsStr.from_str)).exec_output!()?
        Ok(Str.trim(output.stdout_utf8) == "1")
    }

    activity_detail! : Str, I64, F64 => Try(ActivityDetail, _)
    activity_detail! = |db, activity_id, ftp| {
        decoder = decoder_path!({})?
        args = [decoder, "--activity-detail", db, I64.to_str(activity_id), F64.to_str(ftp)]
        output = Cmd.new(OsStr.from_str("python3")).args(List.map(args, OsStr.from_str)).exec_output!()?
        Json.parse(output.stdout_utf8)
    }
}
