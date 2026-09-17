# Wiki source

GitHub wikis have no API: the first page must be created once in the browser, after which the
wiki git repository appears and these pages can be pushed.

To publish:

1. Open https://github.com/Rawgeek/call-recorder/wiki and press **Create the first page**.
   Save any content (it will be replaced).
2. Run:

   ```sh
   git clone https://github.com/Rawgeek/call-recorder.wiki.git
   cd call-recorder.wiki
   cp <repo>/wiki/*.md .
   rm README.md
   git add -A && git commit -m "Add wiki pages" && git push
   ```

The pages here are short on purpose: the repository's README, INSTALL.md, and docs/mcp.md
remain the source of truth.

