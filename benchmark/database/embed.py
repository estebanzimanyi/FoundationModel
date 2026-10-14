"""Embed the descriptions of PointDescriptor into the table PointEmbedding(GapId, PointIdx, Emb), or
of the tables that DESCRIPTOR and EMBEDDING name, as for the stretches of synthetic.py
(SynthDescriptor, SynthEmbedding).

The descriptions are encoded by the encoder of the thesis (enrichment-pipeline/shared/encoder.py,
class SemanticEncoder) with the settings with which the corpus was encoded: EmbeddingGemma
(google/embeddinggemma-300m) with outputs truncated to 256 dimensions and normalized, in bfloat16
on a GPU. The embeddings are written with the COPY protocol of psycopg.

    THESIS=<clone of MobilityDB/FoundationModel> python embed.py

The connection is given by the PostgreSQL environment variables (PGDATABASE, PGHOST, ...).
EmbeddingGemma is a gated model: its license must be accepted on its Hugging Face page and a
token stored with `hf auth login` before the first run.
"""
import os
import sys
from pathlib import Path

import psycopg
from psycopg import sql

sys.path.insert(0, str(Path(os.environ['THESIS']) / 'enrichment-pipeline' / 'shared'))
from encoder import SemanticEncoder  # noqa: E402

DESCRIPTOR = sql.Identifier(os.environ.get('DESCRIPTOR', 'PointDescriptor').lower())
EMBEDDING = sql.Identifier(os.environ.get('EMBEDDING', 'PointEmbedding').lower())

with psycopg.connect() as conn:
    rows = conn.execute(sql.SQL(
        'SELECT GapId, PointIdx, Description FROM {} ORDER BY GapId, PointIdx').format(DESCRIPTOR)
    ).fetchall()
    encoder = SemanticEncoder(model_name='google/embeddinggemma-300m', truncate_dim=256,
                              batch_size=256, trust_remote_code=True)
    embs = encoder.encode([r[2] for r in rows], show_progress=True)
    conn.execute(sql.SQL('DROP TABLE IF EXISTS {} CASCADE').format(EMBEDDING))
    conn.execute(sql.SQL('CREATE TABLE {}(GapId bigint, PointIdx bigint, Emb real[], '
                         'PRIMARY KEY (GapId, PointIdx))').format(EMBEDDING))
    with conn.cursor().copy(sql.SQL('COPY {} FROM STDIN').format(EMBEDDING)) as copy:
        for (gap, idx, _), emb in zip(rows, embs):
            copy.write_row((gap, idx, emb.astype(float).tolist()))
    print(f'{len(rows)} descriptions embedded in {embs.shape[1]} dimensions')
