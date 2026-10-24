"""Tests for packaging/upstream-watch/watch.py with fake upstream answers and a
fake issue tracker; nothing here touches the network."""
import importlib.util
import json
import pathlib
import unittest
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("watch", ROOT / "packaging/upstream-watch/watch.py")
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

SUPPORTED = json.loads((ROOT / "packaging/upstream-watch/supported.json").read_text())


def release(tag, prerelease=False, draft=False, repo="x/y"):
    return {"tag_name": tag, "html_url": f"https://github.com/{repo}/releases/tag/{tag}",
            "prerelease": prerelease, "draft": draft}


def steam_manifest(version):
    # Tab-separated, as Valve serves it
    return f'"osx"\n{{\n\t"version"\t\t"{version}"\n\t"ostype"\t\t"macos1015"\n\t"tenfoot_images_all"\n\t{{\n\t}}\n}}\n'


def upstream(steam_stable="1791918634", steam_beta="1792192922", crossover="26.3.0", wine="11.18",
             dxmt="v0.80", apple="4", gptk="Game-Porting-Toolkit-3.0-3", notproton="v1.2.0"):
    """Answers as of the 2026-10-19 baseline, with any value replaced."""
    return {
        "https://api.github.com/repos/NotProtonNot/NotProton/releases?per_page=10":
            json.dumps([release(notproton, repo="NotProtonNot/NotProton"), release("v1.1.9")]),
        watch.STEAM_MANIFESTS["stable"]: steam_manifest(steam_stable),
        watch.STEAM_MANIFESTS["beta"]: steam_manifest(steam_beta),
        watch.CROSSOVER_PAGE: f'<a href="https://media.codeweavers.com/pub/crossover/source/crossover-sources-'
                              f'{crossover}.tar.gz">Download FOSS Code for CrossOver {crossover}</a>'
                              '<a href="/pub/crossover/source/crossover-sources-25.1.1.tar.gz">old</a>',
        "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=10":
            json.dumps([release(wine, repo="Gcenx/macOS_Wine_builds"), release("11.17")]),
        "https://api.github.com/repos/3Shain/dxmt/releases?per_page=10":
            json.dumps([release("v0.90-rc1", prerelease=True), release(dxmt, repo="3Shain/dxmt")]),
        watch.APPLE_GPTK_PAGE: f"<h1>Game Porting Toolkit {apple}</h1><p>Metal 4</p>",
        "https://api.github.com/repos/Gcenx/game-porting-toolkit/releases?per_page=10":
            json.dumps([release(gptk, repo="Gcenx/game-porting-toolkit")]),
    }


def fetcher(answers):
    def fetch(url):
        if url not in answers:
            raise OSError(f"unexpected fetch {url}")
        return answers[url]
    return fetch


class FakeIssues:
    def __init__(self, titles=()):
        self.existing = set(titles)
        self.created = []
        self.labelled = 0

    def titles(self):
        return set(self.existing)

    def ensure_label(self):
        self.labelled += 1

    def create(self, title, body):
        self.created.append((title, body))
        self.existing.add(title)
        return f"https://github.com/BRYANN2K/cartouche/issues/{len(self.created)}"


def quiet(_):
    pass


class Watch(unittest.TestCase):

    def test_baseline_opens_nothing(self):
        issues = FakeIssues()
        opened, failed = watch.run(fetcher(upstream()), issues, SUPPORTED, out=quiet)
        self.assertEqual((opened, failed, issues.created), ([], [], []))

    def test_new_steam_client_opens_one_issue_then_none_the_next_night(self):
        issues = FakeIssues()
        answers = upstream(steam_beta="1799999999")
        opened, _ = watch.run(fetcher(answers), issues, SUPPORTED, out=quiet)
        self.assertEqual(opened, ["Upstream: Steam client 1799999999"])
        title, body = issues.created[0]
        self.assertEqual(title, "Upstream: Steam client 1799999999")
        self.assertIn("Link: https://client-update.steamstatic.com/steam_client_publicbeta_osx", body)
        self.assertIn("Branch: beta.", body)

        opened, _ = watch.run(fetcher(answers), issues, SUPPORTED, out=quiet)
        self.assertEqual(opened, [])
        self.assertEqual(len(issues.created), 1)

    def test_closed_issue_still_counts_as_reported(self):
        # titles() covers state=all, so a closed issue is in the set too
        issues = FakeIssues(["Upstream: Steam client 1799999999"])
        opened, _ = watch.run(fetcher(upstream(steam_stable="1799999999")), issues, SUPPORTED, out=quiet)
        self.assertEqual(opened, [])

    def test_same_version_on_both_branches_opens_one_issue(self):
        issues = FakeIssues()
        opened, _ = watch.run(fetcher(upstream(steam_stable="1799999999", steam_beta="1799999999")),
                              issues, SUPPORTED, out=quiet)
        self.assertEqual(opened, ["Upstream: Steam client 1799999999"])

    def test_every_source_reports_its_change(self):
        issues = FakeIssues()
        answers = upstream(crossover="26.4.0", wine="11.19", dxmt="v0.81", apple="5",
                           gptk="Game-Porting-Toolkit-3.1", notproton="v1.3.0")
        opened, failed = watch.run(fetcher(answers), issues, SUPPORTED, out=quiet)
        self.assertEqual(failed, [])
        self.assertEqual(sorted(opened), sorted([
            "Upstream: NotProton 1.3.0",
            "Upstream: CrossOver source 26.4.0",
            "Upstream: Wine macOS build 11.19",
            "Upstream: DXMT 0.81",
            "Upstream: Game Porting Toolkit 5",
            "Upstream: Game Porting Toolkit 3.1",
        ]))
        bodies = dict(issues.created)
        self.assertIn("https://github.com/NotProtonNot/NotProton/releases/tag/v1.3.0",
                      bodies["Upstream: NotProton 1.3.0"])
        self.assertIn("crossover-sources-26.4.0.tar.gz", bodies["Upstream: CrossOver source 26.4.0"])
        self.assertIn("never redistributes", bodies["Upstream: Game Porting Toolkit 5"])

    def test_prereleases_and_drafts_are_ignored(self):
        _, failed = watch.run(fetcher(upstream()), FakeIssues(), SUPPORTED, out=quiet)
        self.assertEqual(failed, [])
        self.assertEqual(watch.dxmt(fetcher(upstream()))[0].version, "0.80")

    def test_a_broken_source_fails_alone(self):
        answers = upstream(steam_beta="1799999999")
        answers[watch.CROSSOVER_PAGE] = "<html>redesigned page</html>"
        issues = FakeIssues()
        opened, failed = watch.run(fetcher(answers), issues, SUPPORTED, out=quiet)
        self.assertEqual(failed, ["crossover"])
        self.assertEqual(opened, ["Upstream: Steam client 1799999999"])

    def test_dry_run_opens_nothing(self):
        issues = FakeIssues()
        opened, _ = watch.run(fetcher(upstream(steam_beta="1799999999")), issues, SUPPORTED, dry_run=True,
                              out=quiet)
        self.assertEqual(opened, ["Upstream: Steam client 1799999999"])
        self.assertEqual((issues.created, issues.labelled), ([], 0))

    def test_crossover_takes_the_highest_version(self):
        page = "crossover-sources-26.10.0.tar.gz crossover-sources-26.9.1.tar.gz"
        self.assertEqual(watch.crossover(fetcher({watch.CROSSOVER_PAGE: page}))[0].version, "26.10.0")


class Tracker(unittest.TestCase):
    """GitHubIssues against a fake REST endpoint."""

    def test_titles_page_through_all_issues(self):
        calls = []

        def request(method, url, body, token):
            calls.append((method, url))
            page = int(url.rsplit("page=", 1)[1])
            return [{"title": f"t{page}-{i}"} for i in range(100 if page == 1 else 3)]

        titles = watch.GitHubIssues("BRYANN2K/cartouche", "tok", request).titles()
        self.assertEqual(len(titles), 103)
        self.assertIn("state=all", calls[0][1])
        self.assertIn("labels=upstream", calls[0][1])
        self.assertEqual(len(calls), 2)

    def test_existing_label_is_fine_and_other_errors_are_not(self):
        def exists(method, url, body, token):
            raise urllib.error.HTTPError(url, 422, "already_exists", {}, None)
        watch.GitHubIssues("r/r", "t", exists).ensure_label()

        def forbidden(method, url, body, token):
            raise urllib.error.HTTPError(url, 403, "forbidden", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            watch.GitHubIssues("r/r", "t", forbidden).ensure_label()

    def test_create_sends_the_label(self):
        sent = {}

        def request(method, url, body, token):
            sent.update(method=method, url=url, body=body)
            return {"html_url": "https://github.com/r/r/issues/7"}

        url = watch.GitHubIssues("BRYANN2K/cartouche", "t", request).create("Upstream: DXMT 0.81", "b")
        self.assertEqual(url, "https://github.com/r/r/issues/7")
        self.assertEqual(sent["url"], "https://api.github.com/repos/BRYANN2K/cartouche/issues")
        self.assertEqual(sent["body"]["labels"], ["upstream"])


if __name__ == "__main__":
    unittest.main()
