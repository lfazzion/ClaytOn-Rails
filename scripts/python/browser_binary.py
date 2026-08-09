"""Localiza o binário do Chrome dentro do sidecar python-scraper.

A imagem instala o Chromium via `playwright install chromium`, que o guarda em
`/root/.cache/ms-playwright/chromium-<build>/chrome-linux/chrome` — caminho que
o nodriver não procura sozinho. Sem isto, todo `uc.start()` morre com
"could not find a valid chrome browser binary".

O número do build muda a cada release do playwright, então o caminho é resolvido
por glob e não fixado no código.
"""

import glob
import os
import shutil

CANDIDATE_GLOBS = (
    "/root/.cache/ms-playwright/chromium-*/chrome-linux/chrome",
    "/root/.cache/ms-playwright/chromium_headless_shell-*/chrome-linux/headless_shell",
    "/ms-playwright/chromium-*/chrome-linux/chrome",
)

NAMES_IN_PATH = ("chrome", "chromium", "chromium-browser", "google-chrome")


def find_chrome():
    """Devolve o caminho do binário do Chrome, ou None se não houver."""
    explicit = os.environ.get("CHROME_BIN")
    if explicit and os.path.isfile(explicit):
        return explicit

    for name in NAMES_IN_PATH:
        found = shutil.which(name)
        if found:
            return found

    for pattern in CANDIDATE_GLOBS:
        matches = sorted(glob.glob(pattern))
        if matches:
            return matches[-1]

    return None


def start_kwargs(browser_args=None):
    """kwargs de `nodriver.start()` já com o executável e o sandbox resolvidos."""
    kwargs = {"headless": True, "browser_args": browser_args or []}

    chrome = find_chrome()
    if chrome:
        kwargs["browser_executable_path"] = chrome

    # O container roda como root; o sandbox do Chrome recusa iniciar nesse caso
    # ("Failed to connect to browser"). Só desliga quando é de fato root.
    # O kwarg certo do nodriver é `sandbox`, não `no_sandbox` (0.50.3 ignora).
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        kwargs["sandbox"] = False

    return kwargs
