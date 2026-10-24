"""Where each source lives. Fixtures replay these same addresses."""

STEAM_MOST_PLAYED = "https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/"

AGW_API = "https://www.applegamingwiki.com/w/api.php"
AGW_TEMPLATE = "Template:Compatibility/macOS"

PROTONDB_LISTING = "https://api.github.com/repos/bdefore/protondb-data/contents/reports"

AWACY_GAMES = "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json"


def agw_listing(cont=None):
    params = {
        "action": "query", "generator": "embeddedin", "geititle": AGW_TEMPLATE,
        "geinamespace": "0", "geilimit": "500", "prop": "info",
        "format": "json", "formatversion": "2",
    }
    if cont:
        params.update(cont)
    return params


def agw_content(pageids):
    return {
        "action": "query", "prop": "revisions", "rvprop": "ids|content", "rvslots": "main",
        "pageids": "|".join(str(p) for p in pageids), "format": "json", "formatversion": "2",
    }
