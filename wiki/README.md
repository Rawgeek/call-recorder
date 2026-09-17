# Wiki source

The wiki is published at https://github.com/Rawgeek/call-recorder/wiki. These files are its
source.

To update the wiki, edit the pages here, then copy them over a clone of the wiki repository:

```sh
git clone https://github.com/Rawgeek/call-recorder.wiki.git
cp wiki/*.md call-recorder.wiki/
rm call-recorder.wiki/README.md
cd call-recorder.wiki && git add -A && git commit -m "Update wiki pages" && git push
```

GitHub wikis have no API: the wiki git repository appears only after the first page is created
in the browser. That step is done, so the commands above work as-is. Page names come from the
file names, and `[[Wiki links]]` resolve by page title.

The pages here are short on purpose: the repository's README, INSTALL.md, and docs/mcp.md
remain the source of truth.
