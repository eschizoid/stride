# Mock Strava API for stride e2e — serves the four endpoints sync/auth/ftp use.
# Deterministic fixture data; page 2+ is empty so fetch_pages! terminates.
app [Model, init!, respond!] { web: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.13.1/7P4PF5rntQVkys5JbIHqkMpZIXo-pxa5lVqOdh7z8fE.tar.br" }

import web.Http exposing [Request, Response]

Model : {}

init! : {} => Result Model _
init! = |{}| Ok({})

respond! : Request, Model => Result Response [ServerErr Str]_
respond! = |req, _model|
    if Str.contains(req.uri, "/oauth/token") then
        json(
            """
            {"access_token":"mock-access","refresh_token":"mock-refresh","expires_at":9999999999}
            """,
        )
    else if Str.contains(req.uri, "/api/v3/athlete/activities") then
        if Str.contains(req.uri, "page=1") then
            json(
                """
                [{"id":501,"name":"Mock Power Ride","sport_type":"Ride","start_date_local":"2026-07-28T10:00:00Z","moving_time":3600,"distance":30000.0,"total_elevation_gain":100.0,"average_watts":200.0,"weighted_average_watts":205.0},
                 {"id":502,"name":"Mock HR Row","sport_type":"Rowing","start_date_local":"2026-07-29T10:00:00Z","moving_time":1800,"distance":5000.0,"total_elevation_gain":0.0,"average_heartrate":150.0}]
                """,
            )
        else
            json("[]")
    else if Str.contains(req.uri, "/streams") then
        if Str.contains(req.uri, "/activities/501/") then
            # 60 samples, 30s apart: constant 200W, HR ramp — enough for NP + zones
            json(
                """
                {"time":{"data":[0,30,60,90,120,150,180,210,240,270,300,330,360,390,420,450,480,510,540,570,600,630,660,690,720,750,780,810,840,870,900,930,960,990,1020,1050,1080,1110,1140,1170,1200,1230,1260,1290,1320,1350,1380,1410,1440,1470,1500,1530,1560,1590,1620,1650,1680,1710,1740,1770]},"watts":{"data":[200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200]},"heartrate":{"data":[120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179]}}
                """,
            )
        else
            # 404 = "no streams recorded" — exercises the {} marker path
            Ok({ status: 404, headers: [], body: Str.to_utf8("{}") })
    else if Str.contains(req.uri, "/api/v3/athlete") then
        # PUT ftp update (and GET athlete) — echo success
        json(
            """
            {"id":1,"ftp":243}
            """,
        )
    else
        Ok({ status: 404, headers: [], body: Str.to_utf8("not found") })

json : Str -> Result Response [ServerErr Str]_
json = |body|
    Ok({ status: 200, headers: [{ name: "Content-Type", value: "application/json" }], body: Str.to_utf8(body) })
