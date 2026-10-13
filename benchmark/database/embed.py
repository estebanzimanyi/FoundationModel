"""Embed the descriptions of PointDescriptor into the table PointEmbedding(GapId, PointIdx, Emb).

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

sys.path.insert(0, str(Path(os.environ['THESIS']) / 'enrichment-pipeline' / 'shared'))
from encoder import SemanticEncoder  # noqa: E402

with psycopg.connect() as conn:
    rows = conn.execute(
        'SELECT GapId, PointIdx, Description FROM PointDescriptor ORDER BY GapId, PointIdx'
    ).fetchall()
    encoder = SemanticEncoder(model_name='google/embeddinggemma-300m', truncate_dim=256,
                              batch_size=256, trust_remote_code=True)
    embs = encoder.encode([r[2] for r in rows], show_progress=True)
    conn.execute('DROP TABLE IF EXISTS PointEmbedding CASCADE')
    conn.execute('CREATE TABLE PointEmbedding(GapId bigint, PointIdx bigint, Emb real[], '
                 'PRIMARY KEY (GapId, PointIdx))')
    with conn.cursor().copy('COPY PointEmbedding FROM STDIN') as copy:
        for (gap, idx, _), emb in zip(rows, embs):
            copy.write_row((gap, idx, emb.astype(float).tolist()))
    print(f'{len(rows)} descriptions embedded in {embs.shape[1]} dimensions')
