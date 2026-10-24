import datetime
import pathlib

from compatdata import build, cache, replay

FIXTURES = pathlib.Path(__file__).resolve().parents[1] / "fixtures" / "2026-10-19"
NIGHT = datetime.datetime(2026, 10, 19, 3, 17, tzinfo=datetime.timezone.utc)


def quiet(*_):
    pass


def build_fixtures(now=NIGHT, previous=None, down=(), store=None):
    fetcher = replay.FixtureFetcher(FIXTURES, down=down)
    document = build.build(fetcher, store or cache.Cache(), now, previous=previous, log=quiet)
    return document, fetcher
