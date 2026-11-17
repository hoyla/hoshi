# The official LibreTranslate image downloads its language models on first run.
# This bakes them in at build time so the container boots with no network.
ARG LT_IMAGE=libretranslate/libretranslate:v1.9.6
FROM ${LT_IMAGE}

# Comma-separated language codes (e.g. "en,ru,fr,zh,he,ar"); empty means all.
ARG LANGS=""

RUN if [ -n "$LANGS" ]; then \
      ./venv/bin/python scripts/install_models.py --load_only_lang_codes "$LANGS"; \
    else \
      ./venv/bin/python scripts/install_models.py; \
    fi \
 && rm -rf "$HOME/.local/cache/argos-translate/downloads"
