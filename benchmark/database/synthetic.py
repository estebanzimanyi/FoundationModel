"""Table tab:synthetic of Section 7 of the paper: synthetic gaps of increasing length on moving vessels.

    python synthetic.py points    the stretches, into the tables SynthGaps(GapId, MMSI) and
                                  SynthPoints(GapId, PointIdx, T, Lat, Lon, SOG, COG, ROT, InGap, Geom)
    python synthetic.py           the reconstructions of their central minutes and their errors

The first sequence of at least 181 minutes of the trip of each vessel in Ships is sampled every minute
with tsample, from the minute after it starts, and kept when its mean speed, its haversine path length
over its duration, is of 3 knots or more (693 stretches on January 20, 2026). The stretches have the
columns of TripPoints and Gaps, so that 02_context.sql, 03_descriptions.sql, and embed.py give their
positions the context, the descriptions, and the embeddings of the windows of the day (SynthContext,
SynthDescriptor, SynthEmbedding; CROSSDOMAIN=1 of reproduce.sh).

Their central K minutes are hidden and reconstructed by the reconstructions of the section:
  crossdomain  the model with all its channels, the semantic one from SynthEmbedding (run only when
               that table has rows);
  coordinates  the model with the kinematic and the semantic channels replaced by their unknown tokens;
  kinematic    the reference of kinematic.sql between the two visible positions a and b that bound the
               hidden block: the cubic Hermite curve with the speed and the course reported at a and b
               when both speeds are of 3 knots or more, the segment from a to b otherwise;
  unitraj      UniTraj with the three normalizations of run_unitraj.py (unitraj, unitraj-sd, unitraj-wt).
The channels of the model are those of run_model.py. Their haversine errors to the sampled truth are
averaged per stretch; the medians and means over the stretches, and the share of the stretches in which
one reconstruction has the smaller error than another, are printed and written to
RESULTS/synthetic.json (RESULTS defaults to results/ beside this file).

    THESIS=<checkout of this repository at 8fc3ca2> UNITRAJ=<checkout of Yasoz/UniTraj> python synthetic.py
"""
import json, math, os, sys, statistics as st
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
import numpy as np
import psycopg

SPAN = 181


def hav(a, b):
    p = math.pi / 180
    x = math.sin((b[0] - a[0]) * p / 2) ** 2 + math.cos(a[0] * p) * math.cos(b[0] * p) * math.sin((b[1] - a[1]) * p / 2) ** 2
    return 2 * 6371008.8 * math.asin(math.sqrt(x))


if len(sys.argv) > 1 and sys.argv[1] == 'points':
    with psycopg.connect() as conn:
        conn.execute("SET TimeZone = 'UTC'")
        rows = conn.execute(f"""
          WITH Seqs AS (
            SELECT MMSI, s.Seq FROM Ships, unnest(sequences(Trip)) AS s(Seq)
            WHERE duration(s.Seq) >= interval '{SPAN} minutes' ),
          Picked AS (
            SELECT MMSI, startTimestamp(Seq) AS T0, row_number() OVER (PARTITION BY MMSI ORDER BY startTimestamp(Seq)) AS k
            FROM Seqs )
          SELECT p.MMSI, getTimestamp(i), ST_Y(valueAtTimestamp(s.TripLonLat, getTimestamp(i))),
                 ST_X(valueAtTimestamp(s.TripLonLat, getTimestamp(i))), valueAtTimestamp(s.SOG, getTimestamp(i)),
                 valueAtTimestamp(s.COG, getTimestamp(i)), valueAtTimestamp(s.ROT, getTimestamp(i))
          FROM Picked p JOIN Ships s USING (MMSI),
            unnest(instants(tsample(atTime(s.Trip, span(date_bin('1 minute', p.T0, '2000-01-03') + interval '1 minute',
              date_bin('1 minute', p.T0, '2000-01-03') + interval '{SPAN + 1} minutes')), interval '1 minute'))) AS i
          WHERE p.k = 1
          ORDER BY p.MMSI, 2""").fetchall()
        tracks = defaultdict(list)
        for r in rows:
            tracks[r[0]].append(r[1:])
        # keep complete stretches of moving vessels (mean speed of 3 knots or more)
        sel = []
        for m, t in tracks.items():
            if len(t) != SPAN: continue
            dist = sum(hav((a[1], a[2]), (b[1], b[2])) for a, b in zip(t, t[1:]))
            if dist / (t[-1][0] - t[0][0]).total_seconds() * 1.9438445 >= 3: sel.append((m, t))
        conn.execute('DROP TABLE IF EXISTS SynthGaps, SynthPoints CASCADE')
        conn.execute('CREATE TABLE SynthGaps(GapId bigint PRIMARY KEY, MMSI bigint)')
        conn.execute('CREATE TABLE SynthPoints(GapId bigint, PointIdx bigint, T timestamptz, Lat float8, '
                     'Lon float8, SOG float8, COG float8, ROT float8, InGap boolean, Geom geometry, '
                     'PRIMARY KEY (GapId, PointIdx))')
        with conn.cursor().copy('COPY SynthGaps FROM STDIN') as copy:
            for g, (m, _) in enumerate(sel, 1):
                copy.write_row((g, m))
        with conn.cursor().copy('COPY SynthPoints (GapId, PointIdx, T, Lat, Lon, SOG, COG, ROT, InGap) FROM STDIN') as copy:
            for g, (_, t) in enumerate(sel, 1):
                for i, r in enumerate(t):
                    copy.write_row((g, i, *r, False))
        # the position in EPSG:25832 from the trip, as TripPoints has it
        conn.execute('UPDATE SynthPoints p SET Geom = valueAtTimestamp(s.Trip, p.T) '
                     'FROM SynthGaps g JOIN Ships s USING (MMSI) WHERE g.GapId = p.GapId')
        conn.execute('ANALYZE SynthPoints')
    print(len(sel), 'stretches of moving vessels in SynthGaps and SynthPoints')
    sys.exit()

import torch  # noqa: E402

THESIS = Path(os.environ['THESIS'])
sys.path.insert(0, str(THESIS / 'models'))
from config import ModelConfig  # noqa: E402
from data import _pad  # noqa: E402
from model import TrajectoryMaskedAutoEncoder  # noqa: E402

MAX_LEN, DEV = 256, torch.device('cuda' if torch.cuda.is_available() else 'cpu')
ckpt = torch.load(THESIS / 'models' / 'checkpoints' / 'best.pt', map_location=DEV, weights_only=False)
cfg = ckpt['cfg'] if not isinstance(ckpt['cfg'], dict) else ModelConfig(**ckpt['cfg'])
model = TrajectoryMaskedAutoEncoder(cfg).to(DEV)
model.load_state_dict(ckpt['model'], strict=True)
model.eval()
# the UniTraj adapter of this repository (run_unitraj.py), whose model code postdates 8fc3ca2
REPO = Path(__file__).resolve().parents[2]
for _p in (REPO / 'models', REPO / 'benchmark', REPO / 'models' / 'checkpoints'):
    sys.path.insert(0, str(_p))
for _m in ('config', 'model', 'data'):
    sys.modules.pop(_m, None)
import utils  # noqa: E402  (models/checkpoints/utils.py of the thesis)
np.random.seed(0); torch.manual_seed(0)
ut = utils.load_unitraj_model(Path(os.environ['UNITRAJ']), device=DEV)
UT_LEN = int(ut.encoder.num_tokens)
RESULTS = Path(os.environ.get('RESULTS', Path(__file__).with_name('results')))
RESULTS.mkdir(parents=True, exist_ok=True)


def unitraj_preds(batch, masked, scope):
    # #predict_and_save_unitraj inputs, origin and statistics from the visible positions (run_unitraj.py)
    vis = np.flatnonzero(~masked); hid = np.flatnonzero(masked)
    ll = np.array([[[r[2], r[1]] for r in t] for t in batch], np.float64)
    origin = ll[:, vis[0]]
    off = ll - origin[:, None, :]
    mean, std = utils._unitraj_stats([{'dataset': 'dma', 'lonlat': off[i, vis] + origin[i]} for i in range(len(batch))], scope)['dma']
    z = (off - mean) / std; z[:, hid] = 0.0
    traj = np.zeros((len(batch), 2, UT_LEN), np.float32); traj[:, :, :SPAN] = z.transpose(0, 2, 1)
    ts = np.array([[r[0] for r in t] for t in batch])
    interv = np.zeros((len(batch), UT_LEN), np.float32); interv[:, :SPAN] = np.clip(ts - ts[:, :1], 0, 15.0)
    mi = np.tile(hid, (len(batch), 1)).astype(np.int64)
    with torch.no_grad():
        pp, _ = ut(torch.from_numpy(traj).to(DEV), torch.from_numpy(interv).to(DEV), torch.from_numpy(mi).to(DEV))
    return pp.cpu().numpy().transpose(0, 2, 1)[:, :SPAN] * std + mean + origin[:, None, :]
UNITRAJ = {'unitraj': 'robust', 'unitraj-sd': 'std', 'unitraj-wt': 'worldtrace'}


def channels(t, masked, sem):
    ts = np.array([r[0] for r in t]); lat = np.array([r[1] for r in t]); lon = np.array([r[2] for r in t])
    vis = np.flatnonzero(~masked)
    lat0, lon0 = lat[vis[0]], lon[vis[0]]
    d = np.stack([lat - lat0, lon - lon0], axis=1); d[masked] = np.nan
    bh = max(np.nanmax(np.abs(d)), 1e-8)
    coords = np.nan_to_num(d / bh).astype(np.float32)
    dt = ts - ts[0]; lm = math.log1p(dt.max())
    loc = [datetime.fromtimestamp(x, timezone.utc) + timedelta(hours=1) for x in ts]
    tau = np.stack([[x.weekday() / 6 for x in loc], [x.hour / 23 for x in loc], [x.minute / 59 for x in loc],
                    np.log1p(dt) / lm], axis=1).astype(np.float32)
    f = lambda k: np.array([r[k] if r[k] is not None else 0.0 for r in t], dtype=np.float32)
    kin = np.stack([np.clip(f(3) / 30, 0, 1), np.clip(f(4) / 180 - 1, -1, 1), np.clip(f(5) / 720, -1, 1)], axis=1).astype(np.float32)
    kin[masked] = 0
    sem = sem.copy(); sem[masked] = 0
    cp, pm = _pad(coords, MAX_LEN)
    return dict(x_spatial=cp, coords=cp, tau=_pad(tau, MAX_LEN)[0], kinematics=_pad(kin, MAX_LEN)[0], pad_mask=pm,
                pos_mask=_pad(masked[:, None], MAX_LEN)[0][:, 0], e_sem=_pad(sem, MAX_LEN)[0]), (lat0, lon0, bh)


# the interior case of kinematic.sql, on the two visible positions that bound the hidden block
KINEMATIC = """
WITH Ends AS (
  SELECT p.GapId, p.PointIdx, p.T, p.Geom, p.SOG,
    CASE WHEN p.COG IS NOT NULL THEN ST_Azimuth(p.Geom, ST_Transform(ST_Project(
      ST_Transform(p.Geom, 4326)::geography, 1000, radians(p.COG))::geometry, 25832)) END AS Az
  FROM SynthPoints p WHERE p.PointIdx IN (%(a)s - 1, %(b)s) ),
Neighbors AS (
  SELECT q.GapId, q.PointIdx, a.Geom AS GA, a.SOG AS KA, a.Az AS AzA, b.Geom AS GB, b.SOG AS KB, b.Az AS AzB,
    extract(epoch FROM b.T - a.T) AS D, extract(epoch FROM q.T - a.T) / extract(epoch FROM b.T - a.T) AS s
  FROM SynthPoints q JOIN Ends a ON a.GapId = q.GapId AND a.PointIdx = %(a)s - 1
    JOIN Ends b ON b.GapId = q.GapId AND b.PointIdx = %(b)s
  WHERE q.PointIdx >= %(a)s AND q.PointIdx < %(b)s ),
Rec AS (
  SELECT GapId, PointIdx, ST_Transform(CASE
    WHEN KA >= 3 AND KB >= 3 AND AzA IS NOT NULL AND AzB IS NOT NULL THEN
      ST_SetSRID(ST_MakePoint(
        (2*s^3 - 3*s^2 + 1) * ST_X(GA) + (s^3 - 2*s^2 + s) * D * KA * 1852 / 3600 * sin(AzA)
          + (-2*s^3 + 3*s^2) * ST_X(GB) + (s^3 - s^2) * D * KB * 1852 / 3600 * sin(AzB),
        (2*s^3 - 3*s^2 + 1) * ST_Y(GA) + (s^3 - 2*s^2 + s) * D * KA * 1852 / 3600 * cos(AzA)
          + (-2*s^3 + 3*s^2) * ST_Y(GB) + (s^3 - s^2) * D * KB * 1852 / 3600 * cos(AzB)), 25832)
    ELSE ST_LineInterpolatePoint(ST_MakeLine(GA, GB), s) END, 4326) AS G
  FROM Neighbors )
SELECT GapId, PointIdx, ST_Y(G), ST_X(G) FROM Rec"""

with psycopg.connect() as conn:
    gaps = defaultdict(list)
    for g, ts, lat, lon, sog, cog, rot in conn.execute(
            'SELECT GapId, extract(epoch FROM T), Lat, Lon, SOG, COG, ROT FROM SynthPoints ORDER BY GapId, PointIdx'):
        gaps[g].append((float(ts), lat, lon, sog, cog, rot))
    ids = sorted(gaps); sel = [gaps[g] for g in ids]
    emb = {}
    if conn.execute("SELECT to_regclass('synthembedding') IS NOT NULL").fetchone()[0]:
        emb = {(g, i): np.asarray(e, np.float32) for g, i, e in conn.execute('SELECT GapId, PointIdx, Emb FROM SynthEmbedding')}
    print(len(sel), 'stretches of moving vessels,', len(emb), 'embedded positions')
    MODELS = ([('crossdomain', False)] if emb else []) + [('coordinates', True)]
    NAMES = [m for m, _ in MODELS] + ['kinematic'] + list(UNITRAJ)
    zero = np.zeros(cfg.sem_dim, np.float32)
    sems = [np.stack([emb.get((g, i), zero) for i in range(SPAN)]) for g in ids]

    res = {}
    print('K minutes hidden | median / mean error in meters per stretch of ' + ', '.join(NAMES))
    for K in (5, 10, 20, 30, 45, 60, 90, 120):
        a = (SPAN - K) // 2; masked = np.zeros(SPAN, bool); masked[a:a + K] = True
        err = {m: [] for m in NAMES}
        kin = {(g, i): (lat, lon) for g, i, lat, lon in conn.execute(KINEMATIC, dict(a=a, b=a + K))}
        for b in range(0, len(sel), 256):
            batch, bids, bsem = sel[b:b + 256], ids[b:b + 256], sems[b:b + 256]
            for name, group_masked in MODELS:
                inputs, params = zip(*(channels(t, masked, s) for t, s in zip(batch, bsem)))
                tt = {k: torch.as_tensor(np.stack([x[k] for x in inputs])).to(DEV) for k in inputs[0]}
                with torch.no_grad():
                    out = model(**tt, domain_ids=torch.ones(len(batch), dtype=torch.long, device=DEV),
                                kin_group_masked=group_masked, sem_group_masked=group_masked)
                y = out['pred'][..., :2].cpu().numpy()
                for t, (lat0, lon0, bh), yy in zip(batch, params, y):
                    err[name].append(st.mean(hav((t[j][1], t[j][2]), (lat0 + yy[j, 0] * bh, lon0 + yy[j, 1] * bh))
                                             for j in range(a, a + K)))
            for name, scope in UNITRAJ.items():
                for t, u in zip(batch, unitraj_preds(batch, masked, scope)):
                    err[name].append(st.mean(hav((t[j][1], t[j][2]), (u[j, 1], u[j, 0])) for j in range(a, a + K)))
            for g, t in zip(bids, batch):
                err['kinematic'].append(st.mean(hav((t[j][1], t[j][2]), kin[(g, j)]) for j in range(a, a + K)))
        res[K] = {'stretches': len(sel),
                  'median': {m: st.median(e) for m, e in err.items()},
                  'mean': {m: st.mean(e) for m, e in err.items()},
                  'better': {f'{x} < {y}': sum(u < v for u, v in zip(err[x], err[y])) / len(sel)
                             for x in NAMES for y in NAMES if x != y}}
        print(f'{K:4d} | median ' + ' '.join(f'{res[K]["median"][m]:7.0f}' for m in NAMES)
              + ' | mean ' + ' '.join(f'{res[K]["mean"][m]:7.0f}' for m in NAMES))
    (RESULTS / 'synthetic.json').write_text(json.dumps(res, indent=1))
    print('written', RESULTS / 'synthetic.json')
