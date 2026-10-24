import email.message
import io
import unittest
import urllib.error

from compatdata import http


class FakeOpener:
    """Answers from a script: an int is an HTTP error, an exception is raised, bytes are a body."""

    def __init__(self, *script, headers=None):
        self.script = list(script)
        self.headers = headers or {}
        self.requests = []

    def open(self, request, timeout=None):
        self.requests.append(request)
        step = self.script.pop(0)
        if isinstance(step, int):
            headers = email.message.Message()
            for key, value in self.headers.items():
                headers[key] = value
            raise urllib.error.HTTPError(request.full_url, step, "error", headers, io.BytesIO())
        if isinstance(step, Exception):
            raise step
        return io.BytesIO(step)


class Clock:
    def __init__(self):
        self.now = 0.0
        self.slept = []

    def sleep(self, seconds):
        self.slept.append(round(seconds, 3))
        self.now += seconds

    def __call__(self):
        return self.now


def fetcher(opener, **options):
    clock = Clock()
    return http.Fetcher(opener=opener, sleep=clock.sleep, clock=clock, **options), clock


class FetcherTests(unittest.TestCase):
    def test_busy_host_is_asked_again_with_growing_waits(self):
        f, clock = fetcher(FakeOpener(503, 502, b"ok"), interval=0)
        self.assertEqual(f.get("https://example.org/a"), b"ok")
        self.assertEqual(clock.slept, [2.0, 4.0])

    def test_retry_after_is_honored(self):
        f, clock = fetcher(FakeOpener(429, b"ok", headers={"Retry-After": "30"}), interval=0)
        f.get("https://example.org/a")
        self.assertEqual(clock.slept, [30.0])

    def test_missing_page_is_not_asked_again(self):
        opener = FakeOpener(404)
        f, _ = fetcher(opener)
        with self.assertRaises(http.Unavailable):
            f.get("https://example.org/a")
        self.assertEqual(len(opener.requests), 1)

    def test_unreachable_host_gives_up_after_the_attempts(self):
        opener = FakeOpener(*[urllib.error.URLError("refused")] * 4)
        f, clock = fetcher(opener, interval=0)
        with self.assertRaises(http.Unavailable) as caught:
            f.get("https://example.org/a")
        self.assertEqual(len(opener.requests), 4)
        self.assertEqual(clock.slept, [2.0, 4.0, 8.0])
        self.assertIn("refused", str(caught.exception))

    def test_requests_to_one_host_are_spaced(self):
        f, clock = fetcher(FakeOpener(b"1", b"2", b"3"), interval=1.0)
        f.get("https://example.org/a")
        f.get("https://example.org/b")
        f.get("https://other.example/c")
        self.assertEqual(clock.slept, [1.0])

    def test_user_agent_and_query(self):
        opener = FakeOpener(b"ok")
        f, _ = fetcher(opener)
        f.get("https://example.org/api.php", {"action": "query", "titles": "A|B"})
        request = opener.requests[0]
        self.assertEqual(request.full_url, "https://example.org/api.php?action=query&titles=A%7CB")
        self.assertEqual(request.get_header("User-agent"), http.USER_AGENT)


if __name__ == "__main__":
    unittest.main()
