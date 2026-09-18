# App Privacy answers — draft for account-holder review

Proposed App Store privacy label: **Data Not Collected** and **Tracking: No**.

Basis: recordings, transcripts, participant details, glossary entries, settings,
diagnostics, and the search index stay on the user's Mac and are not transmitted to the developer.
The app contains no developer telemetry, analytics, advertising, or account service. Processing is
local. The privacy manifest therefore declares no tracking and an empty collected-data list.

Network behavior that must be disclosed consistently:

- The Mac App Store build receives app updates through the App Store. Its only bundled executable
  helper is the signed, pinned `whisper-cli`; internal transcript indexing is native code in the
  application.
- Users may request Whisper speech-model downloads from configured model hosts, and the app may
  automatically prepare the small voice-activity model. Those hosts necessarily receive normal
  connection information such as IP address.
- Transcript search, Codex MCP integration, and speaker identification/review are absent
  from the Store build.
- The separate direct-download build also contacts GitHub for update checks, application updates,
  and its verified runtime archive; that behavior is absent from the Store build.

Before submission, the account holder must verify the exact Store binary, model hosts and their
policies, any linked SDK behavior, support/log handling, and Apple's current definition of
"collected." If the developer can access diagnostics, support attachments, crash reports, or any
other user-linked content, the App Privacy answers must be changed before submission.
